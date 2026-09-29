import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tk_music/services/desktop_library_scanner.dart';
import 'package:tk_music/services/dj/music_files.dart';

void main() {
  late Directory root;
  late Directory storage;
  final scanner = DesktopLibraryScanner.instance;

  File song(String relative, {int size = 1000}) {
    final file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(List.filled(size, 1));
    return file;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tk_disks');
    storage = await Directory.systemTemp.createTemp('tk_store');
    scanner
      ..resetForTest()
      ..storageDir = (() async => storage)
      ..roots = (() => [root.path]);
  });

  tearDown(() async {
    scanner.resetForTest();
    await root.delete(recursive: true);
    await storage.delete(recursive: true);
  });

  test('busca en todos los discos todos los formatos, sin juegos ni sistema',
      () async {
    song('Música/salsa/La droga.mp3');
    song('Descargas/tema.flac');
    song('Descargas/otro.m4a');
    song('Escritorio/lista.wav');
    song('SteamLibrary/steamapps/common/juego/sonido.ogg');
    song('Windows/Media/aviso.wav');
    song('Documentos/notas.txt');
    final files = await scanner.files();
    expect(files.map((f) => p.basename(f.path)).toSet(),
        {'La droga.mp3', 'tema.flac', 'otro.m4a', 'lista.wav'});
    expect(
        File(p.join(storage.path, 'library_files.json')).existsSync(), isTrue);
  });

  test('la segunda vez abre con lo guardado y se actualiza sola', () async {
    song('a.mp3');
    await scanner.files();
    // Nueva sesión de la app: lo guardado sale al instante.
    scanner.resetForTest();
    song('b.mp3');
    final revision = scanner.revision.value;
    final first = await scanner.files();
    expect(first.map((f) => p.basename(f.path)), ['a.mp3']);
    // …y la revisión en segundo plano encuentra la nueva.
    await scanner.scan();
    expect(scanner.revision.value, greaterThan(revision));
    final updated = await scanner.files();
    expect(updated.map((f) => p.basename(f.path)).toSet(), {'a.mp3', 'b.mp3'});
  });

  test('suma lo descargado y quita lo borrado sin esperar el escaneo',
      () async {
    final a = song('a.mp3');
    await scanner.files();
    final nuevo = song('Música/TK Music/Descargas/nuevo.mp3');
    await scanner.addFiles([nuevo.path]);
    expect((await scanner.files()).length, 2);
    await scanner.removeFiles([a.path]);
    expect(
        (await scanner.files()).map((f) => p.basename(f.path)), ['nuevo.mp3']);
  });

  test('una carpeta oculta sale de la biblioteca y no vuelve al revisar',
      () async {
    song('Música/tema.mp3');
    song('servergame/sonidos/golpe.ogg');
    song('servergame/sonidos/musica.ogg');
    await scanner.files();
    final hidden = p.join(root.path, 'servergame');
    await scanner.hideFolder(hidden);
    expect(
        (await scanner.files()).map((f) => p.basename(f.path)), ['tema.mp3']);
    await scanner.scan();
    expect(
        (await scanner.files()).map((f) => p.basename(f.path)), ['tema.mp3']);
    // Se recuerda para la próxima vez.
    scanner.resetForTest();
    await scanner.files();
    expect(scanner.hiddenFolders, {hidden});
    // Y se puede volver a incluir.
    await scanner.showFolder(hidden);
    await scanner.scan();
    expect((await scanner.files()).length, 3);
  });

  test('un disco que no se puede leer se marca y se sigue con los demás',
      () async {
    song('Música/tema.mp3');
    // Una lectora de DVD vacía: Windows la lista pero no responde.
    scanner
      ..roots = (() => [r'Q:\', root.path])
      ..driveInfo = (() => [
            const DriveInfo(r'E:\', problem: 'El dispositivo no está listo.'),
          ]);
    final files = await scanner.files();
    expect(files.map((f) => p.basename(f.path)), ['tema.mp3']);
    final paths = scanner.unreadable.map((u) => u.$1).toList();
    expect(paths, containsAll([r'E:\', r'Q:\']));
    expect(scanner.unreadable.first.$2, contains('no está listo'));
    scanner.driveInfo = listDriveInfo;
  });
}
