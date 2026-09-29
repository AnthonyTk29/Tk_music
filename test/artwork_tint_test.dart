import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tk_music/presentation/widgets/artwork_backdrop.dart';
import 'package:tk_music/services/playback_settings.dart';

void main() {
  final red = () {
    final image = img.Image(width: 32, height: 32);
    img.fill(image, color: img.ColorRgb8(210, 30, 40));
    return Uint8List.fromList(img.encodePng(image));
  }();

  Color? seenSeed;
  ColorScheme? seenScheme;

  Widget app() => MaterialApp(
        theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
        home: ArtworkTinted(
          artwork: red,
          artworkKey: 'test-red',
          builder: (context, seed) {
            seenSeed = seed;
            seenScheme = Theme.of(context).colorScheme;
            return const SizedBox();
          },
        ),
      );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('tiñe el tema con el color de la carátula', (tester) async {
    await PlaybackSettings.instance.setArtworkColors(true);
    await tester.pumpWidget(app());
    // El color se calcula en otro isolate: se espera de verdad.
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
    await tester.pumpAndSettle();
    expect(seenSeed, isNotNull);
    expect((seenSeed!.r * 255).round(), greaterThan(150));
    final primary = seenScheme!.primary;
    expect(primary.r, greaterThan(primary.b), reason: 'el tema pasa a rojo');
  });

  testWidgets('con el ajuste apagado queda el color de la app', (tester) async {
    await PlaybackSettings.instance.setArtworkColors(false);
    await tester.pumpWidget(app());
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
    await tester.pumpAndSettle();
    expect(seenSeed, isNull);
    await PlaybackSettings.instance.setArtworkColors(true);
  });
}
