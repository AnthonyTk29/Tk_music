import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tk_music/services/dj/dj_deck.dart';

/// Usa la libmpv real que deja el build de Windows; sin ella se saltea.
const _libmpv = r'build\windows\x64\runner\Debug\libmpv-2.dll';

/// WAV estéreo con sonido distinto en cada lado (440 Hz a la izquierda,
/// 660 Hz a la derecha): si el deck no lo pasara a mono, un lado quedaría
/// con otro contenido.
File _stereoWav(Directory dir) {
  const rate = 44100;
  const seconds = 3;
  final frames = rate * seconds;
  final data = ByteData(44 + frames * 4);
  void text(int o, String v) {
    for (var i = 0; i < v.length; i++) {
      data.setUint8(o + i, v.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  data.setUint32(4, 36 + frames * 4, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 2, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 4, Endian.little);
  data.setUint16(32, 4, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, frames * 4, Endian.little);
  for (var i = 0; i < frames; i++) {
    final l = math.sin(2 * math.pi * 440 * i / rate) * 12000;
    final r = math.sin(2 * math.pi * 660 * i / rate) * 12000;
    data.setInt16(44 + i * 4, l.round(), Endian.little);
    data.setInt16(46 + i * 4, r.round(), Endian.little);
  }
  final file = File('${dir.path}${Platform.pathSeparator}in.wav')
    ..writeAsBytesSync(data.buffer.asUint8List());
  return file;
}

/// Nivel (RMS) de cada lado de un WAV estéreo de 16 bits.
({double left, double right}) _levels(File wav) {
  final bytes = wav.readAsBytesSync();
  final data = ByteData.sublistView(bytes);
  var pos = 12;
  var start = 0;
  while (pos + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(pos, pos + 4));
    final len = data.getUint32(pos + 4, Endian.little);
    if (id == 'data') {
      start = pos + 8;
      break;
    }
    pos += 8 + len;
  }
  var l = 0.0, r = 0.0, n = 0;
  for (var i = start; i + 3 < bytes.length; i += 4) {
    final a = data.getInt16(i, Endian.little).toDouble();
    final b = data.getInt16(i + 2, Endian.little).toDouble();
    l += a * a;
    r += b * b;
    n++;
  }
  return n == 0
      ? (left: 0, right: 0)
      : (left: math.sqrt(l / n), right: math.sqrt(r / n));
}

Future<({double left, double right})> _play(
    File input, File output, String af) async {
  final player = Player();
  final native = player.platform as NativePlayer;
  final sub = player.stream.log.listen((l) {
    if (l.level == 'error' || l.level == 'fatal' || l.prefix == 'ffmpeg') {
      stderr.writeln('mpv ${l.prefix}: ${l.text.trim()}');
    }
  });
  await native.setProperty('ao', 'pcm');
  await native.setProperty('ao-pcm-file', output.path);
  await native.setProperty('audio-channels', 'stereo');
  await native.setProperty('audio-format', 's16');
  await native.setProperty('af', af);
  await player.open(Media(input.path), play: true);
  await Future<void>.delayed(const Duration(milliseconds: 1200));
  await player.dispose();
  await sub.cancel();
  await Future<void>.delayed(const Duration(milliseconds: 300));
  return _levels(output);
}

void main() {
  final hasMpv = Platform.isWindows && File(_libmpv).existsSync();

  test(
    'el deck A sale en mono solo por la izquierda y el B solo por la derecha',
    () async {
      MediaKit.ensureInitialized(libmpv: File(_libmpv).absolute.path);
      final dir = Directory.systemTemp.createTempSync('tk_dj_out');
      final input = _stereoWav(dir);

      // La misma cadena que usa el deck, con ecualizador y cambio de tempo.
      final a = await _play(input, File('${dir.path}/a.wav'),
          djDeckChain('A', const [-6, 0, 3], tempoScale: 0.95));
      final b = await _play(
          input, File('${dir.path}/b.wav'), djDeckChain('B', const [0, 0, 0]));
      // La prueba de salida (pitidos) también sale por un solo lado.
      final tone =
          await _play(input, File('${dir.path}/t.wav'), djSideFilter('B'));

      expect(a.left, greaterThan(1000), reason: 'A suena a la izquierda');
      expect(a.right, lessThan(a.left * 0.01),
          reason: 'A no sale a la derecha');
      expect(b.right, greaterThan(1000), reason: 'B suena a la derecha');
      expect(b.left, lessThan(b.right * 0.01),
          reason: 'B no sale a la izquierda');
      expect(tone.left, lessThan(tone.right * 0.01),
          reason: 'la prueba de B no sale a la izquierda');
    },
    skip: !hasMpv,
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
