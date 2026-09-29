import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/presentation/pages/whatsapp_import_screen.dart';
import 'package:tk_music/services/whatsapp_files.dart';

const _root = 'primary:Android/media/com.whatsapp/WhatsApp/Media';
const _audio = '$_root/WhatsApp Audio';
const _sent = '$_audio/Sent';
const _voice = '$_root/WhatsApp Voice Notes';
const _week = '$_voice/202439';
const _images = '$_root/WhatsApp Images';
const _docs = '$_root/WhatsApp Documents';

WaFile _file(String parent, String name, int size) => WaFile(
      docId: '$parent/$name',
      name: name,
      parent: parent,
      uri: 'content://test/${Uri.encodeComponent('$parent/$name')}',
      size: size,
    );

List<WaFolder> _folders() => const [
      WaFolder(docId: _root, name: 'Media'),
      WaFolder(docId: _audio, name: 'WhatsApp Audio', parent: _root),
      WaFolder(docId: _sent, name: 'Sent', parent: _audio),
      WaFolder(docId: _voice, name: 'WhatsApp Voice Notes', parent: _root),
      WaFolder(docId: _week, name: '202439', parent: _voice),
      WaFolder(
          docId: _images,
          name: 'WhatsApp Images',
          parent: _root,
          otherFiles: 50),
      WaFolder(
          docId: _docs,
          name: 'WhatsApp Documents',
          parent: _root,
          otherFiles: 3),
    ];

List<WaFile> _files() => [
      _file(_audio, 'AUD-20260819-WA0001.mp3', 1000),
      _file(_sent, 'AUD-20260820-WA0002.mp3', 2000),
      _file(_week, 'PTT-20240925-WA0003.opus', 500),
      _file(_docs, 'Cancion.mp3', 3000),
    ];

/// Carpeta de WhatsApp de mentira: borra de verdad de su lista.
class _FakeFiles extends WhatsAppFiles {
  final folders = List.of(_folders());
  final files = _files();
  final deleted = <String>[];

  @override
  Future<WaTree> listTree(String treeUri) async =>
      WaTree(rootDocId: _root, folders: folders, files: files);

  @override
  Future<void> delete(String treeUri, String docId) async {
    deleted.add(docId);
    folders
        .removeWhere((f) => f.docId == docId || f.docId.startsWith('$docId/'));
    files.removeWhere((f) => f.docId == docId || f.docId.startsWith('$docId/'));
  }
}

void main() {
  test('carpetas: cuentas, subcarpetas con audio y ruta', () {
    final tree = WaTree(rootDocId: _root, folders: _folders(), files: _files());
    // WhatsApp Images no tiene audios: no se muestra.
    expect(tree.subfoldersOf(_root).map((f) => f.name), [
      'WhatsApp Audio',
      'WhatsApp Documents',
      'WhatsApp Voice Notes',
    ]);
    expect(tree.audioCount(_root), 4);
    expect(tree.audioCount(_audio), 2);
    expect(tree.audioBytes(_audio), 3000);
    expect(tree.otherFilesCount(_root), 53);
    expect(tree.otherFilesCount(_docs), 3);
    expect(
        tree.filesIn(_audio).map((f) => f.name), ['AUD-20260819-WA0001.mp3']);
    final notes = tree.filesUnder(_voice);
    expect(notes, hasLength(1));
    expect(notes.single.voiceNote, isTrue);
    expect(notes.single.title, 'Nota de voz 25-09-2024 (3)');
    expect(tree.isInside(_sent, _root), isTrue);
    expect(tree.isInside(_root, _sent), isFalse);
    expect(tree.pathTo(_week).map((f) => f.name),
        ['Media', 'WhatsApp Voice Notes', '202439']);
  });

  test('lee lo que manda Android', () {
    final tree = WhatsAppFiles.treeFromMap({
      'rootDocId': _root,
      'folders': [
        {'docId': _root, 'name': 'Media', 'parent': null, 'otherFiles': 2},
        {'docId': _audio, 'name': 'WhatsApp Audio', 'parent': _root},
      ],
      'files': [
        {
          'docId': '$_audio/a.mp3',
          'name': 'a.mp3',
          'parent': _audio,
          'uri': 'content://x',
          'size': 10,
          'modified': 1000,
        },
      ],
    });
    expect(tree.audioCount(_root), 1);
    expect(tree.otherFilesCount(_root), 2);
    expect(tree.files.single.date, DateTime.fromMillisecondsSinceEpoch(1000));
  });

  testWidgets('navegar, buscar, pasar a la biblioteca y borrar una carpeta',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(
        {'whatsapp.voiceNotesUri': 'content://tree/whatsapp'});
    final fake = _FakeFiles();
    final imported = <String>[];

    await tester.pumpWidget(MaterialApp(
      home: WhatsAppImportScreen(
        files: fake,
        loadForwarded: () async => const <Song>[],
        importAudio: (song) async {
          if (song.title == 'Cancion') throw Exception('disco lleno');
          imported.add(song.title);
        },
      ),
    ));
    await tester.pumpAndSettle();

    // Carpetas: arranca en la raíz.
    expect(find.text('WhatsApp Audio'), findsOneWidget);
    expect(find.text('WhatsApp Images'), findsNothing);
    await tester.tap(find.text('WhatsApp Voice Notes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Semana 39 de 2024'));
    await tester.pumpAndSettle();
    expect(find.text('Nota de voz 25-09-2024 (3)'), findsOneWidget);
    // Subir de a una carpeta, y volver al inicio con la ruta.
    await tester.tap(find.byTooltip('Subir una carpeta'));
    await tester.pumpAndSettle();
    expect(find.text('Semana 39 de 2024'), findsOneWidget);
    await tester.tap(find.byTooltip('Subir una carpeta'));
    await tester.pumpAndSettle();
    expect(find.text('WhatsApp'), findsOneWidget);
    expect(find.text('WhatsApp Documents'), findsOneWidget);

    // Todos los audios y buscar.
    await tester.tap(find.text('Todos los audios'));
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsNWidgets(4));
    await tester.enterText(find.byType(TextField), 'cancion');
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();

    // Marcar todos y pasar: uno falla, el resumen lo dice.
    await tester.tap(find.byIcon(Icons.select_all));
    await tester.pumpAndSettle();
    expect(find.text('Marcados: 4 audios'), findsOneWidget);
    await tester.tap(find.text('A biblioteca'));
    await tester.pump();
    expect(find.text('Pasando a la biblioteca…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Pasaron 3 de 4'), findsOneWidget);
    expect(find.textContaining('disco lleno'), findsOneWidget);
    await tester.tap(find.text('Aceptar'));
    await tester.pumpAndSettle();
    expect(imported, hasLength(3));
    expect(find.text('En biblioteca'), findsNWidgets(3));
    // Queda marcado solo el que falló.
    expect(find.text('Marcados: 1 audio'), findsOneWidget);
    await tester.tap(find.text('Desmarcar'));
    await tester.pumpAndSettle();

    // Borrar una carpeta entera: alerta con aviso de los otros archivos,
    // avance y resumen.
    await tester.tap(find.text('Carpetas'));
    await tester.pumpAndSettle();
    final docsTile = find.ancestor(
        of: find.text('WhatsApp Documents'), matching: find.byType(ListTile));
    await tester
        .tap(find.descendant(of: docsTile, matching: find.byType(Checkbox)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eliminar'));
    await tester.pumpAndSettle();
    expect(find.text('¿Eliminar definitivamente?'), findsOneWidget);
    expect(
        find.textContaining('1 carpeta entera, con 1 audio'), findsOneWidget);
    expect(find.textContaining('tiene 3 archivos'), findsNothing);
    expect(find.textContaining('tienen 3 archivos'), findsOneWidget);
    await tester.tap(find.text('Eliminar').last);
    await tester.pump();
    expect(find.text('Eliminando…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Listo: se eliminó 1 elemento'), findsOneWidget);
    await tester.tap(find.text('Aceptar'));
    await tester.pumpAndSettle();
    expect(fake.deleted, [_docs]);
    expect(find.text('WhatsApp Documents'), findsNothing);
    expect(find.text('WhatsApp Audio'), findsOneWidget);
  });
}
