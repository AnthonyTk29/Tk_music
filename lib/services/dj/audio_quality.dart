import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'package:tk_music/domain/entities/song_id.dart';
import 'package:tk_music/services/loudness_store.dart';

/// Datos técnicos de un archivo de audio (del sistema de propiedades de
/// Windows, lo mismo que muestra el Explorador).
class AudioInfo {
  const AudioInfo({
    this.bitrate,
    this.sampleRate,
    this.channels,
    this.bitsPerSample,
    this.durationMs,
    this.vbr = false,
    this.realFormat,
  });

  factory AudioInfo.fromMap(Map<dynamic, dynamic> map) => AudioInfo(
        bitrate: (map['bitrate'] as num?)?.toInt(),
        sampleRate: (map['sampleRate'] as num?)?.toInt(),
        channels: (map['channels'] as num?)?.toInt(),
        bitsPerSample: (map['bitsPerSample'] as num?)?.toInt(),
        durationMs: (map['durationMs'] as num?)?.toInt(),
        vbr: map['vbr'] == true,
      );

  /// Bits por segundo.
  final int? bitrate;
  final int? sampleRate;
  final int? channels;
  final int? bitsPerSample;
  final int? durationMs;
  final bool vbr;

  /// Si el contenido no es lo que dice la extensión: "M4A", "WEBM"… (por
  /// ejemplo un audio de YouTube renombrado a .mp3). `null` si coincide o no
  /// se sabe.
  final String? realFormat;

  AudioInfo withRealFormat(String? format) => AudioInfo(
        bitrate: bitrate,
        sampleRate: sampleRate,
        channels: channels,
        bitsPerSample: bitsPerSample,
        durationMs: durationMs,
        vbr: vbr,
        realFormat: format,
      );
}

/// Qué hay de verdad adentro de un archivo, por sus primeros bytes: "MP3",
/// "WAV", "M4A", "WEBM", "OGG", "FLAC" o `null` si no se reconoce.
String? sniffAudioFormat(List<int> head) {
  bool at(int offset, String text) {
    if (head.length < offset + text.length) return false;
    for (var i = 0; i < text.length; i++) {
      if (head[offset + i] != text.codeUnitAt(i)) return false;
    }
    return true;
  }

  if (at(0, 'ID3')) return 'MP3';
  if (head.length >= 2 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0) {
    return 'MP3';
  }
  if (at(0, 'RIFF') && at(8, 'WAVE')) return 'WAV';
  if (at(4, 'ftyp')) return 'M4A';
  if (head.length >= 4 &&
      head[0] == 0x1A &&
      head[1] == 0x45 &&
      head[2] == 0xDF &&
      head[3] == 0xA3) {
    return 'WEBM';
  }
  if (at(0, 'OggS')) return 'OGG';
  if (at(0, 'fLaC')) return 'FLAC';
  return null;
}

/// El formato real de [path] si no coincide con su extensión.
Future<String?> realFormatOf(String path) async {
  RandomAccessFile? file;
  try {
    file = await File(path).open();
    final head = await file.read(12);
    final found = sniffAudioFormat(head);
    final expected = p.extension(path).replaceFirst('.', '').toUpperCase();
    return found == null || found == expected ? null : found;
  } catch (_) {
    return null;
  } finally {
    await file?.close();
  }
}

/// Lo que se sabe de una copia para compararla con las demás.
class CopyFacts {
  const CopyFacts({
    required this.path,
    required this.size,
    required this.modified,
    this.info,
    this.loudnessDb,
  });

  final String path;
  final int size;
  final DateTime modified;
  final AudioInfo? info;

  /// Volumen medido (dB RMS de un tramo de 20 s; más cerca de 0 = más
  /// fuerte). `null` si todavía no se midió.
  final double? loudnessDb;

  bool get isWav => p.extension(path).toLowerCase() == '.wav';

  /// kbps del MP3: el que informa el archivo o, si no, estimado por peso y
  /// duración.
  int? get kbps {
    final bitrate = info?.bitrate;
    if (bitrate != null && bitrate > 0) return (bitrate / 1000).round();
    final ms = info?.durationMs;
    if (ms == null || ms <= 0) return null;
    return (size * 8 / ms).round();
  }

  /// "320 kbps", "WAV 16/44" (bits / kHz).
  String? get qualityLabel {
    final fake = fakeFormat;
    if (fake != null) return '$fake (falso)';
    if (isWav) {
      final bits = info?.bitsPerSample;
      final rate = info?.sampleRate;
      if (bits == null || rate == null) return 'WAV';
      return 'WAV $bits/${(rate / 1000).round()}';
    }
    final k = kbps;
    return k == null ? null : '$k kbps';
  }

  /// El contenido es otro formato con la extensión cambiada.
  String? get fakeFormat => info?.realFormat;

  /// Baja calidad: MP3 de menos de 192 kbps, menos de 44,1 kHz o mono.
  bool get lowQuality {
    final rate = info?.sampleRate;
    if (rate != null && rate < 44100) return true;
    if (info?.channels == 1) return true;
    if (isWav) return (info?.bitsPerSample ?? 16) < 16;
    final k = kbps;
    return k != null && k < 192;
  }

  /// 0–100 según el formato y el bitrate.
  double get qualityPoints {
    var points = isWav
        ? 100.0
        : switch (kbps) {
            null => 50.0,
            >= 310 => 95.0,
            >= 250 => 88.0,
            >= 220 => 83.0,
            >= 185 => 78.0,
            >= 155 => 66.0,
            >= 120 => 55.0,
            >= 90 => 35.0,
            _ => 20.0,
          };
    final rate = info?.sampleRate;
    if (rate != null && rate < 44100) points -= 25;
    if (info?.channels == 1) points -= 15;
    if (isWav && (info?.bitsPerSample ?? 16) < 16) points -= 30;
    // Renombrado: algunos programas no lo abren y no se sabe su calidad.
    if (fakeFormat != null) points = math.min(points, 40) - 20;
    return points;
  }
}

/// Umbrales de "bajo volumen".
const lowVolumeDb = -20.0;
const quieterThanBestDb = 4.0;

/// Una copia es "cortada" si dura esto menos que la más larga.
const cutToleranceMs = 8000;

/// El veredicto sobre una copia.
class CopyVerdict {
  const CopyVerdict({
    required this.score,
    required this.recommended,
    required this.lowQuality,
    required this.lowVolume,
    required this.cut,
    required this.reasons,
    this.fakeFormat,
  });

  final double score;

  /// La mejor de sus copias (la que conviene dejar).
  final bool recommended;
  final bool lowQuality;
  final bool lowVolume;
  final bool cut;

  /// "M4A" si en realidad es otro formato renombrado.
  final String? fakeFormat;

  /// Por qué (para el cartelito).
  final List<String> reasons;
}

/// Compara las copias de una misma canción y elige la mejor: primero la
/// calidad (WAV > MP3 320 > 256 > … ; menos de 44,1 kHz o mono restan),
/// después que no esté cortada y que no suene más baja que las otras. Con
/// una sola copia solo marca sus problemas.
Map<String, CopyVerdict> judgeCopies(List<CopyFacts> copies) {
  final longest = copies
      .map((c) => c.info?.durationMs ?? 0)
      .fold<int>(0, (a, b) => math.max(a, b));
  final measured = copies.map((c) => c.loudnessDb).whereType<double>();
  final loudest = measured.isEmpty ? null : measured.reduce(math.max);
  final scores = <String, double>{};
  final flags = <String, (bool, bool, bool, List<String>)>{};
  for (final c in copies) {
    final reasons = <String>[];
    var score = c.qualityPoints;
    final label = c.qualityLabel;
    final fake = c.fakeFormat;
    if (fake != null) {
      reasons.add('en realidad es $fake con la extensión cambiada a '
          '${p.extension(c.path)}: algunos programas no lo abren');
    } else if (label != null) {
      reasons.add(c.lowQuality ? '$label: baja calidad' : label);
    }
    if (c.info?.channels == 1) reasons.add('mono');
    final rate = c.info?.sampleRate;
    if (rate != null && rate < 44100) {
      reasons.add('${(rate / 1000).toStringAsFixed(1)} kHz');
    }
    var cut = false;
    final ms = c.info?.durationMs;
    if (copies.length > 1 &&
        ms != null &&
        ms > 0 &&
        longest - ms > cutToleranceMs) {
      cut = true;
      score -= 30;
      reasons.add('${((longest - ms) / 1000).round()} s más corta que la '
          'más larga: puede estar cortada');
    }
    var lowVolume = false;
    final db = c.loudnessDb;
    if (db != null) {
      final diff = loudest == null ? 0.0 : loudest - db;
      if (copies.length > 1 && diff > 3) {
        score -= math.min(20.0, diff * 3);
      }
      if (db < lowVolumeDb ||
          (copies.length > 1 && diff >= quieterThanBestDb)) {
        lowVolume = true;
        reasons.add(copies.length > 1 && diff >= quieterThanBestDb
            ? 'suena ${diff.toStringAsFixed(1).replaceAll('.', ',')} dB más '
                'baja que la más fuerte'
            : 'volumen bajo (${db.toStringAsFixed(1).replaceAll('.', ',')} dB)');
      }
    }
    // Desempates: la más pesada (más información) y después la más nueva.
    score += c.size / 1e10 + c.modified.millisecondsSinceEpoch / 1e16;
    scores[c.path] = score;
    flags[c.path] = (c.lowQuality, lowVolume, cut, reasons);
  }
  String? best;
  if (copies.length > 1) {
    best = scores.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }
  return {
    for (final c in copies)
      c.path: CopyVerdict(
        score: scores[c.path]!,
        recommended: c.path == best,
        lowQuality: flags[c.path]!.$1,
        lowVolume: flags[c.path]!.$2,
        cut: flags[c.path]!.$3,
        fakeFormat: c.fakeFormat,
        reasons: [
          if (c.path == best) 'la mejor de las ${copies.length} copias',
          ...flags[c.path]!.$4,
        ],
      ),
  };
}

/// Lee la calidad y mide el volumen de archivos, y los manda a la papelera
/// (windows/runner/desktop_media_plugin.cpp). Lo leído queda en memoria.
class AudioQualityService {
  AudioQualityService({MethodChannel? channel, LoudnessStore? loudness})
      : _channel = channel ?? const MethodChannel('tk_music/desktop_media'),
        _loudnessStore = loudness ?? LoudnessStore();

  static final instance = AudioQualityService();

  final MethodChannel _channel;
  final LoudnessStore _loudnessStore;
  final _info = <String, AudioInfo>{};
  final _loudness = <String, double>{};

  AudioInfo? cachedInfo(String path) => _info[path];
  double? cachedLoudness(String path) => _loudness[path];

  /// Datos de [paths] (los que no estaban leídos, de a tandas).
  Future<void> loadInfo(Iterable<String> paths) async {
    final missing = paths.where((path) => !_info.containsKey(path)).toList();
    for (var i = 0; i < missing.length; i += 100) {
      final batch = missing.sublist(i, math.min(missing.length, i + 100));
      try {
        final list = await _channel
            .invokeListMethod<Object?>('audioInfo', {'paths': batch});
        for (var j = 0; j < batch.length; j++) {
          final item = list != null && j < list.length ? list[j] : null;
          final info =
              item is Map ? AudioInfo.fromMap(item) : const AudioInfo();
          _info[batch[j]] = info.withRealFormat(await realFormatOf(batch[j]));
        }
      } catch (_) {
        for (final path in batch) {
          _info[path] = AudioInfo(realFormat: await realFormatOf(path));
        }
      }
    }
  }

  /// Mide el volumen de [path] (decodifica 20 s; se guarda para la próxima).
  Future<double?> measureLoudness(String path) async {
    final cached = _loudness[path];
    if (cached != null) return cached;
    try {
      final db = await _loudnessStore.dbForFile(stableSongId(path), path);
      // El valor neutro es lo que devuelve cuando no pudo analizar.
      if (db == LoudnessStore.neutralDb) return null;
      _loudness[path] = db;
      return db;
    } catch (_) {
      return null;
    }
  }

  /// Manda [paths] a la Papelera de reciclaje. Devuelve los que se
  /// pudieron mandar.
  Future<Set<String>> recycle(List<String> paths) async {
    if (paths.isEmpty) return {};
    try {
      final list =
          await _channel.invokeListMethod<Object?>('recycle', {'paths': paths});
      return {
        for (var i = 0; i < paths.length; i++)
          if (list != null && i < list.length && list[i] == true) paths[i],
      };
    } catch (_) {
      return {};
    }
  }

  CopyFacts factsFor(String path, int size, DateTime modified) => CopyFacts(
        path: path,
        size: size,
        modified: modified,
        info: _info[path],
        loudnessDb: _loudness[path],
      );
}
