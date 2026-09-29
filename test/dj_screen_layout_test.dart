import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/presentation/pages/dj_screen.dart';
import 'package:tk_music/presentation/widgets/dj/dj_shortcuts.dart';

/// El modo DJ usa reproductores mpv reales: el test necesita la libmpv que
/// deja el build de Windows. Sin ella (otra PC, CI) se saltea.
const _libmpv = r'build\windows\x64\runner\Debug\libmpv-2.dll';

void main() {
  final hasMpv = Platform.isWindows && File(_libmpv).existsSync();

  setUpAll(() {
    if (hasMpv) MediaKit.ensureInitialized(libmpv: File(_libmpv).absolute.path);
  });

  final songs = [
    const Song(
        mediaStoreId: 900,
        title: 'La droga',
        filePath: r'C:\musica\La droga.mp3'),
    const Song(
        mediaStoreId: 901,
        title: '003 - LA DROGA',
        filePath: r'D:\salsa\003 - LA DROGA.mp3'),
    for (var i = 0; i < 40; i++)
      Song(
        mediaStoreId: i,
        title: 'Canción de prueba con un título largo número $i',
        filePath: 'C:/musica/cancion_$i.mp3',
        artist: 'Artista $i',
        duration: Duration(seconds: 180 + i),
      ),
  ];

  for (final size in const [
    Size(1920, 1040),
    Size(1600, 860),
    Size(1280, 680), // ventana baja: se desplaza
  ]) {
    testWidgets(
      'se arma sin desbordes en ${size.width.toInt()}×${size.height.toInt()}',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: DjScreen(librarySongs: songs),
        ));
        await tester.pump(const Duration(milliseconds: 100));

        expect(tester.takeException(), isNull);
        expect(find.text('MEZCLADOR'), findsOneWidget);
        expect(find.text('MEZCLA AUTO'), findsOneWidget);
        expect(find.text('PUNTOS'), findsNWidgets(2));
        // Ganancia y ecualizador, en su ventana.
        expect(find.textContaining('GANANCIA'), findsNothing);
        await tester.tap(find.text('ECUALIZADOR'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.textContaining('GANANCIA'), findsNWidgets(2));
        expect(find.textContaining('AGUDOS'), findsNWidgets(2));
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Cerrar'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        // Auto DJ, en su ventana.
        await tester.tap(find.text('Auto DJ'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Arrancar Auto DJ'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Cerrar (el Auto DJ sigue)'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        // Los archivos se abren en una ventana.
        await tester.tap(find.text('Archivos'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
        expect(find.text('Biblioteca TK Music'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'droga');
        await tester.pump();
        expect(find.textContaining('REPETIDA'), findsOneWidget);
        // La repetida se despliega y muestra cada copia.
        await tester.tap(find.textContaining('REPETIDA'));
        await tester.pump();
        expect(find.byIcon(Icons.subdirectory_arrow_right), findsNWidgets(2));
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Cerrar'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        // Desde un deck: la ventana apunta a ese deck.
        await tester.tap(find.text('CARGAR').first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Cargar en el deck A'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Cerrar'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        // El mezclador se pliega y se vuelve a desplegar.
        await tester.tap(find.byTooltip(
            'Plegar el mezclador${djShortcutHint(DjCommand.toggleMixer)}'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
        expect(find.text('MEZCLA AUTO'), findsNothing);
        await tester.tap(find.byTooltip(
            'Desplegar el mezclador${djShortcutHint(DjCommand.toggleMixer)}'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('MEZCLA AUTO'), findsOneWidget);

        // Cambiar a los pads de loops y de saltos tampoco desborda.
        await tester.tap(find.text('BUCLE').first);
        await tester.pump();
        await tester.tap(find.text('SALTO').last);
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('+16'), findsOneWidget);

        // Teclado: F1 abre los atajos (y se ve sin desbordes), Esc cierra.
        Future<void> key(
            LogicalKeyboardKey logical, PhysicalKeyboardKey physical) async {
          await tester.sendKeyEvent(logical, physicalKey: physical);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
        }

        await key(LogicalKeyboardKey.f1, PhysicalKeyboardKey.f1);
        expect(find.text('Atajos de teclado'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await key(LogicalKeyboardKey.escape, PhysicalKeyboardKey.escape);
        expect(find.text('Atajos de teclado'), findsNothing);
        // F3 pliega y despliega el mezclador.
        await key(LogicalKeyboardKey.f3, PhysicalKeyboardKey.f3);
        expect(find.text('MEZCLA AUTO'), findsNothing);
        await key(LogicalKeyboardKey.f3, PhysicalKeyboardKey.f3);
        expect(find.text('MEZCLA AUTO'), findsOneWidget);
        // 6 cambia el modo de los pads del deck B: de SALTO a PUNTOS.
        await key(LogicalKeyboardKey.digit6, PhysicalKeyboardKey.digit6);
        expect(find.text('+16'), findsNothing);
        // F cambia el rango del pitch del deck A.
        await key(LogicalKeyboardKey.keyF, PhysicalKeyboardKey.keyF);
        expect(find.text('±16'), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Salir destruye los reproductores sin errores.
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 100));
      },
      skip: !hasMpv,
    );
  }
}
