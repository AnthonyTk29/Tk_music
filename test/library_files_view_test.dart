import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/presentation/widgets/dj/dj_file_browser.dart';

/// El gestor de archivos en la pestaña Biblioteca (modo reproductor).
void main() {
  testWidgets(
      'modo reproductor: biblioteca completa, todos los formatos y '
      'PLAY con la lista como cola', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final shotDir = Platform.environment['SHOTDIR'];
    if (shotDir != null) {
      await tester.runAsync(() async {
        for (final (family, path) in [
          ('Segoe UI', r'C:\Windows\Fonts\segoeui.ttf'),
          (
            'MaterialIcons',
            r'C:\Users\USER A1\Documents\flutter_3.32.0\bin\cache\artifacts\material_fonts\materialicons-regular.otf'
          ),
        ]) {
          final loader = FontLoader(family)
            ..addFont(Future.value(
                ByteData.view(File(path).readAsBytesSync().buffer)));
          await loader.load();
        }
      });
    }

    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('tk_library_view');
    });
    addTearDown(() => dir.deleteSync(recursive: true));
    String file(String name) {
      final path = p.join(dir.path, name);
      File(path).writeAsBytesSync(List.filled(4000, 1));
      return path;
    }

    final songs = [
      Song(mediaStoreId: 1, title: 'La droga', filePath: file('La droga.mp3')),
      Song(
          mediaStoreId: 2,
          title: '003 - LA DROGA',
          filePath: file('003 - LA DROGA.mp3')),
      Song(
          mediaStoreId: 3,
          title: 'Amnesia',
          artist: 'José José',
          filePath: file('Amnesia.m4a')),
      Song(mediaStoreId: 4, title: 'Tema en FLAC', filePath: file('tema.flac')),
    ];
    Song? played;
    List<Song>? queue;
    await tester.pumpWidget(RepaintBoundary(
      key: const Key('shot'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(
            textTheme:
                ThemeData.dark().textTheme.apply(fontFamily: 'Segoe UI')),
        home: Scaffold(
          body: DjFileBrowser.forPlayer(
            librarySongs: songs,
            onPlay: (song, context) async {
              played = song;
              queue = context;
            },
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Archivos de la PC'), findsOneWidget);
    expect(find.text('Todas mis canciones'), findsWidgets);
    expect(find.text('Otros'), findsOneWidget);
    // Sin "Todas las canciones" aparte: la biblioteca ya son todos los discos.
    expect(find.text('Todas las canciones'), findsNothing);
    expect(find.text('Amnesia'), findsOneWidget);
    expect(find.text('Tema en FLAC'), findsOneWidget);
    expect(find.textContaining('REPETIDA ×2'), findsOneWidget);

    if (shotDir != null) {
      final boundary = tester
          .renderObject<RenderRepaintBoundary>(find.byKey(const Key('shot')));
      final image =
          await tester.runAsync(() => boundary.toImage(pixelRatio: 1));
      final bytes = await tester
          .runAsync(() => image!.toByteData(format: ui.ImageByteFormat.png));
      File(p.join(shotDir, 'library_files.png'))
          .writeAsBytesSync(bytes!.buffer.asUint8List());
    }

    // "Otros" apagado: quedan MP3 y WAV.
    await tester.tap(find.text('Otros'));
    await tester.pump();
    expect(find.text('Amnesia'), findsNothing);
    await tester.tap(find.text('Otros'));
    await tester.pump();

    // PLAY en Amnesia: suena esa, con lo que se ve como cola (de la
    // repetida, una sola copia).
    final amnesiaRow =
        find.ancestor(of: find.text('Amnesia'), matching: find.byType(InkWell));
    await tester.tap(find.descendant(
        of: amnesiaRow.first, matching: find.byIcon(Icons.play_arrow)));
    // La fila también escucha el doble clic: el toque se confirma al pasar
    // ese tiempo.
    await tester.pump(const Duration(milliseconds: 400));
    expect(played?.title, 'Amnesia');
    expect(queue, hasLength(3));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });
}
