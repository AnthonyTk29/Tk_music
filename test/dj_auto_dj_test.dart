import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/services/dj/dj_auto_dj.dart';
import 'package:tk_music/services/dj/dj_mixer.dart';

const _libmpv = r'build\windows\x64\runner\Debug\libmpv-2.dll';

/// WAV mono en silencio (suena sin que se escuche nada).
String _silentWav(Directory dir, String name, int seconds) {
  const rate = 22050;
  final dataBytes = rate * 2 * seconds;
  final bytes = ByteData(44 + dataBytes);
  void text(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  bytes.setUint32(4, 36 + dataBytes, Endian.little);
  text(8, 'WAVEfmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, rate, Endian.little);
  bytes.setUint32(28, rate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  text(36, 'data');
  bytes.setUint32(40, dataBytes, Endian.little);
  final path = '${dir.path}${Platform.pathSeparator}$name';
  File(path).writeAsBytesSync(bytes.buffer.asUint8List());
  return path;
}

Future<void> _until(bool Function() ok, String what,
    {Duration timeout = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(timeout);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('No pasó: $what');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  final hasMpv = Platform.isWindows && File(_libmpv).existsSync();

  test('la lista suena sola: carga la siguiente, mezcla y sigue', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    MediaKit.ensureInitialized(libmpv: File(_libmpv).absolute.path);
    final dir = await Directory.systemTemp.createTemp('tk_autodj');
    addTearDown(() => dir.delete(recursive: true));
    final songs = [
      for (final (i, name) in ['uno.wav', 'dos.wav', 'tres.wav'].indexed)
        Song(
          mediaStoreId: i + 1,
          title: name,
          filePath: _silentWav(dir, name, 10),
          duration: const Duration(seconds: 10),
        ),
    ];
    final mixer = DjMixer();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // 8 pulsos sin BPM = 4 s de mezcla.
    final autoDj = DjAutoDj(mixer, beats: 8)..add(songs);
    addTearDown(() async {
      autoDj
        ..stop()
        ..dispose();
      for (final deck in mixer.decks) {
        await deck.pause();
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      mixer.dispose();
    });

    expect(await autoDj.start(), isNull);
    // Suena la primera en el A; la segunda queda cargada en el B.
    expect(mixer.a.song?.title, 'uno.wav');
    expect(mixer.a.playing, isTrue);
    await _until(() => mixer.b.song?.title == 'dos.wav', 'cargar la segunda');
    expect(autoDj.next?.song.title, 'dos.wav');

    // Cerca del final mezcla sola al B y deja la tercera en el A.
    await _until(() => autoDj.mixing, 'empezar a mezclar',
        timeout: const Duration(seconds: 15));
    await _until(
        () => !autoDj.mixing && autoDj.current?.song.title == 'dos.wav',
        'terminar la mezcla');
    expect(mixer.b.playing, isTrue);
    expect(mixer.crossfader, 1);
    await _until(() => mixer.a.song?.title == 'tres.wav', 'cargar la tercera');
    expect(autoDj.items.where((i) => i.played).length, 2);
  }, skip: !hasMpv, timeout: const Timeout(Duration(seconds: 90)));
}
