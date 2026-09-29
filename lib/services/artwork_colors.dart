import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:image/image.dart' as img;

import 'artwork_bytes.dart';

/// Color dominante de la carátula de una canción, para teñir "Reproduciendo"
/// (y la sesión compartida) con el color del disco. Se calcula una vez por
/// canción en un isolate y queda en memoria.
class ArtworkColors {
  ArtworkColors._();

  static final Map<int, Future<Color?>> _cache = {};

  static Future<Color?> seedFor(int songId) =>
      _cache[songId] ??= _compute(songId);

  /// Se cambió la carátula en el editor de tags.
  static void invalidate(int songId) => _cache.remove(songId);

  /// Olvida todos (cambió de dónde salen las carátulas).
  static void clear() {
    _cache.clear();
    _bytesCache.clear();
  }

  static Future<Color?> _compute(int songId) async {
    final bytes = await ArtworkBytes.forSong(songId, size: 128);
    if (bytes == null) return null;
    return fromBytes(bytes);
  }

  static Future<Color?> fromBytes(Uint8List bytes) async {
    final argb = await Isolate.run(() => dominantArgb(bytes));
    return argb == null ? null : Color(argb);
  }

  static final Map<String, Future<Color?>> _bytesCache = {};

  /// Igual que [fromBytes] pero recordado por [key] — para carátulas que no
  /// son de la biblioteca (las que manda el anfitrión en una sesión).
  static Future<Color?> seedForBytes(String key, Uint8List bytes) {
    if (_bytesCache.length > 200) _bytesCache.clear();
    return _bytesCache[key] ??= fromBytes(bytes);
  }
}

/// Color "protagonista" de una imagen: agrupa los píxeles en cubetas de
/// color y elige la que más pesa, premiando los colores vivos (saturados y
/// ni muy oscuros ni muy claros) para que el tema no salga gris.
int? dominantArgb(Uint8List encoded) {
  final decoded = img.decodeImage(encoded);
  if (decoded == null) return null;
  final small =
      decoded.width > 64 ? img.copyResize(decoded, width: 64) : decoded;

  final counts = <int, double>{};
  final sums = <int, List<double>>{};
  for (final pixel in small) {
    final r = pixel.r.toDouble();
    final g = pixel.g.toDouble();
    final b = pixel.b.toDouble();
    final max = [r, g, b].reduce((a, c) => a > c ? a : c);
    final min = [r, g, b].reduce((a, c) => a < c ? a : c);
    final lightness = (max + min) / 2 / 255;
    if (lightness < 0.08 || lightness > 0.94) continue;
    final saturation = max == 0 ? 0.0 : (max - min) / max;
    final weight = 0.25 + saturation * saturation * 2;
    final key = (r ~/ 32) << 6 | (g ~/ 32) << 3 | (b ~/ 32);
    counts[key] = (counts[key] ?? 0) + weight;
    final sum = sums.putIfAbsent(key, () => [0, 0, 0, 0]);
    sum[0] += r * weight;
    sum[1] += g * weight;
    sum[2] += b * weight;
    sum[3] += weight;
  }
  if (counts.isEmpty) return null;
  final best = counts.entries.reduce((a, c) => a.value >= c.value ? a : c).key;
  final sum = sums[best]!;
  final r = (sum[0] / sum[3]).round().clamp(0, 255);
  final g = (sum[1] / sum[3]).round().clamp(0, 255);
  final b = (sum[2] / sum[3]).round().clamp(0, 255);
  return 0xFF000000 | r << 16 | g << 8 | b;
}
