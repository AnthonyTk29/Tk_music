import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tk_music/services/sync_stream_server.dart';

void main() {
  late Directory dir;
  late SyncStreamServer server;
  late HttpClient client;

  const total = 1000 * 1024;
  final content = Uint8List.fromList(List.generate(total, (i) => i % 251));

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sync_stream_test');
    server = SyncStreamServer();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.close();
    await dir.delete(recursive: true);
  });

  /// Archivo del tamaño final con solo [ranges] escritos (como lo deja el
  /// puente nativo mientras llegan los trozos).
  Future<File> partialFile(List<(int, int)> ranges) async {
    final file = File('${dir.path}/song.mp3');
    final raf = await file.open(mode: FileMode.write);
    await raf.truncate(total);
    for (final (start, end) in ranges) {
      await raf.setPosition(start);
      await raf.writeFrom(content, start, end);
    }
    await raf.close();
    return file;
  }

  Future<void> writeRange(File file, int start, int end) async {
    final raf = await file.open(mode: FileMode.append);
    await raf.setPosition(start);
    await raf.writeFrom(content, start, end);
    await raf.close();
  }

  Future<HttpClientResponse> get(Uri url, {String? range}) async {
    final request = await client.getUrl(url);
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    return request.close();
  }

  Future<List<int>> body(HttpClientResponse response) =>
      response.fold<List<int>>([], (acc, chunk) => acc..addAll(chunk));

  test('sirve de una lo que ya llegó, con rango y cabeceras', () async {
    final file = await partialFile([(0, 300 * 1024)]);
    final url = await server.register('t1', path: file.path, total: total);
    server.update('t1', head: 300 * 1024, tailFrom: total, tailEnd: total);

    final response = await get(url, range: 'bytes=1024-2047');
    expect(response.statusCode, HttpStatus.partialContent);
    expect(response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 1024-2047/$total');
    expect(response.headers.contentType?.mimeType, 'audio/mpeg');
    expect(await body(response), content.sublist(1024, 2048));
  });

  test('el final que llegó primero se sirve aunque falte el medio', () async {
    const tailFrom = total - 256 * 1024;
    final file = await partialFile([(0, 64 * 1024), (tailFrom, total)]);
    final url = await server.register('t2', path: file.path, total: total);
    server.update('t2', head: 64 * 1024, tailFrom: tailFrom, tailEnd: total);

    // "Los últimos 128 bytes" (tags ID3v1).
    final response = await get(url, range: 'bytes=-128');
    expect(await body(response), content.sublist(total - 128));
  });

  test('lo que todavía no llegó espera y se entrega cuando llega', () async {
    final file = await partialFile([(0, 100 * 1024)]);
    final url = await server.register('t3', path: file.path, total: total);
    server.update('t3', head: 100 * 1024, tailFrom: total, tailEnd: total);

    final pending = get(url, range: 'bytes=0-${200 * 1024 - 1}').then(body);
    var done = false;
    unawaited(pending.then((_) => done = true));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(done, isFalse, reason: 'faltan bytes: tiene que esperar');

    await writeRange(file, 100 * 1024, 200 * 1024);
    server.update('t3', head: 200 * 1024, tailFrom: total, tailEnd: total);
    expect(await pending.timeout(const Duration(seconds: 5)),
        content.sublist(0, 200 * 1024));
  });

  test('un archivo descartado corta la respuesta en vez de colgarla', () async {
    final file = await partialFile([(0, 64 * 1024)]);
    final url = await server.register('t4', path: file.path, total: total);
    server.update('t4', head: 64 * 1024, tailFrom: total, tailEnd: total);

    // El corte llega como "Connection closed" al cliente: es lo esperado.
    final pending = get(url).then(body).catchError((Object _) => <int>[]);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    server.abort('t4');
    final received = await pending.timeout(const Duration(seconds: 5));
    expect(received.length, lessThan(total));
  });
}
