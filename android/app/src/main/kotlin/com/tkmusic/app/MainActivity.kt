package com.tkmusic.app

import android.app.Activity
import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteOrder
import kotlin.concurrent.thread
import kotlin.math.log10
import kotlin.math.sqrt

// audio_service necesita que MainActivity extienda su propia Activity base
// (o AudioServiceActivity si se usara FlutterActivity) para poder compartir
// el FlutterEngine entre la UI y el servicio en segundo plano. Sin esto,
// AudioService.init() falla con "The Activity class declared in your
// AndroidManifest.xml is wrong...". AudioServiceFragmentActivity ya extiende
// FlutterFragmentActivity, así que no se pierde esa compatibilidad.
//
// Además expone dos canales propios (sin depender de plugins de terceros,
// para no repetir el problema de R8 con audio_service):
//  - tk_music/external_storage: selector de carpetas (SAF) para leer música
//    de un pendrive conectado por USB-OTG.
//  - tk_music/media_import: copia audios de WhatsApp a la carpeta Download
//    para que MediaStore los indexe como música normal.
//  - tk_music/audio_analysis: mide el volumen real (dB) de una canción para
//    el Mezclador automático.
//  - tk_music/bluetooth_sync (+ /events): sesión Bluetooth Classic para
//    "Sincronizar con otro teléfono" (ver BluetoothSyncBridge.kt).
//  - tk_music/spectrum_analysis (+ /progress): espectrograma del Ecualizador
//    calculado con FFT propia (ver SpectrumMath.kt), no con el Visualizer
//    del sistema.
class MainActivity : AudioServiceFragmentActivity() {
    private val storageChannelName = "tk_music/external_storage"
    private val importChannelName = "tk_music/media_import"
    private val analysisChannelName = "tk_music/audio_analysis"
    private val waveformProgressEventsName = "tk_music/audio_analysis/waveform_progress"
    private val bluetoothSyncChannelName = "tk_music/bluetooth_sync"
    private val bluetoothSyncEventsName = "tk_music/bluetooth_sync/events"
    private val spectrumChannelName = "tk_music/spectrum_analysis"
    private val spectrumProgressEventsName = "tk_music/spectrum_analysis/progress"
    private val pickDirectoryRequestCode = 4201

    private var waveformProgressSink: EventChannel.EventSink? = null
    private var spectrumProgressSink: EventChannel.EventSink? = null

    private var pendingPickResult: MethodChannel.Result? = null
    private val bluetoothSyncBridge by lazy { BluetoothSyncBridge(this) }

    // Tres hilos separados para el análisis de audio: uno para el volumen
    // (lo usa el Mezclador automático para calcular el crossfade, tiene que
    // responder rápido), otro para la forma de onda y otro para el
    // espectrograma (ambos decodifican la canción entera, tardan mucho
    // más). Antes volumen y forma de onda compartían un solo hilo y una
    // forma de onda lenta dejaba el cálculo de volumen — y con eso, el
    // cruce entero — esperando en la cola detrás suyo. Dentro de cada uno
    // las tareas se siguen serializando (decodificar con MediaCodec compite
    // por el mismo decodificador que la reproducción en curso), y cada
    // pedido revisa si sigue siendo el más nuevo antes de decodificar — si
    // el usuario ya cambió de canción, se aborta sin gastar tiempo en un
    // resultado que ya no sirve.
    private val analysisExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()
    private val waveformExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()
    private val spectrumExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()
    private val waveformRequestCounter = java.util.concurrent.atomic.AtomicLong(0)
    @Volatile private var latestWaveformRequestId: Long = 0
    private val spectrumRequestCounter = java.util.concurrent.atomic.AtomicLong(0)
    @Volatile private var latestSpectrumRequestId: Long = 0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, storageChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickDirectory" -> pickDirectory(result)
                    "listChildren" -> {
                        val uri = call.argument<String>("uri")
                        if (uri == null) {
                            result.error("BAD_ARGS", "Falta uri", null)
                        } else {
                            listChildren(uri, result)
                        }
                    }
                    "releasePermission" -> {
                        val uri = call.argument<String>("uri")
                        if (uri == null) {
                            result.error("BAD_ARGS", "Falta uri", null)
                        } else {
                            releasePermission(uri, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, importChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "importToDownloads" -> {
                        val sourceId = call.argument<Number>("mediaStoreId")
                        val fileName = call.argument<String>("fileName")
                        val mimeType = call.argument<String>("mimeType") ?: "audio/*"
                        if (sourceId == null || fileName == null) {
                            result.error("BAD_ARGS", "Faltan mediaStoreId/fileName", null)
                        } else {
                            importToDownloads(sourceId.toLong(), fileName, mimeType, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, analysisChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "analyzeLoudness" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("BAD_ARGS", "Falta path", null)
                        } else {
                            analyzeLoudness(path, result)
                        }
                    }
                    "analyzeWaveform" -> {
                        val path = call.argument<String>("path")
                        val buckets = call.argument<Number>("buckets")?.toInt() ?: 240
                        val mediaStoreId = call.argument<Number>("mediaStoreId")?.toInt() ?: -1
                        val positionFraction =
                            call.argument<Number>("positionFraction")?.toDouble() ?: 0.0
                        if (path == null) {
                            result.error("BAD_ARGS", "Falta path", null)
                        } else {
                            analyzeWaveform(path, buckets, mediaStoreId, positionFraction, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, waveformProgressEventsName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    waveformProgressSink = events
                }

                override fun onCancel(arguments: Any?) {
                    waveformProgressSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, bluetoothSyncChannelName)
            .setMethodCallHandler { call, result -> bluetoothSyncBridge.handle(call, result) }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, bluetoothSyncEventsName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    bluetoothSyncBridge.setEventSink(events)
                }

                override fun onCancel(arguments: Any?) {
                    bluetoothSyncBridge.setEventSink(null)
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, spectrumChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "analyzeSpectrogram" -> {
                        val path = call.argument<String>("path")
                        val mediaStoreId = call.argument<Number>("mediaStoreId")?.toInt() ?: -1
                        val positionFraction =
                            call.argument<Number>("positionFraction")?.toDouble() ?: 0.0
                        if (path == null) {
                            result.error("BAD_ARGS", "Falta path", null)
                        } else {
                            analyzeSpectrogram(path, mediaStoreId, positionFraction, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, spectrumProgressEventsName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    spectrumProgressSink = events
                }

                override fun onCancel(arguments: Any?) {
                    spectrumProgressSink = null
                }
            })
    }

    override fun onDestroy() {
        bluetoothSyncBridge.shutdown()
        analysisExecutor.shutdownNow()
        waveformExecutor.shutdownNow()
        spectrumExecutor.shutdownNow()
        super.onDestroy()
    }

    // ---- Storage Access Framework (pendrive) ----

    private fun pickDirectory(result: MethodChannel.Result) {
        if (pendingPickResult != null) {
            result.error("BUSY", "Ya hay una selección de carpeta en curso", null)
            return
        }
        pendingPickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        try {
            startActivityForResult(intent, pickDirectoryRequestCode)
        } catch (e: Exception) {
            pendingPickResult = null
            result.error("PICK_FAILED", e.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickDirectoryRequestCode) return

        val result = pendingPickResult
        pendingPickResult = null
        val treeUri = data?.data
        if (resultCode != Activity.RESULT_OK || treeUri == null) {
            result?.success(null)
            return
        }
        try {
            contentResolver.takePersistableUriPermission(
                treeUri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
        } catch (e: SecurityException) {
            result?.error("PERMISSION_FAILED", e.message, null)
            return
        }
        val docId = DocumentsContract.getTreeDocumentId(treeUri)
        val displayName = docId.substringAfterLast(':').ifEmpty { docId }
        result?.success(mapOf("uri" to treeUri.toString(), "name" to displayName))
    }

    private fun listChildren(uriString: String, result: MethodChannel.Result) {
        try {
            val uri = Uri.parse(uriString)
            // Para la raíz elegida con el picker, la uri es una "tree uri"
            // (sin segmento "document"); para subcarpetas ya viene con
            // ambos segmentos. Hay que sacar el documentId con la función
            // correcta en cada caso, o termina apuntando siempre a la raíz.
            val parentDocId = if (DocumentsContract.isDocumentUri(this, uri)) {
                DocumentsContract.getDocumentId(uri)
            } else {
                DocumentsContract.getTreeDocumentId(uri)
            }
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(uri, parentDocId)
            val projection = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE
            )
            val items = mutableListOf<Map<String, Any?>>()
            contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
                val idIdx = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameIdx = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val mimeIdx = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
                val sizeIdx = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_SIZE)
                while (cursor.moveToNext()) {
                    val docId = cursor.getString(idIdx)
                    val name = cursor.getString(nameIdx) ?: docId
                    val mime = cursor.getString(mimeIdx)
                    val size = cursor.getLong(sizeIdx)
                    val childUri = DocumentsContract.buildDocumentUriUsingTree(uri, docId)
                    items.add(
                        mapOf(
                            "name" to name,
                            "uri" to childUri.toString(),
                            "isDirectory" to (mime == DocumentsContract.Document.MIME_TYPE_DIR),
                            "size" to size
                        )
                    )
                }
            }
            result.success(items)
        } catch (e: Exception) {
            result.error("LIST_FAILED", e.message, null)
        }
    }

    private fun releasePermission(uriString: String, result: MethodChannel.Result) {
        try {
            contentResolver.releasePersistableUriPermission(
                Uri.parse(uriString),
                Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
        } catch (e: SecurityException) {
            // Puede fallar si ya no estaba persistido (p. ej. el pendrive se
            // desconectó); no importa, igual se saca de la lista guardada.
        }
        result.success(null)
    }

    // ---- Importar audios de WhatsApp a Download ----

    private fun importToDownloads(
        sourceMediaStoreId: Long,
        fileName: String,
        mimeType: String,
        result: MethodChannel.Result
    ) {
        try {
            val sourceUri = ContentUris.withAppendedId(
                MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                sourceMediaStoreId
            )

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.Audio.Media.DISPLAY_NAME, fileName)
                    put(MediaStore.Audio.Media.MIME_TYPE, mimeType)
                    put(MediaStore.Audio.Media.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                    put(MediaStore.Audio.Media.IS_PENDING, 1)
                }
                val destUri = contentResolver.insert(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, values)
                if (destUri == null) {
                    result.error("INSERT_FAILED", "No se pudo crear el destino en Download", null)
                    return
                }
                val input = contentResolver.openInputStream(sourceUri)
                if (input == null) {
                    contentResolver.delete(destUri, null, null)
                    result.error("SOURCE_NOT_FOUND", "No se pudo abrir el archivo de origen", null)
                    return
                }
                val output = contentResolver.openOutputStream(destUri)
                if (output == null) {
                    input.close()
                    contentResolver.delete(destUri, null, null)
                    result.error("OUTPUT_FAILED", "No se pudo escribir en Download", null)
                    return
                }
                input.use { i -> output.use { o -> i.copyTo(o) } }

                val donePending = ContentValues()
                donePending.put(MediaStore.Audio.Media.IS_PENDING, 0)
                contentResolver.update(destUri, donePending, null, null)
                result.success(destUri.toString())
            } else {
                val downloadsDir =
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                if (!downloadsDir.exists()) downloadsDir.mkdirs()
                val destFile = File(downloadsDir, fileName)
                val input = contentResolver.openInputStream(sourceUri)
                if (input == null) {
                    result.error("SOURCE_NOT_FOUND", "No se pudo abrir el archivo de origen", null)
                    return
                }
                input.use { i -> FileOutputStream(destFile).use { o -> i.copyTo(o) } }
                MediaScannerConnection.scanFile(
                    this, arrayOf(destFile.absolutePath), arrayOf(mimeType), null
                )
                result.success(destFile.absolutePath)
            }
        } catch (e: Exception) {
            result.error("IMPORT_FAILED", e.message, null)
        }
    }

    // ---- Análisis de volumen para el Mezclador automático ----

    private fun analyzeLoudness(path: String, result: MethodChannel.Result) {
        analysisExecutor.execute {
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND)
            val db = try {
                computeLoudnessDb(path)
            } catch (e: Exception) {
                null
            }
            runOnUiThread {
                if (db != null) result.success(db)
                else result.error("ANALYZE_FAILED", "No se pudo analizar el audio", null)
            }
        }
    }

    // Decodifica ~20s de audio desde el 30% de la canción (evita silencios
    // de intro y no hace falta procesar el archivo entero) y devuelve el
    // volumen promedio en dB (RMS relativo a la amplitud máxima de 16 bits).
    // Con un tope de tiempo real por si algún archivo no llega nunca a EOS.
    private fun computeLoudnessDb(path: String): Double {
        val extractor = MediaExtractor()
        extractor.setDataSource(path)
        try {
            var trackIndex = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    trackIndex = i
                    format = f
                    break
                }
            }
            if (trackIndex < 0 || format == null) {
                throw IllegalStateException("Sin pista de audio")
            }
            extractor.selectTrack(trackIndex)

            val durationUs = try {
                format.getLong(MediaFormat.KEY_DURATION)
            } catch (e: Exception) {
                0L
            }
            val windowUs = 20_000_000L
            val startUs = if (durationUs > windowUs * 2) (durationUs * 0.3).toLong() else 0L
            if (startUs > 0) extractor.seekTo(startUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)

            val mime = format.getString(MediaFormat.KEY_MIME)!!
            val codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            val bufferInfo = MediaCodec.BufferInfo()
            var sumSquares = 0.0
            var sampleCount = 0L
            var sawInputEOS = false
            var sawOutputEOS = false
            var windowExceeded = false
            val deadline = System.currentTimeMillis() + 15_000

            try {
                while (!sawOutputEOS && System.currentTimeMillis() < deadline) {
                    if (!sawInputEOS) {
                        val inIndex = codec.dequeueInputBuffer(10_000)
                        if (inIndex >= 0) {
                            if (windowExceeded) {
                                codec.queueInputBuffer(
                                    inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM
                                )
                                sawInputEOS = true
                            } else {
                                val inBuffer = codec.getInputBuffer(inIndex)!!
                                val sampleSize = extractor.readSampleData(inBuffer, 0)
                                if (sampleSize < 0) {
                                    codec.queueInputBuffer(
                                        inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM
                                    )
                                    sawInputEOS = true
                                } else {
                                    val presentationTimeUs = extractor.sampleTime
                                    codec.queueInputBuffer(
                                        inIndex, 0, sampleSize, presentationTimeUs, 0
                                    )
                                    extractor.advance()
                                    if (presentationTimeUs - startUs > windowUs) {
                                        windowExceeded = true
                                    }
                                }
                            }
                        }
                    }

                    val outIndex = codec.dequeueOutputBuffer(bufferInfo, 10_000)
                    if (outIndex >= 0) {
                        if (bufferInfo.size > 0) {
                            val outBuffer = codec.getOutputBuffer(outIndex)!!
                            outBuffer.position(bufferInfo.offset)
                            outBuffer.limit(bufferInfo.offset + bufferInfo.size)
                            val shortBuffer = outBuffer.order(ByteOrder.nativeOrder()).asShortBuffer()
                            while (shortBuffer.remaining() > 0) {
                                val sample = shortBuffer.get().toDouble()
                                sumSquares += sample * sample
                                sampleCount++
                            }
                        }
                        codec.releaseOutputBuffer(outIndex, false)
                        if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            sawOutputEOS = true
                        }
                    }
                }
            } finally {
                codec.stop()
                codec.release()
            }

            if (sampleCount == 0L) return -23.0

            val rms = sqrt(sumSquares / sampleCount)
            val maxAmplitude = 32768.0
            val db = 20 * log10(rms / maxAmplitude)
            return if (db.isFinite()) db.coerceIn(-60.0, 0.0) else -23.0
        } finally {
            extractor.release()
        }
    }

    // ---- Forma de onda para la vista estilo VirtualDJ ----

    // [positionFraction] (0.0-1.0) es dónde está el puntero de reproducción
    // ahora mismo: se decodifica primero desde ahí hacia adelante (lo
    // próximo que el usuario va a ver, igual que YouTube precargando hacia
    // adelante del video) y recién después se completa hacia atrás. Cada
    // pasada emite actualizaciones parciales por [waveformProgressEventsName]
    // a medida que decodifica, en vez de esperar al resultado completo.
    private fun analyzeWaveform(
        path: String,
        buckets: Int,
        mediaStoreId: Int,
        positionFraction: Double,
        result: MethodChannel.Result
    ) {
        val requestId = waveformRequestCounter.incrementAndGet()
        latestWaveformRequestId = requestId

        waveformExecutor.execute {
            if (requestId != latestWaveformRequestId) {
                // Se pidió otra forma de onda (cambió de canción) mientras
                // esta esperaba su turno en la cola: se descarta sin
                // decodificar nada, total ya no la va a mostrar nadie.
                runOnUiThread {
                    result.error("SUPERSEDED", "Se pidió otra canción antes de empezar", null)
                }
                return@execute
            }
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND)
            val stillValid = { requestId == latestWaveformRequestId }
            val peaks = DoubleArray(buckets)
            val startBucket = (positionFraction * buckets).toInt().coerceIn(0, buckets - 1)

            val onProgress: (DoubleArray) -> Unit = { snapshot ->
                if (stillValid()) {
                    runOnUiThread {
                        waveformProgressSink?.success(
                            mapOf(
                                "mediaStoreId" to mediaStoreId,
                                "peaks" to snapshot.toList()
                            )
                        )
                    }
                }
            }

            val ok = try {
                // Pasada 1: desde el puntero hacia el final.
                decodeWaveformRange(path, buckets, startBucket, buckets, peaks, stillValid, onProgress)
                // decodeWaveformRange corta su bucle apenas stillValid() da
                // false (se pidió otra canción) pero vuelve normalmente, sin
                // tirar excepción — sin este chequeo, un análisis
                // interrumpido a la mitad se reportaba igual como
                // "terminado", y el tramo que no llegó a decodificar
                // (relleno en cero) quedaba cacheado como si fuera la onda
                // completa para siempre.
                if (!stillValid()) throw IllegalStateException("superseded")
                // Pasada 2: desde el principio hasta el puntero, si quedó algo.
                if (startBucket > 0) {
                    decodeWaveformRange(path, buckets, 0, startBucket, peaks, stillValid, onProgress)
                    if (!stillValid()) throw IllegalStateException("superseded")
                }
                true
            } catch (e: Exception) {
                false
            }

            runOnUiThread {
                if (ok) result.success(peaks.toList())
                else result.error("ANALYZE_FAILED", "No se pudo generar la forma de onda", null)
            }
        }
    }

    // Decodifica el tramo [fromBucket, toBucketExclusive) de [path] (a
    // diferencia de computeLoudnessDb, acá hace falta el perfil de amplitud
    // real, no solo un ventaneo) escribiendo picos normalizados (0.0-1.0)
    // directo en [peaks] — así una pasada puede completar lo que dejó la
    // otra sin pisarla. [onProgress] se llama cada ~400ms con una copia del
    // estado actual. Con tope de tiempo real y chequeo de [stillValid] en
    // cada vuelta por si el usuario ya cambió de canción.
    private fun decodeWaveformRange(
        path: String,
        buckets: Int,
        fromBucket: Int,
        toBucketExclusive: Int,
        peaks: DoubleArray,
        stillValid: () -> Boolean,
        onProgress: (DoubleArray) -> Unit
    ) {
        val extractor = MediaExtractor()
        extractor.setDataSource(path)
        try {
            var trackIndex = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    trackIndex = i
                    format = f
                    break
                }
            }
            if (trackIndex < 0 || format == null) {
                throw IllegalStateException("Sin pista de audio")
            }
            extractor.selectTrack(trackIndex)

            val durationUs = try {
                format.getLong(MediaFormat.KEY_DURATION)
            } catch (e: Exception) {
                0L
            }
            val safeDuration = if (durationUs > 0) durationUs else 1L
            val startUs = (fromBucket.toDouble() / buckets * safeDuration).toLong()
            if (startUs > 0) extractor.seekTo(startUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)

            val mime = format.getString(MediaFormat.KEY_MIME)!!
            val codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            val bufferInfo = MediaCodec.BufferInfo()
            var sawInputEOS = false
            var sawOutputEOS = false
            val deadline = System.currentTimeMillis() + 15_000
            var lastEmit = System.currentTimeMillis()

            try {
                while (!sawOutputEOS && System.currentTimeMillis() < deadline && stillValid()) {
                    if (!sawInputEOS) {
                        val inIndex = codec.dequeueInputBuffer(10_000)
                        if (inIndex >= 0) {
                            val inBuffer = codec.getInputBuffer(inIndex)!!
                            val sampleSize = extractor.readSampleData(inBuffer, 0)
                            if (sampleSize < 0) {
                                codec.queueInputBuffer(
                                    inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM
                                )
                                sawInputEOS = true
                            } else {
                                val presentationTimeUs = extractor.sampleTime
                                codec.queueInputBuffer(inIndex, 0, sampleSize, presentationTimeUs, 0)
                                extractor.advance()
                            }
                        }
                    }

                    val outIndex = codec.dequeueOutputBuffer(bufferInfo, 10_000)
                    if (outIndex >= 0) {
                        var reachedEnd = false
                        if (bufferInfo.size > 0) {
                            val bucket = ((bufferInfo.presentationTimeUs.toDouble() / safeDuration) * buckets)
                                .toInt().coerceIn(0, buckets - 1)
                            if (bucket >= toBucketExclusive) {
                                // Ya cubrimos el tramo pedido en esta pasada;
                                // no hace falta seguir decodificando el resto
                                // ahora (lo cubre la otra pasada si hace falta).
                                reachedEnd = true
                            } else {
                                val outBuffer = codec.getOutputBuffer(outIndex)!!
                                outBuffer.position(bufferInfo.offset)
                                outBuffer.limit(bufferInfo.offset + bufferInfo.size)
                                val shortBuffer = outBuffer.order(ByteOrder.nativeOrder()).asShortBuffer()
                                var localPeak = 0
                                while (shortBuffer.remaining() > 0) {
                                    val sample = kotlin.math.abs(shortBuffer.get().toInt())
                                    if (sample > localPeak) localPeak = sample
                                }
                                val amplitude = (localPeak / 32768.0).coerceIn(0.0, 1.0)
                                if (amplitude > peaks[bucket]) peaks[bucket] = amplitude
                            }
                        }
                        codec.releaseOutputBuffer(outIndex, false)
                        if (reachedEnd ||
                            (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                        ) {
                            sawOutputEOS = true
                        }
                    }

                    val now = System.currentTimeMillis()
                    if (now - lastEmit > 400) {
                        lastEmit = now
                        onProgress(peaks.copyOf())
                    }
                }
            } finally {
                codec.stop()
                codec.release()
            }
            onProgress(peaks.copyOf())
        } finally {
            extractor.release()
        }
    }

    // ---- Espectro en vivo para el Ecualizador ----

    // El efecto Visualizer del sistema (android.media.audiofx.Visualizer)
    // queda a merced de que el fabricante lo soporte para la sesión de una
    // app puntual — confirmado en un equipo real que AudioFlinger lo
    // rechaza (status -1 / initCheck -3), algo que no se puede arreglar
    // desde acá. Esto evita ese problema del todo: decodifica el PCM
    // nosotros mismos con MediaExtractor/MediaCodec —igual que la forma de
    // onda, que sí funciona en cualquier equipo porque no depende de un
    // efecto de audio del sistema— y calcula una FFT propia por ventana de
    // tiempo. El resultado es el "espectrograma" completo de la canción (un
    // array de bandas cada [spectrumFrameStepMs]): se calcula una sola vez
    // y del lado de Dart alcanza con indexarlo por la posición de
    // reproducción actual, sin decodificar nada más mientras suena.
    private val spectrumFftSize = 2048
    private val spectrumFrameStepMs = 100
    private val spectrumBandCount = 24

    private fun analyzeSpectrogram(
        path: String,
        mediaStoreId: Int,
        positionFraction: Double,
        result: MethodChannel.Result
    ) {
        val requestId = spectrumRequestCounter.incrementAndGet()
        latestSpectrumRequestId = requestId

        spectrumExecutor.execute {
            if (requestId != latestSpectrumRequestId) {
                runOnUiThread {
                    result.error("SUPERSEDED", "Se pidió otra canción antes de empezar", null)
                }
                return@execute
            }
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND)
            val stillValid = { requestId == latestSpectrumRequestId }

            val computedFrames = try {
                val durationMs = probeDurationMs(path)
                val totalFrames =
                    (durationMs / spectrumFrameStepMs).toInt().coerceAtLeast(1)
                val frameBands = Array(totalFrames) { FloatArray(spectrumBandCount) }
                val startFrame =
                    (positionFraction * totalFrames).toInt().coerceIn(0, totalFrames - 1)

                val onProgress: () -> Unit = {
                    if (stillValid()) {
                        runOnUiThread {
                            spectrumProgressSink?.success(
                                mapOf(
                                    "mediaStoreId" to mediaStoreId,
                                    "frames" to frameBands.map { it.toList() },
                                    "frameStepMs" to spectrumFrameStepMs
                                )
                            )
                        }
                    }
                }

                // Pasada 1: desde el puntero hacia el final (lo próximo que
                // el usuario va a ver primero). Pasada 2: desde el
                // principio hasta el puntero, si quedó algo — igual que la
                // forma de onda.
                decodeSpectrogramRange(
                    path, frameBands, startFrame, totalFrames, stillValid, onProgress
                )
                if (!stillValid()) throw IllegalStateException("superseded")
                if (startFrame > 0) {
                    decodeSpectrogramRange(path, frameBands, 0, startFrame, stillValid, onProgress)
                    if (!stillValid()) throw IllegalStateException("superseded")
                }
                frameBands
            } catch (e: Exception) {
                null
            }

            runOnUiThread {
                if (computedFrames != null) {
                    result.success(
                        mapOf(
                            "frames" to computedFrames.map { it.toList() },
                            "frameStepMs" to spectrumFrameStepMs
                        )
                    )
                } else {
                    result.error("ANALYZE_FAILED", "No se pudo generar el espectrograma", null)
                }
            }
        }
    }

    private fun probeDurationMs(path: String): Long {
        val extractor = MediaExtractor()
        extractor.setDataSource(path)
        try {
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    val durationUs = try {
                        f.getLong(MediaFormat.KEY_DURATION)
                    } catch (e: Exception) {
                        0L
                    }
                    return (durationUs / 1000).coerceAtLeast(1000)
                }
            }
            return 1000
        } finally {
            extractor.release()
        }
    }

    // Decodifica el tramo [fromFrame, toFrameExclusive) de [path] calculando
    // una FFT por cada [spectrumFrameStepMs] de audio (ventanas de
    // [spectrumFftSize] muestras, sin solapar entre sí — de sobra para una
    // barra que se actualiza 10 veces por segundo) y guardando las bandas
    // resultantes directo en [frames]. Mismo esquema de tope de tiempo real
    // y chequeo de [stillValid] que la forma de onda, por si el usuario
    // cambia de canción a mitad de la decodificación.
    private fun decodeSpectrogramRange(
        path: String,
        frames: Array<FloatArray>,
        fromFrame: Int,
        toFrameExclusive: Int,
        stillValid: () -> Boolean,
        onProgress: () -> Unit
    ) {
        val extractor = MediaExtractor()
        extractor.setDataSource(path)
        try {
            var trackIndex = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                val mime = f.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    trackIndex = i
                    format = f
                    break
                }
            }
            if (trackIndex < 0 || format == null) {
                throw IllegalStateException("Sin pista de audio")
            }
            extractor.selectTrack(trackIndex)

            val sampleRate = try {
                format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            } catch (e: Exception) {
                44100
            }
            val channelCount = try {
                format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            } catch (e: Exception) {
                2
            }
            val frameStepSamples =
                (sampleRate.toLong() * spectrumFrameStepMs / 1000L).toInt().coerceAtLeast(1)

            val startUs = fromFrame.toLong() * spectrumFrameStepMs * 1000L
            if (startUs > 0) extractor.seekTo(startUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)

            val mime = format.getString(MediaFormat.KEY_MIME)!!
            val codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()

            val bufferInfo = MediaCodec.BufferInfo()
            var sawInputEOS = false
            var sawOutputEOS = false
            val deadline = System.currentTimeMillis() + 15_000
            var lastEmit = System.currentTimeMillis()

            val window = ShortArray(spectrumFftSize)
            var samplesSinceWindowStart = 0

            try {
                while (!sawOutputEOS && System.currentTimeMillis() < deadline && stillValid()) {
                    if (!sawInputEOS) {
                        val inIndex = codec.dequeueInputBuffer(10_000)
                        if (inIndex >= 0) {
                            val inBuffer = codec.getInputBuffer(inIndex)!!
                            val sampleSize = extractor.readSampleData(inBuffer, 0)
                            if (sampleSize < 0) {
                                codec.queueInputBuffer(
                                    inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM
                                )
                                sawInputEOS = true
                            } else {
                                val presentationTimeUs = extractor.sampleTime
                                codec.queueInputBuffer(inIndex, 0, sampleSize, presentationTimeUs, 0)
                                extractor.advance()
                            }
                        }
                    }

                    val outIndex = codec.dequeueOutputBuffer(bufferInfo, 10_000)
                    if (outIndex >= 0) {
                        var reachedEnd = false
                        if (bufferInfo.size > 0) {
                            val outBuffer = codec.getOutputBuffer(outIndex)!!
                            outBuffer.position(bufferInfo.offset)
                            outBuffer.limit(bufferInfo.offset + bufferInfo.size)
                            val shortBuffer = outBuffer.order(ByteOrder.nativeOrder()).asShortBuffer()

                            while (!reachedEnd && shortBuffer.remaining() >= channelCount) {
                                var sum = 0
                                for (c in 0 until channelCount) sum += shortBuffer.get().toInt()
                                val mono = (sum / channelCount).toShort()

                                if (samplesSinceWindowStart < spectrumFftSize) {
                                    window[samplesSinceWindowStart] = mono
                                }
                                samplesSinceWindowStart++

                                if (samplesSinceWindowStart >= frameStepSamples) {
                                    if (samplesSinceWindowStart >= spectrumFftSize) {
                                        val frameIndex = (
                                            bufferInfo.presentationTimeUs / 1000L /
                                                spectrumFrameStepMs
                                            ).toInt()
                                        if (frameIndex >= toFrameExclusive) {
                                            reachedEnd = true
                                        } else if (frameIndex in frames.indices) {
                                            val mags = SpectrumMath.magnitudes(window)
                                            frames[frameIndex] = SpectrumMath.toBands(
                                                mags, spectrumBandCount, spectrumFftSize
                                            )
                                        }
                                    }
                                    samplesSinceWindowStart = 0
                                }
                            }
                        }
                        codec.releaseOutputBuffer(outIndex, false)
                        if (reachedEnd ||
                            (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                        ) {
                            sawOutputEOS = true
                        }
                    }

                    val now = System.currentTimeMillis()
                    if (now - lastEmit > 500) {
                        lastEmit = now
                        onProgress()
                    }
                }
            } finally {
                codec.stop()
                codec.release()
            }
            onProgress()
        } finally {
            extractor.release()
        }
    }
}
