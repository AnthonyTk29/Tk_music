package com.tkmusic.app

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

private val SYNC_UUID: UUID = UUID.fromString("8ce255c0-200a-11e0-ac64-0800200c9a66")
private const val MAX_GUESTS = 4

private class Connection(
    val address: String,
    val socket: BluetoothSocket,
    val input: DataInputStream,
    val output: DataOutputStream
)

/// Transporte Bluetooth Classic (RFCOMM) propio para "Sincronizar con otro
/// teléfono": un socket por dispositivo conectado, dos tipos de frame
/// ([1 byte tipo][4 bytes tamaño][payload]) — tipo 1 = JSON de control
/// (play/pause/seek/reloj), tipo 2 = metadata de un archivo de audio
/// entrante, inmediatamente seguida de sus bytes crudos (sin framing
/// adicional, hasta completar fileSize). Toda la lógica de sincronización de
/// reloj/drift vive en Dart (PartySyncEngine); esto es solo una tubería
/// confiable — ahora para hasta [MAX_GUESTS] invitados a la vez cuando se
/// hace de anfitrión, no solo uno.
class BluetoothSyncBridge(private val activity: MainActivity) {
    private val adapter: BluetoothAdapter? = BluetoothAdapter.getDefaultAdapter()
    private var serverSocket: BluetoothServerSocket? = null
    // address de dispositivo -> conexión activa. Desde el lado invitado
    // nunca hay más de una entrada (un solo socket hacia el anfitrión);
    // desde el lado anfitrión puede haber hasta MAX_GUESTS.
    private val connections = ConcurrentHashMap<String, Connection>()
    private var eventSink: EventChannel.EventSink? = null
    private val running = AtomicBoolean(false)

    // Direcciones de TODOS los dispositivos Bluetooth que tienen una sesión
    // activa ahora mismo (no solo los de esta app): se mantiene siguiendo las
    // broadcasts ACL_CONNECTED/ACL_DISCONNECTED del sistema, para que la
    // pantalla pueda marcar cuáles están "conectados ahora" al emparejar.
    private val activeAclDevices: MutableSet<String> = ConcurrentHashMap.newKeySet()
    private val aclReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val device: BluetoothDevice? = if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
            }
            val address = try {
                device?.address ?: return
            } catch (e: SecurityException) {
                return
            }
            when (intent.action) {
                BluetoothDevice.ACTION_ACL_CONNECTED -> {
                    activeAclDevices.add(address)
                    emitAclState(address, true)
                }
                BluetoothDevice.ACTION_ACL_DISCONNECTED -> {
                    activeAclDevices.remove(address)
                    emitAclState(address, false)
                }
            }
        }
    }

    init {
        // Context-registered receiver para ver qué dispositivos tienen una
        // sesión Bluetooth activa. Son broadcasts de sistema protegidas, así
        // que en Android 13+ se registra sin marcar como exported.
        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                activity.registerReceiver(aclReceiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                activity.registerReceiver(aclReceiver, filter)
            }
        } catch (e: Exception) {
            // Sin permiso de Bluetooth aún, o el registro falla: no es fatal,
            // solo se pierde el marcado en vivo hasta que haya permiso.
        }
    }

    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getPairedDevices" -> getPairedDevices(result)
            "getCapacity" -> getCapacity(result)
            "getActiveSessions" -> getActiveSessions(result)
            "startHosting" -> startHosting(result)
            "connectToDevice" -> {
                val address = call.argument<String>("address")
                if (address == null) result.error("BAD_ARGS", "Falta address", null)
                else connectToDevice(address, result)
            }
            "sendSongFile" -> {
                val path = call.argument<String>("path")
                val title = call.argument<String>("title") ?: "Canción"
                val artist = call.argument<String>("artist")
                val durationMs = call.argument<Number>("durationMs")?.toLong()
                if (path == null) result.error("BAD_ARGS", "Falta path", null)
                else sendSongFile(path, title, artist, durationMs, result)
            }
            "sendSongFileTo" -> {
                val address = call.argument<String>("address")
                val path = call.argument<String>("path")
                val title = call.argument<String>("title") ?: "Canción"
                val artist = call.argument<String>("artist")
                val durationMs = call.argument<Number>("durationMs")?.toLong()
                if (address == null || path == null) {
                    result.error("BAD_ARGS", "Falta address/path", null)
                } else {
                    sendSongFileTo(address, path, title, artist, durationMs, result)
                }
            }
            "sendControl" -> {
                val json = call.argument<String>("json")
                if (json == null) result.error("BAD_ARGS", "Falta json", null)
                else sendControl(json, result)
            }
            "sendControlTo" -> {
                val address = call.argument<String>("address")
                val json = call.argument<String>("json")
                if (address == null || json == null) {
                    result.error("BAD_ARGS", "Falta address/json", null)
                } else {
                    sendControlTo(address, json, result)
                }
            }
            "disconnect" -> disconnect(result)
            else -> result.notImplemented()
        }
    }

    // Snapshot de las direcciones con sesión activa en este momento. La
    // pantalla lo pide al cargar la lista de dispositivos y después se
    // actualiza solo con los eventos ACL que emite aclReceiver.
    private fun getActiveSessions(result: MethodChannel.Result) {
        result.success(activeAclDevices.toList())
    }

    private fun emitAclState(address: String, connected: Boolean) {
        val sink = eventSink ?: return
        activity.runOnUiThread {
            sink.success(
                mapOf(
                    "type" to "device_connected_changed",
                    "address" to address,
                    "connected" to connected
                )
            )
        }
    }

    // Limpia el receiver de broadcasts y las conexiones al cerrar la
    // actividad, para no filtrar el activity al rotar o salir.
    fun shutdown() {
        try {
            activity.unregisterReceiver(aclReceiver)
        } catch (e: IllegalArgumentException) {
            // Ya estaba dado de baja.
        }
        disconnect(null)
    }

    private fun hasBluetoothPermission(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return ContextCompat.checkSelfPermission(
                activity, Manifest.permission.BLUETOOTH_CONNECT
            ) == PackageManager.PERMISSION_GRANTED
        }
        return true
    }

    private fun getPairedDevices(result: MethodChannel.Result) {
        if (adapter == null) {
            result.error("NO_ADAPTER", "Este dispositivo no tiene Bluetooth", null)
            return
        }
        if (!hasBluetoothPermission()) {
            result.error("NO_PERMISSION", "Falta permiso de Bluetooth", null)
            return
        }
        try {
            val devices = adapter.bondedDevices.map {
                mapOf("name" to (it.name ?: it.address), "address" to it.address)
            }
            result.success(devices)
        } catch (e: SecurityException) {
            result.error("NO_PERMISSION", e.message, null)
        }
    }

    // Cálculo previo de cuántas sesiones Bluetooth activas puede sostener el
    // dispositivo. Un piconet BR/EDR (Bluetooth clásico) da soporte a 1
    // maestro + hasta 7 esclavos activos, y este sincronizador abre una
    // sesión RFCOMM por invitado, así que 4 invitados + este teléfono entran
    // de sobra en cualquier equipo con Classic. Lo que SÍ se valida acá es
    // la parte real que puede hacer fallar la función: dispositivos que solo
    // traen Bluetooth LE (tablets/equipos nuevos que omiten BR/EDR) no pueden
    // ser anfitrión de ni una sola sesión RFCOMM, y eso no se puede saber
    // hasta probar — por eso se detecta por feature antes de ofrecer el rol.
    private fun getCapacity(result: MethodChannel.Result) {
        if (adapter == null || !hasBluetoothPermission()) {
            result.success(mapOf("supported" to false, "maxConcurrent" to 0, "reason" to "no_bluetooth"))
            return
        }
        val pm = activity.packageManager
        val hasClassic = pm.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH)
        try {
            if (!hasClassic) {
                // BLE solo: no hay RFCOMM (Bluetooth clásico), la sesión no
                // puede ni arrancar.
                result.success(mapOf("supported" to false, "maxConcurrent" to 0, "reason" to "le_only"))
                return
            }
            // Máximo del estándar BR/EDR; esta app nunca pide más de 4
            // invitados, así que el tope efectivo lo vuelve a poner Dart
            // contra PartySyncEngine.maxGuests.
            result.success(mapOf("supported" to true, "maxConcurrent" to 7, "reason" to null))
        } catch (e: Exception) {
            result.error("CAPACITY_FAILED", e.message, null)
        }
    }

    // Antes aceptaba una sola conexión y cerraba el socket del servidor —
    // ahora sigue aceptando en loop hasta llegar a MAX_GUESTS invitados (o
    // hasta que se llame a disconnect(), que corta el accept() bloqueado
    // cerrando el socket del servidor).
    private fun startHosting(result: MethodChannel.Result) {
        if (adapter == null || !hasBluetoothPermission()) {
            result.error("NO_PERMISSION", "Falta Bluetooth o el permiso", null)
            return
        }
        running.set(true)
        thread {
            var reportedReady = false
            try {
                val server =
                    adapter.listenUsingRfcommWithServiceRecord("tk_music_sync", SYNC_UUID)
                serverSocket = server
                activity.runOnUiThread { result.success(null) }
                reportedReady = true
                while (running.get() && connections.size < MAX_GUESTS) {
                    val accepted = try {
                        server.accept()
                    } catch (e: Exception) {
                        break // socket cerrado (disconnect()) o error real: se corta el loop igual
                    }
                    onConnected(accepted)
                }
            } catch (e: Exception) {
                if (!reportedReady) {
                    activity.runOnUiThread { result.error("HOST_FAILED", e.message, null) }
                } else {
                    activity.runOnUiThread {
                        eventSink?.success(
                            mapOf("type" to "error", "message" to (e.message ?: "No se pudo esperar la conexión"))
                        )
                    }
                }
            } finally {
                try { serverSocket?.close() } catch (_: Exception) {}
                serverSocket = null
            }
        }
    }

    private fun connectToDevice(address: String, result: MethodChannel.Result) {
        if (adapter == null || !hasBluetoothPermission()) {
            result.error("NO_PERMISSION", "Falta Bluetooth o el permiso", null)
            return
        }
        thread {
            try {
                val device: BluetoothDevice = adapter.getRemoteDevice(address)
                adapter.cancelDiscovery()
                val newSocket = device.createRfcommSocketToServiceRecord(SYNC_UUID)
                newSocket.connect()
                running.set(true)
                activity.runOnUiThread { result.success(null) }
                onConnected(newSocket)
            } catch (e: Exception) {
                activity.runOnUiThread {
                    result.error("CONNECT_FAILED", e.message, null)
                }
            }
        }
    }

    private fun onConnected(socket: BluetoothSocket) {
        val address = try {
            socket.remoteDevice.address
        } catch (e: Exception) {
            socket.hashCode().toString()
        }
        val name = try { socket.remoteDevice.name ?: address } catch (e: SecurityException) { address }
        val conn = Connection(
            address, socket, DataInputStream(socket.inputStream), DataOutputStream(socket.outputStream)
        )
        connections[address] = conn
        activity.runOnUiThread {
            eventSink?.success(mapOf("type" to "connected", "deviceName" to name, "address" to address))
        }
        readLoop(conn)
    }

    private fun readLoop(conn: Connection) {
        thread {
            try {
                while (running.get() && connections[conn.address] === conn) {
                    val frameType = conn.input.readByte()
                    val length = conn.input.readInt()
                    if (length < 0 || length > 200 * 1024 * 1024) {
                        throw java.io.IOException("Frame inválido")
                    }
                    when (frameType.toInt()) {
                        1 -> {
                            val bytes = ByteArray(length)
                            conn.input.readFully(bytes)
                            val text = String(bytes, Charsets.UTF_8)
                            activity.runOnUiThread {
                                eventSink?.success(
                                    mapOf("type" to "message", "json" to text, "address" to conn.address)
                                )
                            }
                        }
                        2 -> {
                            val bytes = ByteArray(length)
                            conn.input.readFully(bytes)
                            val meta = JSONObject(String(bytes, Charsets.UTF_8))
                            receiveIncomingFile(conn, meta)
                        }
                        else -> {
                            val bytes = ByteArray(length)
                            conn.input.readFully(bytes)
                        }
                    }
                }
            } catch (e: Exception) {
                val stillOurs = connections[conn.address] === conn
                connections.remove(conn.address, conn)
                try { conn.socket.close() } catch (_: Exception) {}
                if (stillOurs) {
                    activity.runOnUiThread {
                        eventSink?.success(
                            mapOf("type" to "disconnected", "reason" to (e.message ?: ""), "address" to conn.address)
                        )
                    }
                }
            }
        }
    }

    private fun receiveIncomingFile(conn: Connection, meta: JSONObject) {
        val fileSize = meta.optLong("fileSize", 0L)
        val fileName = meta.optString("fileName", "sync_received.mp3")
        val destFile = File(
            activity.getExternalFilesDir(null),
            "sync_" + System.currentTimeMillis() + "_" + fileName
        )
        var received = 0L
        val buffer = ByteArray(16 * 1024)
        FileOutputStream(destFile).use { out ->
            while (received < fileSize) {
                val toRead = minOf(buffer.size.toLong(), fileSize - received).toInt()
                val read = conn.input.read(buffer, 0, toRead)
                if (read < 0) break
                out.write(buffer, 0, read)
                received += read
                if (received % (256 * 1024) < buffer.size) {
                    val progress = received
                    activity.runOnUiThread {
                        eventSink?.success(
                            mapOf(
                                "type" to "file_progress", "received" to progress,
                                "total" to fileSize, "address" to conn.address
                            )
                        )
                    }
                }
            }
        }
        activity.runOnUiThread {
            eventSink?.success(
                mapOf(
                    "type" to "file_received",
                    "path" to destFile.absolutePath,
                    "title" to meta.optString("title", ""),
                    "artist" to meta.optString("artist", ""),
                    "durationMs" to meta.optLong("durationMs", 0L),
                    "address" to conn.address
                )
            )
        }
    }

    // Arma la metadata y manda el archivo por [conn] — la parte compartida
    // entre mandarlo a todos (sendSongFile) y a uno solo (sendSongFileTo,
    // para un invitado que se conecta después de que ya se mandó la
    // canción al resto).
    private fun writeSongFileTo(
        conn: Connection,
        path: String,
        title: String,
        artist: String?,
        durationMs: Long?
    ) {
        val file = File(path)
        val meta = JSONObject().apply {
            put("fileName", file.name)
            put("fileSize", file.length())
            put("title", title)
            put("artist", artist)
            put("durationMs", durationMs ?: 0L)
        }
        val metaBytes = meta.toString().toByteArray(Charsets.UTF_8)
        synchronized(conn) {
            conn.output.writeByte(2)
            conn.output.writeInt(metaBytes.size)
            conn.output.write(metaBytes)
            conn.output.flush()

            file.inputStream().use { input ->
                val buffer = ByteArray(16 * 1024)
                var sent = 0L
                val total = file.length()
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    conn.output.write(buffer, 0, read)
                    sent += read
                    if (sent % (256 * 1024) < buffer.size) {
                        val progress = sent
                        activity.runOnUiThread {
                            eventSink?.success(
                                mapOf(
                                    "type" to "send_progress", "sent" to progress,
                                    "total" to total, "address" to conn.address
                                )
                            )
                        }
                    }
                }
                conn.output.flush()
            }
        }
    }

    // Manda el archivo a TODOS los invitados conectados en paralelo (un
    // hilo por invitado, cada uno con su propio socket — no se serializa
    // artificialmente más de lo que ya limita el radio Bluetooth
    // compartido). [result] se resuelve cuando todos terminaron (o al
    // primer error).
    private fun sendSongFile(
        path: String,
        title: String,
        artist: String?,
        durationMs: Long?,
        result: MethodChannel.Result
    ) {
        val targets = connections.values.toList()
        if (targets.isEmpty()) {
            result.error("NOT_CONNECTED", "No hay invitados conectados", null)
            return
        }
        thread {
            val latch = CountDownLatch(targets.size)
            var lastError: Exception? = null

            for (conn in targets) {
                thread {
                    try {
                        writeSongFileTo(conn, path, title, artist, durationMs)
                    } catch (e: Exception) {
                        lastError = e
                    } finally {
                        latch.countDown()
                    }
                }
            }
            latch.await()
            activity.runOnUiThread {
                if (lastError == null) result.success(null)
                else result.error("SEND_FAILED", lastError?.message, null)
            }
        }
    }

    // Manda el archivo a UN SOLO invitado — hace falta cuando alguien se
    // conecta después de que ya se mandó la canción al resto (p. ej. tras
    // "Empezar con los que ya están"): reenviar con sendSongFile() de
    // nuevo le volvería a mandar el archivo también a los que ya lo tienen
    // y ya están sincronizando el reloj, interrumpiéndolos sin necesidad.
    private fun sendSongFileTo(
        address: String,
        path: String,
        title: String,
        artist: String?,
        durationMs: Long?,
        result: MethodChannel.Result
    ) {
        val conn = connections[address]
        if (conn == null) {
            result.error("NOT_CONNECTED", "Invitado no conectado", null)
            return
        }
        thread {
            try {
                writeSongFileTo(conn, path, title, artist, durationMs)
                activity.runOnUiThread { result.success(null) }
            } catch (e: Exception) {
                activity.runOnUiThread { result.error("SEND_FAILED", e.message, null) }
            }
        }
    }

    // Difunde un mensaje de control a TODOS los conectados (play/pause/
    // seek/reloj de posición) — lo usa el anfitrión. El invitado también lo
    // usa para mandarle algo al anfitrión, pero como solo tiene una
    // conexión "difundir" y "mandarle al anfitrión" son lo mismo.
    private fun sendControl(json: String, result: MethodChannel.Result) {
        val targets = connections.values.toList()
        if (targets.isEmpty()) {
            result.error("NOT_CONNECTED", "No hay conexión activa", null)
            return
        }
        thread {
            val bytes = json.toByteArray(Charsets.UTF_8)
            var lastError: Exception? = null
            for (conn in targets) {
                try {
                    synchronized(conn) {
                        conn.output.writeByte(1)
                        conn.output.writeInt(bytes.size)
                        conn.output.write(bytes)
                        conn.output.flush()
                    }
                } catch (e: Exception) {
                    lastError = e
                }
            }
            activity.runOnUiThread {
                if (lastError == null) result.success(null)
                else result.error("SEND_FAILED", lastError?.message, null)
            }
        }
    }

    // Le manda un mensaje de control a UN SOLO invitado — hace falta para
    // la respuesta "clock_pong" de la ronda de reloj, que tiene que volver
    // solo al invitado que mandó el "clock_ping" correspondiente (si se
    // difundiera a todos, cada invitado recibiría respuestas con el t0 de
    // otro y calcularía mal su offset).
    private fun sendControlTo(address: String, json: String, result: MethodChannel.Result) {
        val conn = connections[address]
        if (conn == null) {
            result.error("NOT_CONNECTED", "Invitado no conectado", null)
            return
        }
        thread {
            try {
                val bytes = json.toByteArray(Charsets.UTF_8)
                synchronized(conn) {
                    conn.output.writeByte(1)
                    conn.output.writeInt(bytes.size)
                    conn.output.write(bytes)
                    conn.output.flush()
                }
                activity.runOnUiThread { result.success(null) }
            } catch (e: Exception) {
                activity.runOnUiThread { result.error("SEND_FAILED", e.message, null) }
            }
        }
    }

    private fun disconnect(result: MethodChannel.Result?) {
        running.set(false)
        try { serverSocket?.close() } catch (_: Exception) {}
        serverSocket = null
        for (conn in connections.values.toList()) {
            try { conn.socket.close() } catch (_: Exception) {}
        }
        connections.clear()
        result?.success(null)
    }
}
