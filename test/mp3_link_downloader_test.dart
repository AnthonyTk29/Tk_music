import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tk_music/services/mp3_link_downloader.dart';

Uint8List _bytes(List<int> head) =>
    Uint8List.fromList([...head, ...List.filled(64, 0x55)]);

void main() {
  group('qué se acepta como MP3', () {
    test('con etiqueta ID3', () {
      expect(mp3Problem(_bytes('ID3'.codeUnits)), isNull);
    });

    test('sin etiqueta, empieza directo con audio MPEG Layer III', () {
      expect(mp3Problem(_bytes([0xFF, 0xFB, 0x90, 0x44])), isNull);
      expect(mp3Problem(_bytes([0, 0, 0xFF, 0xF3, 0x64, 0])), isNull);
    });

    test('una página web se rechaza avisando qué es', () {
      final html = _bytes('  <!DOCTYPE html><html>'.codeUnits);
      expect(mp3Problem(html), contains('página web'));
    });

    test('otros formatos de audio se rechazan', () {
      expect(mp3Problem(_bytes([0, 0, 0, 0x20, ...'ftypM4A '.codeUnits])),
          contains('M4A'));
      expect(mp3Problem(_bytes('OggS'.codeUnits)), contains('OGG'));
      expect(mp3Problem(_bytes('fLaC'.codeUnits)), contains('FLAC'));
      expect(mp3Problem(_bytes('RIFF'.codeUnits)), contains('WAV'));
      expect(mp3Problem(_bytes('PK'.codeUnits)), contains('ZIP'));
      // Audio MPEG pero Layer II (MP2), no MP3.
      expect(mp3Problem(_bytes([0xFF, 0xFD, 0x90, 0x44])), isNotNull);
    });
  });

  group('enlaces', () {
    test('solo http/https', () {
      expect(normalizeMp3Link('hola'), isNull);
      expect(normalizeMp3Link('ftp://x.com/a.mp3'), isNull);
      expect(normalizeMp3Link(' https://x.com/a.mp3 ').toString(),
          'https://x.com/a.mp3');
    });

    test('Google Drive compartido pasa a descarga directa', () {
      final url = normalizeMp3Link(
          'https://drive.google.com/file/d/1AbC_d-9/view?usp=sharing')!;
      expect(url.host, 'drive.usercontent.google.com');
      expect(url.queryParameters['id'], '1AbC_d-9');
    });

    test('Dropbox compartido pasa a descarga directa', () {
      final url =
          normalizeMp3Link('https://www.dropbox.com/s/abc/tema.mp3?dl=0')!;
      expect(url.queryParameters['dl'], '1');
    });

    test('las páginas de streaming no se descargan', () {
      for (final link in [
        'https://www.youtube.com/watch?v=abc',
        'https://youtu.be/abc',
        'https://music.youtube.com/watch?v=abc',
        'https://open.spotify.com/track/abc',
        'https://soundcloud.com/a/b',
      ]) {
        expect(isStreamingPage(normalizeMp3Link(link)!), isTrue, reason: link);
      }
      expect(
          isStreamingPage(Uri.parse('https://miservidor.com/a.mp3')), isFalse);
    });
  });

  group('nombre del archivo', () {
    final url = Uri.parse('https://x.com/musica/Tema%20Uno.mp3');

    test('usa artista y título del MP3', () {
      expect(mp3FileName(url: url, title: 'Mi tema', artist: 'Grupo'),
          'Grupo - Mi tema.mp3');
    });

    test('si no, el que manda el servidor (también en UTF-8)', () {
      expect(
          mp3FileName(
              url: url,
              contentDisposition:
                  "attachment; filename=\"a.mp3\"; filename*=UTF-8''Canci%C3%B3n.mp3"),
          'Canción.mp3');
      expect(
          mp3FileName(
              url: url, contentDisposition: 'attachment; filename="b.mp3"'),
          'b.mp3');
    });

    test('si no, el del enlace, sin caracteres prohibidos', () {
      expect(mp3FileName(url: url), 'Tema Uno.mp3');
      expect(
          mp3FileName(url: url, title: 'AC/DC: "Back"?'), 'AC_DC_ _Back__.mp3');
    });
  });

  group('descarga', () {
    late HttpServer server;
    late String base;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      // El entorno de test responde 400 a todo pedido HTTP: acá se usa un
      // servidor local de verdad.
      HttpOverrides.global = null;
      final temp = await Directory.systemTemp.createTemp('tk_dl_test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (call) async => temp.path);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((request) {
        final res = request.response;
        switch (request.uri.path) {
          case '/tema.mp3':
            res.headers.contentType = ContentType('audio', 'mpeg');
            res.contentLength = 3 + 20000;
            res.add('ID3'.codeUnits);
            res.add(List.filled(20000, 0x55));
          case '/pagina':
            res.headers.contentType = ContentType.html;
            res.write('<html><body>${'x' * 5000}</body></html>');
          default:
            res.statusCode = 404;
        }
        res.close();
      });
    });

    tearDownAll(() => server.close(force: true));

    test('baja un MP3 informando el avance', () async {
      final progress = <int>[];
      final mp3 = await Mp3LinkDownloader().download('$base/tema.mp3',
          onProgress: (received, total) {
        expect(total, 20003);
        progress.add(received);
      });
      expect(await mp3.file.length(), 20003);
      expect(progress.last, 20003);
      expect(mp3.fileName, 'tema.mp3');
      await mp3.file.delete();
    });

    test('una página web no se guarda', () async {
      await expectLater(
          Mp3LinkDownloader().download('$base/pagina'),
          throwsA(isA<Mp3LinkException>()
              .having((e) => e.message, 'mensaje', contains('página web'))));
    });

    test('un enlace roto avisa que no existe', () async {
      await expectLater(
          Mp3LinkDownloader().download('$base/nada.mp3'),
          throwsA(isA<Mp3LinkException>()
              .having((e) => e.message, 'mensaje', contains('no existe'))));
    });
  });
}
