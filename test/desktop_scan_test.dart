import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tk_music/services/dj/music_files.dart';

void main() {
  test('encuentra audio en subcarpetas y saltea las del sistema', () async {
    final root = await Directory.systemTemp.createTemp('scan_test');
    Future<void> touch(String relative) async {
      final file = File('${root.path}/$relative');
      await file.parent.create(recursive: true);
      await file.writeAsString('x');
    }

    await touch('Rock/tema1.mp3');
    await touch('Rock/Live/tema2.FLAC');
    await touch('notas.txt');
    await touch(r'$Recycle.Bin/borrado.mp3');
    await touch('AppData/cache.mp3');
    await touch('.oculta/secreto.mp3');

    final scan =
        await scanMusic([root.path], extensions: libraryAudioExtensions).last;
    final names = scan.found
        .map((f) => f.path.split(Platform.pathSeparator).last)
        .toSet();
    expect(names, {'tema1.mp3', 'tema2.FLAC'});
    await root.delete(recursive: true);
  });

  test('una carpeta que no existe o no se puede leer no rompe el escaneo',
      () async {
    final scan = await scanMusic([
      '${Directory.systemTemp.path}/no_existe_${DateTime.now().microsecondsSinceEpoch}',
    ], extensions: libraryAudioExtensions)
        .last;
    expect(scan.found, isEmpty);
    expect(scan.done, isTrue);
  });
}
