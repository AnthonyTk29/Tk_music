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
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

private val SYNC_UUID: UUID = UUID.fromString("8ce255c0-200a-11e0-ac64-0800200c9a66")
private const val MAX_GUESTS = 6

// Canal RFCOMM fijo en el que escucha un anfitrión Windows (mismo valor que
// kPreferredChannel en windows/runner/bluetooth_sync_plugin.cpp): se prueba
// directo si la búsqueda del servicio por SDP falla.
private const val WINDOWS_HOST_CHANNEL = 22

// Tipos de frame ([1 byte tipo][4 bytes tamaño][payload]). Mismo protocolo
// que windows/runner/bluetooth_sync_plugin.cpp.
private const val FRAME_CONTROL = 1     // JSON de control
private const val FRAME_FILE_START = 3  // JSON con la metadata del archivo
private const val FRAME_FILE_CHUNK = 4  // [8 bytes offset][bytes]
private const val FRAME_FILE_ABORT = 5  // transferId (UTF-8)

private const val CHUNK_SIZE = 32 * 1024
// El final del archivo viaja primero: ahí están los tags ID3v1 (MP3) o el
// índice "moov" (M4A) que el reproductor lee antes de arrancar — sin esto
// no podría empezar a sonar hasta tener el archivo completo.
private const val TAIL_SIZE = 256L * 1024
private const val PROGRESS_STEP = 64L * 1024

private class IncomingFile(
    val transferId: String,
    val meta: JSONObject,
    val file: File,
    val raf: RandomAccessFile,
    val size: Long
) {
    var received = 0L
    // Bytes disponibles = [0, head) ∪ [tailFrom, tailEnd).
    var head = 0L
    var tailFrom = size
    var tailEnd = size
    var lastEmitted = 0L
}

private class Connection(
    val address: String,
    val socket: BluetoothSocket,
    val input: DataInputStream,
    val output: DataOutputStream
) {
    // Un solo archivo saliente a la vez por conexión (los trozos de dos
    // archivos no se pueden mezclar); los frames de control sí se cuelan
    // entre trozo y trozo, porque cada trozo toma el lock de escritura
    // (synchronized(conn)) por separado.
    val fileLock = Object()
    @Volatile var cancelOutgoing = false
    // Solo lo toca el hilo de lectura de esta conexión.
    var incoming: IncomingFile? = null
}

/// Transporte Bluetooth Classic (RFCOMM) propio para "Sincronizar con otro
/// dispositivo": un socket por dispositivo conectado. Los archivos viajan en
/// trozos de [CHUNK_SIZE] para que play/pausa/sincronía no queden trabados
/// detrás de una transferencia de varios MB, y el receptor puede empezar a
/// reproducir antes de tener el archivo entero (streaming: ver
/// SyncStreamServer en Dart). Toda la lógica de sincronización vive en Dart
/// (PartySyncEngine); esto es solo una tubería confiable para hasta
/// [MAX_GUESTS] invitados a la vez.
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
            "getLocalAdapter" -> getLocalAdapter(result)
            "openBluetoothSettings" -> {
                try {
                    activity.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
                    result.success(null)
                } catch (e: Exception) {
                    result.error("OPEN_FAILED", e.message, null)
                }
            }
            "getActiveSessions" -> getActiveSessions(result)
            "startHosting" -> startHosting(result)
            "connectToDevice" -> {
                val address = call.argument<String>("address")
                val channel = call.argument<Number>("channel")?.toInt()
                if (address == null) result.error("BAD_ARGS", "Falta address", null)
                else connectToDevice(address, channel, result)
            }
            "sendSongFileTo" -> {
                val address = call.argument<String>("address")
                val path = call.argument<String>("path")
                val title = call.argument<String>("title") ?: "Canción"
                val artist = call.argument<String>("artist")
                val durationMs = call.argument<Number>("durationMs")?.toLong()
                val transferId = call.argument<String>("transferId") ?: ""
                val extraJson = call.argument<String>("extraJson")
                if (address == null || path == null) {
                    result.error("BAD_ARGS", "Falta address/path", null)
                } else {
                    sendSongFileTo(address, path, title, artist, durationMs, transferId, extraJson, result)
                }
            }
            "cancelTransfer" -> {
                val address = call.argument<String>("address")
                if (address != null) connections[address]?.cancelOutgoing = true
                result.success(null)
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

    // Nombre del Bluetooth de este teléfono, para el QR de "Unirse con QR".
    // La dirección no: desde Android 6 el sistema devuelve una falsa
    // (02:00:00:00:00:00) a las apps.
    @Suppress("MissingPermission")
    private fun getLocalAdapter(result: MethodChannel.Result) {
        if (adapter == null || !hasBluetoothPermission()) {
            result.success(mapOf("name" to null, "address" to null))
            return
        }
        val name = try { adapter.name } catch (e: SecurityException) { null }
        result.success(mapOf("name" to name, "address" to null))
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
    // sesión RFCOMM por invitado, así que 6 invitados + este teléfono entran
    // y todavía queda un lugar libre (p. ej. para unos auriculares o un
    // parlante Bluetooth conectados al anfitrión). Lo que SÍ se valida acá es
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

    // Se prueban varias formas, de la más normal a la más directa, porque
    // algunas combinaciones de teléfono y placa Bluetooth de PC fallan en
    // una y no en otra:
    //  1. buscar el servicio de TK Music por SDP (cifrado, lo normal),
    //  2. lo mismo sin cifrar,
    //  3. el canal RFCOMM directo (el del QR y el fijo del anfitrión Windows),
    //     sin pasar por SDP.
    // Si todas fallan, el error dice qué pasó con cada una.
    private fun connectToDevice(address: String, channelHint: Int?, result: MethodChannel.Result) {
        if (adapter == null || !hasBluetoothPermission()) {
            result.error("NO_PERMISSION", "Falta Bluetooth o el permiso", null)
            return
        }
        thread {
            val device: BluetoothDevice = try {
                adapter.getRemoteDevice(address)
            } catch (e: Exception) {
                activity.runOnUiThread { result.error("CONNECT_FAILED", e.message, null) }
                return@thread
            }
            try { adapter.cancelDiscovery() } catch (_: SecurityException) {}
            val attempts = mutableListOf<Pair<String, () -> BluetoothSocket>>(
                "servicio" to { device.createRfcommSocketToServiceRecord(SYNC_UUID) },
                "servicio sin cifrar" to { device.createInsecureRfcommSocketToServiceRecord(SYNC_UUID) },
            )
            for (channel in listOfNotNull(channelHint, WINDOWS_HOST_CHANNEL).distinct()) {
                attempts += "canal $channel" to { rfcommOnChannel(device, channel, secure = true) }
                attempts += "canal $channel sin cifrar" to { rfcommOnChannel(device, channel, secure = false) }
            }
            val errors = mutableListOf<String>()
            for ((label, open) in attempts) {
                var socket: BluetoothSocket? = null
                try {
                    socket = open()
                    socket.connect()
                    running.set(true)
                    activity.runOnUiThread { result.success(mapOf("via" to label)) }
                    onConnected(socket)
                    return@thread
                } catch (e: Exception) {
                    val reason = (e.cause ?: e).message ?: e.javaClass.simpleName
                    errors += "$label: $reason"
                    try { socket?.close() } catch (_: Exception) {}
                }
            }
            activity.runOnUiThread {
                result.error("CONNECT_FAILED", errors.joinToString(" | "), null)
            }
        }
    }

    // BluetoothDevice.createRfcommSocket(canal) no es API pública, pero
    // existe en todos los Android: conecta a un canal sin buscar por SDP.
    private fun rfcommOnChannel(device: BluetoothDevice, channel: Int, secure: Boolean): BluetoothSocket {
        val name = if (secure) "createRfcommSocket" else "createInsecureRfcommSocket"
        val method = device.javaClass.getMethod(name, Int::class.javaPrimitiveType)
        return method.invoke(device, channel) as BluetoothSocket
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

    private fun emit(event: Map<String, Any?>) {
        activity.runOnUiThread { eventSink?.success(event) }
    }

    private fun readLoop(conn: Connection) {
        thread {
            try {
                while (running.get() && connections[conn.address] === conn) {
                    val frameType = conn.input.readByte().toInt()
                    val length = conn.input.readInt()
                    if (length < 0 || length > 16 * 1024 * 1024) {
                        throw IOException("Frame inválido")
                    }
                    when (frameType) {
                        FRAME_CONTROL -> {
                            val bytes = ByteArray(length)
                            conn.input.readFully(bytes)
                            emit(
                                mapOf(
                                    "type" to "message",
                                    "json" to String(bytes, Charsets.UTF_8),
                                    "address" to conn.address
                                )
                            )
                        }
                        FRAME_FILE_START -> {
                            val bytes = ByteArray(length)
                            conn.input.readFully(bytes)
                            startIncomingFile(conn, JSONObject(String(bytes, Charsets.UTF_8)))
                        }
                        FRAME_FILE_CHUNK -> {
                            if (length < 8) throw IOException("Trozo inválido")
                            val offset = conn.input.readLong()
                            val data = ByteArray(length - 8)
                            conn.input.readFully(data)
                            writeIncomingChunk(conn, offset, data)
                        }
                        FRAME_FILE_ABORT -> {
                            val bytes = ByteArray(length)
                            conn.input.readFully(bytes)
                            abortIncomingFile(conn)
                        }
                        else -> {
                            val bytes = ByteArray(length)
                            conn.input.readFully(bytes)
                        }
                    }
                }
            } catch (e: Exception) {
                abortIncomingFile(conn)
                val stillOurs = connections[conn.address] === conn
                connections.remove(conn.address, conn)
                try { conn.socket.close() } catch (_: Exception) {}
                if (stillOurs) {
                    emit(
                        mapOf(
                            "type" to "disconnected",
                            "reason" to (e.message ?: ""),
                            "address" to conn.address
                        )
                    )
                }
            }
        }
    }

    private fun startIncomingFile(conn: Connection, meta: JSONObject) {
        // Un archivo anterior que quedó a medias (el anfitrión pasó a otra
        // canción sin avisar): se descarta.
        abortIncomingFile(conn)
        val size = meta.optLong("fileSize", 0L)
        val transferId = meta.optString("transferId", "")
        val fileName = meta.optString("fileName", "sync_received.mp3")
            .map { if ("\\/:*?\"<>|".indexOf(it) >= 0) '_' else it }
            .joinToString("")
        val dir = File(activity.getExternalFilesDir(null), "sync").apply { mkdirs() }
        val file = File(dir, "sync_" + System.currentTimeMillis() + "_" + fileName)
        val raf = RandomAccessFile(file, "rw")
        raf.setLength(size)
        val incoming = IncomingFile(transferId, meta, file, raf, size)
        conn.incoming = incoming
        emit(
            mapOf(
                "type" to "file_started",
                "transferId" to transferId,
                "path" to file.absolutePath,
                "total" to size,
                "meta" to meta.toString(),
                "address" to conn.address
            )
        )
        if (size == 0L) finishIncomingFile(conn, incoming)
    }

    private fun writeIncomingChunk(conn: Connection, offset: Long, data: ByteArray) {
        val incoming = conn.incoming ?: return
        if (offset < 0 || offset + data.size > incoming.size) throw IOException("Trozo fuera de rango")
        incoming.raf.seek(offset)
        incoming.raf.write(data)
        incoming.received += data.size
        if (offset == incoming.head) {
            incoming.head += data.size
        } else {
            if (incoming.tailFrom == incoming.size) incoming.tailEnd = offset
            incoming.tailFrom = minOf(incoming.tailFrom, offset)
            incoming.tailEnd = maxOf(incoming.tailEnd, offset + data.size)
        }
        val done = incoming.received >= incoming.size
        if (done || incoming.received - incoming.lastEmitted >= PROGRESS_STEP) {
            incoming.lastEmitted = incoming.received
            emit(
                mapOf(
                    "type" to "file_progress",
                    "transferId" to incoming.transferId,
                    "received" to incoming.received,
                    "total" to incoming.size,
                    "head" to incoming.head,
                    "tailFrom" to incoming.tailFrom,
                    "tailEnd" to incoming.tailEnd,
                    "address" to conn.address
                )
            )
        }
        if (done) finishIncomingFile(conn, incoming)
    }

    private fun finishIncomingFile(conn: Connection, incoming: IncomingFile) {
        try { incoming.raf.close() } catch (_: Exception) {}
        conn.incoming = null
        emit(
            mapOf(
                "type" to "file_received",
                "transferId" to incoming.transferId,
                "path" to incoming.file.absolutePath,
                "title" to incoming.meta.optString("title", ""),
                "artist" to incoming.meta.optString("artist", ""),
                "durationMs" to incoming.meta.optLong("durationMs", 0L),
                "meta" to incoming.meta.toString(),
                "address" to conn.address
            )
        )
    }

    private fun abortIncomingFile(conn: Connection) {
        val incoming = conn.incoming ?: return
        conn.incoming = null
        try { incoming.raf.close() } catch (_: Exception) {}
        incoming.file.delete()
        emit(
            mapOf(
                "type" to "file_aborted",
                "transferId" to incoming.transferId,
                "address" to conn.address
            )
        )
    }

    private fun writeFrame(conn: Connection, type: Int, payload: ByteArray) {
        synchronized(conn) {
            conn.output.writeByte(type)
            conn.output.writeInt(payload.size)
            conn.output.write(payload)
            conn.output.flush()
        }
    }

    // Manda un archivo a UN invitado, en trozos: primero los últimos
    // [TAIL_SIZE] bytes y después el resto en orden. Tira IOException
    // ("CANCELLED") si Dart pidió cancelarlo con cancelTransfer — p. ej. el
    // anfitrión saltó a otra canción y esa tiene que llegar primero.
    private fun writeSongFileTo(
        conn: Connection,
        path: String,
        title: String,
        artist: String?,
        durationMs: Long?,
        transferId: String,
        extraJson: String?
    ) {
        synchronized(conn.fileLock) {
            conn.cancelOutgoing = false
            val file = File(path)
            val total = file.length()
            val meta = JSONObject().apply {
                put("transferId", transferId)
                put("fileName", file.name)
                put("fileSize", total)
                put("title", title)
                put("artist", artist ?: "")
                put("durationMs", durationMs ?: 0L)
                if (!extraJson.isNullOrEmpty()) put("extra", JSONObject(extraJson))
            }
            writeFrame(conn, FRAME_FILE_START, meta.toString().toByteArray(Charsets.UTF_8))

            val ranges = if (total > 2 * TAIL_SIZE) {
                listOf((total - TAIL_SIZE) to total, 0L to (total - TAIL_SIZE))
            } else {
                listOf(0L to total)
            }
            val buffer = ByteArray(CHUNK_SIZE)
            var sent = 0L
            var lastEmitted = 0L
            RandomAccessFile(file, "r").use { raf ->
                for ((start, end) in ranges) {
                    var offset = start
                    while (offset < end) {
                        if (conn.cancelOutgoing) {
                            writeFrame(conn, FRAME_FILE_ABORT, transferId.toByteArray(Charsets.UTF_8))
                            throw IOException("CANCELLED")
                        }
                        val n = minOf(CHUNK_SIZE.toLong(), end - offset).toInt()
                        raf.seek(offset)
                        raf.readFully(buffer, 0, n)
                        synchronized(conn) {
                            conn.output.writeByte(FRAME_FILE_CHUNK)
                            conn.output.writeInt(n + 8)
                            conn.output.writeLong(offset)
                            conn.output.write(buffer, 0, n)
                            conn.output.flush()
                        }
                        offset += n
                        sent += n
                        if (sent == total || sent - lastEmitted >= PROGRESS_STEP) {
                            lastEmitted = sent
                            emit(
                                mapOf(
                                    "type" to "send_progress",
                                    "transferId" to transferId,
                                    "sent" to sent,
                                    "total" to total,
                                    "address" to conn.address
                                )
                            )
                        }
                    }
                }
            }
        }
    }

    private fun sendSongFileTo(
        address: String,
        path: String,
        title: String,
        artist: String?,
        durationMs: Long?,
        transferId: String,
        extraJson: String?,
        result: MethodChannel.Result
    ) {
        val conn = connections[address]
        if (conn == null) {
            result.error("NOT_CONNECTED", "Invitado no conectado", null)
            return
        }
        thread {
            try {
                writeSongFileTo(conn, path, title, artist, durationMs, transferId, extraJson)
                activity.runOnUiThread { result.success(null) }
            } catch (e: Exception) {
                val code = if (e.message == "CANCELLED") "CANCELLED" else "SEND_FAILED"
                activity.runOnUiThread { result.error(code, e.message, null) }
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
                    writeFrame(conn, FRAME_CONTROL, bytes)
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
                writeFrame(conn, FRAME_CONTROL, bytes)
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
            conn.cancelOutgoing = true
            try { conn.socket.close() } catch (_: Exception) {}
        }
        connections.clear()
        result?.success(null)
    }
}
