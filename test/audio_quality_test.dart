import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/presentation/widgets/dj/dj_file_browser.dart';
import 'package:tk_music/services/dj/audio_quality.dart';
import 'package:tk_music/services/dj/dj_mixer.dart';

const _libmpv = r'build\windows\x64\runner\Debug\libmpv-2.dll';

CopyFacts _copy(
  String name, {
  int? kbps,
  int rate = 44100,
  int channels = 2,
  int bits = 16,
  int ms = 240000,
  double? db,
  int size = 5000000,
  String? fake,
}) =>
    CopyFacts(
      path: 'C:/m/$name',
      size: size,
      modified: DateTime(2024),
      info: AudioInfo(
        bitrate: kbps == null ? null : kbps * 1000,
        sampleRate: rate,
        channels: channels,
        bitsPerSample: bits,
        durationMs: ms,
        realFormat: fake,
      ),
      loudnessDb: db,
    );

/// Calidad, volumen y papelera sin el plugin nativo.
class _FakeQuality extends AudioQualityService {
  _FakeQuality(this.info, this.loudness);
  final Map<String, AudioInfo> info;
  final Map<String, double> loudness;
  final recycled = <String>[];

  @override
  AudioInfo? cachedInfo(String path) => info[path];
  @override
  double? cachedLoudness(String path) => loudness[path];
  @override
  Future<void> loadInfo(Iterable<String> paths) async {}
  @override
  Future<double?> measureLoudness(String path) async => loudness[path];
  @override
  Future<Set<String>> recycle(List<String> paths) async {
    recycled.addAll(paths);
    return paths.toSet();
  }

  @override
  CopyFacts factsFor(String path, int size, DateTime modified) => CopyFacts(
      path: path,
      size: size,
      modified: modified,
      info: info[path],
      loudnessDb: loudness[path]);
}

void main() {
  group('elige la mejor copia', () {
    test('la de más calidad gana', () {
      final v = judgeCopies([
        _copy('a.mp3', kbps: 128, db: -10),
        _copy('b.mp3', kbps: 320, db: -10),
        _copy('c.mp3', kbps: 192, db: -10),
      ]);
      expect(v['C:/m/b.mp3']!.recommended, isTrue);
      expect(v['C:/m/a.mp3']!.lowQuality, isTrue);
      expect(v['C:/m/c.mp3']!.lowQuality, isFalse);
      expect(v.values.where((x) => x.recommended), hasLength(1));
    });

    test('un WAV le gana a un MP3 de 320', () {
      final v = judgeCopies([
        _copy('a.mp3', kbps: 320),
        _copy('a.wav', kbps: 1411),
      ]);
      expect(v['C:/m/a.wav']!.recommended, isTrue);
    });

    test('mono o de 22 kHz es baja calidad aunque diga 320', () {
      expect(_copy('x.mp3', kbps: 320, channels: 1).lowQuality, isTrue);
      expect(_copy('x.mp3', kbps: 320, rate: 22050).lowQuality, isTrue);
      // Como el "023 - LA DROGA.mp3" real: 40 kbps, 22 kHz, mono.
      final droga = _copy('droga.mp3', kbps: 40, rate: 22050, channels: 1);
      expect(droga.lowQuality, isTrue);
      expect(droga.qualityPoints, lessThan(0));
    });

    test('cortada y más baja pierden aunque tengan buen bitrate', () {
      final v = judgeCopies([
        _copy('corta.mp3', kbps: 320, ms: 200000, db: -10),
        _copy('baja.mp3', kbps: 320, db: -17),
        _copy('bien.mp3', kbps: 256, db: -10),
      ]);
      expect(v['C:/m/bien.mp3']!.recommended, isTrue);
      expect(v['C:/m/corta.mp3']!.cut, isTrue);
      expect(v['C:/m/baja.mp3']!.lowVolume, isTrue);
      expect(v['C:/m/baja.mp3']!.reasons.join(), contains('7,0 dB más baja'));
    });

    test('volumen bajo también sola', () {
      final v = judgeCopies([_copy('x.mp3', kbps: 320, db: -24)]);
      expect(v['C:/m/x.mp3']!.lowVolume, isTrue);
      expect(v['C:/m/x.mp3']!.recommended, isFalse);
    });

    test('sin bitrate lo estima por peso y duración', () {
      final c = CopyFacts(
        path: 'x.mp3',
        size: 320 * 1000 ~/ 8 * 200, // 200 s a 320 kbps
        modified: DateTime(2024),
        info: const AudioInfo(durationMs: 200000),
      );
      expect(c.kbps, 320);
    });
  });

  group('formato falso', () {
    test('reconoce el contenido por los primeros bytes', () {
      expect(sniffAudioFormat('ID3\x04'.codeUnits), 'MP3');
      expect(sniffAudioFormat([0xFF, 0xFB, 0x90, 0x00]), 'MP3');
      expect(sniffAudioFormat('RIFF\x00\x00\x00\x00WAVE'.codeUnits), 'WAV');
      // Como "José José - Amnesia (Video Oficial).mp3": un M4A de YouTube.
      expect(sniffAudioFormat([0, 0, 0, 0x18, ...'ftypdash'.codeUnits]), 'M4A');
      expect(sniffAudioFormat([0x1A, 0x45, 0xDF, 0xA3]), 'WEBM');
      expect(sniffAudioFormat('abcd'.codeUnits), isNull);
    });

    test('marca el archivo renombrado', () async {
      final dir = await Directory.systemTemp.createTemp('tk_fake');
      addTearDown(() => dir.delete(recursive: true));
      final fake = File(p.join(dir.path, 'amnesia.mp3'))
        ..writeAsBytesSync([0, 0, 0, 0x18, ...'ftypdash'.codeUnits, 0, 0]);
      final real = File(p.join(dir.path, 'bien.mp3'))
        ..writeAsBytesSync([...'ID3'.codeUnits, 4, 0, 0]);
      expect(await realFormatOf(fake.path), 'M4A');
      expect(await realFormatOf(real.path), isNull);
      final c = _copy('amnesia.mp3', kbps: 128, fake: 'M4A');
      expect(c.qualityLabel, 'M4A (falso)');
      final v = judgeCopies([c, _copy('amnesia2.mp3', kbps: 128)]);
      expect(v['C:/m/amnesia.mp3']!.fakeFormat, 'M4A');
      expect(v['C:/m/amnesia2.mp3']!.recommended, isTrue);
    });
  });

  group('gestor de archivos', () {
    final hasMpv = Platform.isWindows && File(_libmpv).existsSync();
    setUpAll(() {
      if (hasMpv) {
        MediaKit.ensureInitialized(libmpv: File(_libmpv).absolute.path);
      }
    });

    testWidgets(
        'revisa las repetidas, marca la peor y la manda a la papelera con '
        'confirmación', (tester) async {
      tester.view.physicalSize = const Size(1500, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      late Directory dir;
      late DjMixer mixer;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('tk_browser');
        mixer = DjMixer();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      final good = p.join(dir.path, 'La droga.mp3');
      final bad = p.join(dir.path, '003 - LA DROGA.mp3');
      final other = p.join(dir.path, 'Otra.mp3');
      File(good).writeAsBytesSync(List.filled(9000, 1));
      File(bad).writeAsBytesSync(List.filled(4000, 1));
      File(other).writeAsBytesSync(List.filled(5000, 1));
      final quality = _FakeQuality({
        good: const AudioInfo(
            bitrate: 320000,
            sampleRate: 44100,
            channels: 2,
            durationMs: 240000),
        bad: const AudioInfo(
            bitrate: 128000,
            sampleRate: 44100,
            channels: 2,
            durationMs: 240000),
        other: const AudioInfo(
            bitrate: 256000,
            sampleRate: 44100,
            channels: 2,
            durationMs: 200000),
      }, {
        good: -10,
        bad: -16,
        other: -11,
      });
      final deleted = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DjFileBrowser(
            mixer: mixer,
            quality: quality,
            librarySongs: [
              Song(mediaStoreId: 1, title: 'La droga', filePath: good),
              Song(mediaStoreId: 2, title: '003 - LA DROGA', filePath: bad),
              Song(mediaStoreId: 3, title: 'Otra', filePath: other),
            ],
            onLoad: (_, __) async {},
            onLoadToFree: (_) async {},
            onClose: () {},
            onFilesDeleted: deleted.addAll,
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('Revisar repetidas (1)'), findsOneWidget);
      await tester.tap(find.text('Revisar repetidas (1)'));
      await tester.pump();
      await tester.pump();
      // Al desplegar la repetida se ven las marcas de cada copia.
      await tester.tap(find.textContaining('REPETIDA ×2'));
      await tester.pump();
      await tester.pump();
      expect(find.text('RECOMENDADA'), findsOneWidget);
      expect(find.text('BAJA CALIDAD'), findsOneWidget);
      expect(find.text('BAJO VOLUMEN'), findsOneWidget);
      expect(find.text('320 kbps'), findsNWidgets(2)); // grupo + copia
      expect(find.text('128 kbps'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Marcar las copias peores'));
      await tester.pump();
      expect(find.textContaining('1 marcada'), findsOneWidget);

      await tester.tap(find.text('Mandar a la papelera (1)'));
      await tester.pumpAndSettle();
      expect(find.text('¿Mandar 1 archivo a la papelera?'), findsOneWidget);
      expect(find.textContaining('003 - LA DROGA.mp3'), findsWidgets);
      await tester.tap(find.text('Mandar a la papelera'));
      await tester.pumpAndSettle();
      // Confirmación de lo borrado.
      expect(find.text('Listo: se borró 1 archivo'), findsOneWidget);
      expect(find.textContaining('Papelera de reciclaje'), findsWidgets);
      await tester.tap(find.text('Aceptar'));
      await tester.pumpAndSettle();

      expect(quality.recycled, [bad]);
      expect(deleted, [bad]);
      expect(find.textContaining('REPETIDA'), findsNothing);
      expect(find.text('Otra'), findsOneWidget);

      // La casilla de arriba marca todas las que se ven.
      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();
      expect(find.textContaining('2 marcadas'), findsOneWidget);
      await tester.tap(find.text('Desmarcar'));
      await tester.pump();
      expect(find.textContaining('marcadas'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        mixer.dispose();
        await dir.delete(recursive: true);
      });
    }, skip: !hasMpv);

    testWidgets(
        'marcar las copias peores funciona en todas las repetidas, sin '
        'abrirlas', (tester) async {
      tester.view.physicalSize = const Size(1500, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      late Directory dir;
      late DjMixer mixer;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('tk_browser_all');
        mixer = DjMixer();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      String file(String name, int size) {
        final path = p.join(dir.path, name);
        File(path).writeAsBytesSync(List.filled(size, 1));
        return path;
      }

      const hq = AudioInfo(
          bitrate: 320000, sampleRate: 44100, channels: 2, durationMs: 240000);
      const lq = AudioInfo(
          bitrate: 96000, sampleRate: 44100, channels: 2, durationMs: 240000);
      final droga1 = file('La droga.mp3', 9000);
      final droga2 = file('La droga (1).mp3', 3000);
      final negrita1 = file('007.grupo caneo - negrita.mp3', 3000);
      final negrita2 = file('grupo caneo - negrita - copia.mp3', 9000);
      final negrita3 = file('Grupo Caneo - Negrita (from YouTube).mp3', 3100);
      final sola = file('Otra.mp3', 5000);
      final quality = _FakeQuality({
        droga1: hq,
        droga2: lq,
        negrita1: lq,
        negrita2: hq,
        negrita3: lq,
        sola: hq,
      }, {
        for (final path in [droga1, droga2, negrita1, negrita2, negrita3, sola])
          path: -10,
      });
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: DjFileBrowser(
            mixer: mixer,
            quality: quality,
            librarySongs: [
              for (final (i, path) in [
                droga1,
                droga2,
                negrita1,
                negrita2,
                negrita3,
                sola
              ].indexed)
                Song(
                    mediaStoreId: i,
                    title: p.basenameWithoutExtension(path),
                    filePath: path),
            ],
            onLoad: (_, __) async {},
            onLoadToFree: (_) async {},
            onClose: () {},
          ),
        ),
      ));
      await tester.pump();
      expect(find.textContaining('2 repetidas'), findsOneWidget);
      // Sin abrir ninguna: revisa las dos y marca las peores de cada una.
      await tester.tap(find.text('Marcar las copias peores'));
      for (var i = 0; i < 10; i++) {
        await tester.pump();
      }
      expect(find.textContaining('3 marcadas'), findsOneWidget);
      expect(
          find.textContaining('Marcadas 3 copias peores en 2 canciones '
              'repetidas'),
          findsOneWidget);
      // La que no está repetida y las mejores no se marcan.
      await tester.tap(find.text('Mandar a la papelera (3)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mandar a la papelera'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // Ventana de avance, con porcentaje.
      expect(find.text('Mandando a la papelera…'), findsOneWidget);
      expect(find.text('3 de 3'), findsOneWidget);
      expect(find.text('100 %'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Listo: se borraron 3 archivos'), findsOneWidget);
      await tester.tap(find.text('Aceptar'));
      await tester.pumpAndSettle();
      expect(quality.recycled.toSet(), {droga2, negrita1, negrita3});

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        mixer.dispose();
        await dir.delete(recursive: true);
      });
    }, skip: !hasMpv);
  });
}
