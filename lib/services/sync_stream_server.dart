import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

/// Servidor HTTP local (solo 127.0.0.1) que le entrega al reproductor un
/// archivo que todavía se está recibiendo por Bluetooth: así el invitado de
/// "Sincronizar con otro dispositivo" empieza a sonar sin esperar la canción
/// entera (streaming). El reproductor pide rangos de bytes como a cualquier
/// servidor; si pide algo que todavía no llegó, la respuesta espera a que
/// llegue en vez de fallar.
///
/// Sirve igual para just_audio (Android) que para media_kit (desktop): los
/// dos saben reproducir una URL http con peticiones por rango.
class SyncStreamServer {
  HttpServer? _server;
  final Map<String, _GrowingFile> _files = {};

  static const _pieceSize = 64 * 1024;
  static const _maxWait = Duration(minutes: 2);

  /// URL del archivo [path] (que se llena de a poco hasta [total] bytes).
  Future<Uri> register(String id,
      {required String path, required int total}) async {
    final server = _server ??= await _start();
    _files[id]?.abort();
    _files[id] = _GrowingFile(path: path, total: total);
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      pathSegments: ['track', id],
    );
  }

  /// Bytes ya escritos: `[0, head)` más `[tailFrom, tailEnd)`.
  void update(String id,
      {required int head, required int tailFrom, required int tailEnd}) {
    final file = _files[id];
    if (file == null) return;
    file
      ..head = head
      ..tailFrom = tailFrom
      ..tailEnd = tailEnd
      ..notify();
  }

  void complete(String id) {
    final file = _files[id];
    if (file == null) return;
    file
      ..complete = true
      ..notify();
  }

  void abort(String id) => _files.remove(id)?.abort();

  Future<void> close() async {
    for (final file in _files.values) {
      file.abort();
    }
    _files.clear();
    await _server?.close(force: true);
    _server = null;
  }

  Future<HttpServer> _start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) => unawaited(_handle(request)));
    return server;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final segments = request.uri.pathSegments;
    final file = segments.length == 2 ? _files[segments[1]] : null;
    if (file == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }

    var start = 0;
    var end = file.total - 1;
    var partial = false;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final match =
        range == null ? null : RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
    if (match != null) {
      partial = true;
      final from = match.group(1)!;
      final to = match.group(2)!;
      if (from.isEmpty) {
        // "bytes=-N": los últimos N bytes.
        start = math.max(0, file.total - int.parse(to));
      } else {
        start = int.parse(from);
        if (to.isNotEmpty) end = math.min(int.parse(to), file.total - 1);
      }
    }
    if (file.total == 0 || start >= file.total || start > end) {
      response
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */${file.total}');
      await response.close();
      return;
    }

    response
      ..statusCode = partial ? HttpStatus.partialContent : HttpStatus.ok
      ..headers.contentType = ContentType.parse(_mimeFor(file.path))
      ..headers.contentLength = end - start + 1
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (partial) {
      response.headers.set(
          HttpHeaders.contentRangeHeader, 'bytes $start-$end/${file.total}');
    }
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }

    RandomAccessFile? raf;
    try {
      raf = await File(file.path).open();
      var position = start;
      while (position <= end) {
        final length = math.min(_pieceSize, end - position + 1);
        final waitedSince = DateTime.now();
        while (!file.has(position, position + length)) {
          if (file.aborted ||
              DateTime.now().difference(waitedSince) > _maxWait) {
            throw const HttpException('Archivo no disponible');
          }
          await Future.any([
            file.changed(),
            Future<void>.delayed(const Duration(seconds: 2))
          ]);
        }
        await raf.setPosition(position);
        response.add(await raf.read(length));
        await response.flush();
        position += length;
      }
    } catch (_) {
      // El reproductor cortó la conexión (seek, cambio de canción) o el
      // archivo se descartó: no hay nada más que mandar.
    } finally {
      await raf?.close();
      try {
        await response.close();
      } catch (_) {}
    }
  }

  static String _mimeFor(String path) {
    final ext = path.split('.').last.toLowerCase();
    return switch (ext) {
      'm4a' || 'aac' || 'mp4' => 'audio/mp4',
      'flac' => 'audio/flac',
      'ogg' || 'opus' => 'audio/ogg',
      'wav' => 'audio/wav',
      _ => 'audio/mpeg',
    };
  }
}

class _GrowingFile {
  _GrowingFile({required this.path, required this.total})
      : tailFrom = total,
        tailEnd = total;

  final String path;
  final int total;
  int head = 0;
  int tailFrom;
  int tailEnd;
  bool complete = false;
  bool aborted = false;
  Completer<void>? _waiter;

  bool has(int start, int end) {
    if (complete) return true;
    if (end <= head) return true;
    if (start >= tailFrom && end <= tailEnd) return true;
    // El principio ya alcanzó al final que llegó primero: son un solo tramo.
    return head >= tailFrom && end <= tailEnd;
  }

  Future<void> changed() => (_waiter ??= Completer<void>()).future;

  void notify() {
    final waiter = _waiter;
    _waiter = null;
    waiter?.complete();
  }

  void abort() {
    aborted = true;
    notify();
  }
}
