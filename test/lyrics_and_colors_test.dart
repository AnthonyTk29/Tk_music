import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:tk_music/services/artwork_colors.dart';
import 'package:tk_music/services/lyrics.dart';

void main() {
  group('letras LRC', () {
    test('lee marcas de tiempo, ignora metadatos y ordena', () {
      final lyrics = parseLyrics('''
[ar:Artista]
[ti:Tema]
[00:12.50]Segundo
[00:05.00]Primero
[01:02.3]Tercero''', source: 'test')!;
      expect(lyrics.synced, isTrue);
      expect(
          lyrics.lines.map((l) => l.text), ['Primero', 'Segundo', 'Tercero']);
      expect(lyrics.lines.last.time,
          const Duration(minutes: 1, seconds: 2, milliseconds: 300));
    });

    test('varias marcas en un renglón (estribillo repetido)', () {
      final lyrics = parseLyrics(
          '[00:10.00][00:30.00]Estribillo\n[00:20.00]Verso',
          source: 'test')!;
      expect(lyrics.lines.map((l) => l.text),
          ['Estribillo', 'Verso', 'Estribillo']);
    });

    test('respeta [offset:]', () {
      final lyrics =
          parseLyrics('[offset:500]\n[00:10.00]Hola', source: 'test')!;
      expect(lyrics.lines.single.time, const Duration(milliseconds: 9500));
    });

    test('renglón actual según la posición', () {
      final lyrics =
          parseLyrics('[00:01.00]A\n[00:05.00]B\n[00:09.00]C', source: 'test')!;
      expect(lyrics.indexAt(Duration.zero), -1);
      expect(lyrics.indexAt(const Duration(seconds: 6)), 1);
      expect(lyrics.indexAt(const Duration(seconds: 30)), 2);
    });

    test('sin marcas de tiempo es letra sin sincronizar', () {
      final lyrics = parseLyrics('Uno\nDos', source: 'test')!;
      expect(lyrics.synced, isFalse);
      expect(lyrics.indexAt(const Duration(seconds: 5)), -1);
    });
  });

  test('el color de la carátula es el vivo, no el fondo gris', () {
    final image = img.Image(width: 40, height: 40);
    img.fill(image, color: img.ColorRgb8(120, 120, 120));
    img.fillRect(image,
        x1: 0, y1: 0, x2: 18, y2: 18, color: img.ColorRgb8(220, 30, 40));
    final png = Uint8List.fromList(img.encodePng(image));
    final argb = dominantArgb(png)!;
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    expect(r, greaterThan(180));
    expect(g, lessThan(80));
  });
}
