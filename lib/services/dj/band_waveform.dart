import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Forma de onda detallada y por frecuencias, como la de los programas de
/// DJ: [bucketsPerSecond] puntos por segundo y, en cada uno, el pico de los
/// graves ([low]), los medios ([mid]) y los agudos ([high]), de 0 a 255 (la
/// misma escala para las tres bandas, así se comparan entre sí).
class BandWaveform {
  const BandWaveform({
    required this.bucketsPerSecond,
    required this.low,
    required this.mid,
    required this.high,
  });

  /// Puntos por segundo, exacto (la frecuencia de muestreo dividida por las
  /// muestras de cada punto): con un redondeo acá la onda se iría corriendo
  /// respecto del audio a lo largo de la canción.
  final double bucketsPerSecond;
  final Uint8List low;
  final Uint8List mid;
  final Uint8List high;

  int get length => low.length;
  double get durationMs => length * 1000 / bucketsPerSecond;

  /// Picos generales (0–1) en [count] tramos: lo que usan el vúmetro, la
  /// vista de la canción entera y el bucle automático.
  List<double> toPeaks(int count) {
    final out = List<double>.filled(count, 0);
    if (length == 0) return out;
    for (var i = 0; i < length; i++) {
      final b = (i * count ~/ length).clamp(0, count - 1);
      final v = math.max(low[i], math.max(mid[i], high[i])) / 255;
      if (v > out[b]) out[b] = v;
    }
    return out;
  }
}

// ---------------------------------------------------------------------------
// Análisis (Dart puro, corre en un isolate)
// ---------------------------------------------------------------------------

/// Filtro bicuadrático (fórmulas de Robert Bristow-Johnson).
class _Biquad {
  _Biquad.lowPass(double freq, double rate, {double q = 0.7071}) {
    final w = 2 * math.pi * freq / rate;
    final alpha = math.sin(w) / (2 * q);
    final cos = math.cos(w);
    _set((1 - cos) / 2, 1 - cos, (1 - cos) / 2, 1 + alpha, -2 * cos, 1 - alpha);
  }

  _Biquad.highPass(double freq, double rate, {double q = 0.7071}) {
    final w = 2 * math.pi * freq / rate;
    final alpha = math.sin(w) / (2 * q);
    final cos = math.cos(w);
    _set((1 + cos) / 2, -(1 + cos), (1 + cos) / 2, 1 + alpha, -2 * cos,
        1 - alpha);
  }

  late double _b0, _b1, _b2, _a1, _a2;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  void _set(double b0, double b1, double b2, double a0, double a1, double a2) {
    _b0 = b0 / a0;
    _b1 = b1 / a0;
    _b2 = b2 / a0;
    _a1 = a1 / a0;
    _a2 = a2 / a0;
  }

  double process(double x) {
    final y = _b0 * x + _b1 * _x1 + _b2 * _x2 - _a1 * _y1 - _a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }
}

/// Graves hasta ~200 Hz, medios ~200–2500 Hz, agudos desde ~2500 Hz.
const _lowCut = 200.0;
const _highCut = 2500.0;

/// Calcula la forma de onda por bandas de [pcm] (mono, 16 bits, [rate] Hz).
BandWaveform analyzeBandWaveform(Int16List pcm, int rate,
    {int bucketsPerSecond = 100}) {
  final samplesPerBucket = math.max(1, (rate / bucketsPerSecond).round());
  final count = (pcm.length / samplesPerBucket).ceil();
  final low = Float64List(count);
  final mid = Float64List(count);
  final high = Float64List(count);
  // Dos etapas por filtro (4.º orden): bandas más separadas.
  final lp1 = _Biquad.lowPass(_lowCut, rate.toDouble());
  final lp2 = _Biquad.lowPass(_lowCut, rate.toDouble());
  final hp1 = _Biquad.highPass(_highCut, rate.toDouble());
  final hp2 = _Biquad.highPass(_highCut, rate.toDouble());
  final mHp1 = _Biquad.highPass(_lowCut, rate.toDouble());
  final mHp2 = _Biquad.highPass(_lowCut, rate.toDouble());
  final mLp1 = _Biquad.lowPass(_highCut, rate.toDouble());
  final mLp2 = _Biquad.lowPass(_highCut, rate.toDouble());
  for (var i = 0; i < pcm.length; i++) {
    final x = pcm[i] / 32768.0;
    final l = lp2.process(lp1.process(x)).abs();
    final h = hp2.process(hp1.process(x)).abs();
    final m = mLp2.process(mLp1.process(mHp2.process(mHp1.process(x)))).abs();
    final b = i ~/ samplesPerBucket;
    if (l > low[b]) low[b] = l;
    if (m > mid[b]) mid[b] = m;
    if (h > high[b]) high[b] = h;
  }
  // Una sola escala para las tres bandas: el 99,5 % más alto de todos los
  // picos (un golpe suelto no achica todo lo demás).
  final all = Float64List(count);
  for (var i = 0; i < count; i++) {
    all[i] = math.max(low[i], math.max(mid[i], high[i]));
  }
  final sorted = Float64List.fromList(all)..sort();
  final reference = count == 0
      ? 1.0
      : math.max(1e-4, sorted[(count * 0.995).floor().clamp(0, count - 1)]);
  Uint8List quantize(Float64List values) {
    final out = Uint8List(count);
    for (var i = 0; i < count; i++) {
      out[i] = (values[i] / reference * 255).round().clamp(0, 255);
    }
    return out;
  }

  return BandWaveform(
    bucketsPerSecond: rate / samplesPerBucket,
    low: quantize(low),
    mid: quantize(mid),
    high: quantize(high),
  );
}

// ---------------------------------------------------------------------------
// Carga (decodificación nativa + caché en disco)
// ---------------------------------------------------------------------------

/// Calcula y guarda las formas de onda por bandas de los decks. Decodifica
/// la canción entera con el mismo decodificador del análisis de ritmo
/// (canal `tk_music/audio_analysis`, `decodePcm`) y la analiza en un
/// isolate; el resultado queda en disco (por ruta, tamaño y fecha).
class BandWaveformStore {
  BandWaveformStore._();
  static final instance = BandWaveformStore._();

  static const _channel = MethodChannel('tk_music/audio_analysis');
  static const _rate = 11025;
  static const _chunkSeconds = 600;
  static const _version = 2;

  @visibleForTesting
  Future<Directory> Function() storageDir = getApplicationSupportDirectory;

  final _memory = <String, BandWaveform>{};
  final _pending = <String, Future<BandWaveform?>>{};

  Future<BandWaveform?> load(String path) {
    final cached = _memory[path];
    if (cached != null) return Future.value(cached);
    return _pending[path] ??= _load(path).whenComplete(() {
      _pending.remove(path);
    });
  }

  Future<BandWaveform?> _load(String path) async {
    File? cacheFile;
    try {
      final stat = await File(path).stat();
      cacheFile = await _cacheFileFor(path, stat.size, stat.modified);
      final fromDisk = await _read(cacheFile);
      if (fromDisk != null) return _memory[path] = fromDisk;
    } catch (_) {
      // Sin caché: se calcula.
    }
    final pcm = await _decode(path);
    if (pcm == null) return null;
    final wave = await Isolate.run(() => analyzeBandWaveform(pcm, _rate));
    _memory[path] = wave;
    if (cacheFile != null) unawaited(_write(cacheFile, wave));
    return wave;
  }

  /// La canción entera, mono a [_rate] Hz, de a tramos de 10 minutos.
  Future<Int16List?> _decode(String path) async {
    final parts = <(int startMs, Int16List pcm)>[];
    var start = 0;
    while (true) {
      final Map<String, Object?>? result;
      try {
        result = await _channel.invokeMapMethod<String, Object?>('decodePcm', {
          'path': path,
          'startMs': start,
          'seconds': _chunkSeconds,
          'sampleRate': _rate,
        }).timeout(const Duration(seconds: 60));
      } catch (e) {
        debugPrint('Onda por bandas de $path: $e');
        return null;
      }
      final bytes = result?['pcm'] as Uint8List?;
      if (bytes == null || bytes.isEmpty) break;
      final realStart = (result!['startMs'] as num?)?.toInt() ?? start;
      parts.add((
        realStart,
        Int16List.fromList(
            bytes.buffer.asInt16List(bytes.offsetInBytes, bytes.length ~/ 2)),
      ));
      // Terminó la canción (vino menos de un tramo completo, o el nativo
      // corrió el comienzo hacia atrás para llenar el último tramo).
      final full = bytes.length ~/ 2 >= _chunkSeconds * _rate - _rate;
      if (!full || realStart < start) break;
      start += _chunkSeconds * 1000;
    }
    if (parts.isEmpty) return null;
    final total =
        parts.map((p) => p.$1 * _rate ~/ 1000 + p.$2.length).reduce(math.max);
    final out = Int16List(total);
    for (final (startMs, pcm) in parts) {
      out.setRange(
          startMs * _rate ~/ 1000, startMs * _rate ~/ 1000 + pcm.length, pcm);
    }
    return out;
  }

  Future<File> _cacheFileFor(String path, int size, DateTime modified) async {
    // FNV-1a de la ruta, el tamaño y la fecha: otro archivo, otra onda.
    var hash = 0x811c9dc5;
    for (final unit
        in '${path.toLowerCase()}|$size|${modified.millisecondsSinceEpoch}'
            .codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    final dir = await storageDir();
    return File('${dir.path}${Platform.pathSeparator}band_waveforms'
        '${Platform.pathSeparator}${hash.toRadixString(16)}.bin');
  }

  Future<BandWaveform?> _read(File file) async {
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    if (bytes.length < 12) return null;
    final header = ByteData.sublistView(bytes, 0, 12);
    if (header.getUint32(0) != _version) return null;
    final bps = header.getFloat32(4);
    final count = header.getUint32(8);
    if (bytes.length != 12 + count * 3) return null;
    return BandWaveform(
      bucketsPerSecond: bps,
      low: Uint8List.sublistView(bytes, 12, 12 + count),
      mid: Uint8List.sublistView(bytes, 12 + count, 12 + 2 * count),
      high: Uint8List.sublistView(bytes, 12 + 2 * count, 12 + 3 * count),
    );
  }

  Future<void> _write(File file, BandWaveform wave) async {
    try {
      await file.parent.create(recursive: true);
      final header = ByteData(12)
        ..setUint32(0, _version)
        ..setFloat32(4, wave.bucketsPerSecond)
        ..setUint32(8, wave.length);
      final builder = BytesBuilder(copy: false)
        ..add(header.buffer.asUint8List())
        ..add(wave.low)
        ..add(wave.mid)
        ..add(wave.high);
      await file.writeAsBytes(builder.takeBytes());
    } catch (e) {
      debugPrint('No se pudo guardar la onda por bandas: $e');
    }
  }
}
