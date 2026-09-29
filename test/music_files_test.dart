import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tk_music/services/dj/music_files.dart';

MusicFile _file(String path, {int size = 1000, int day = 1}) =>
    MusicFile(path: path, size: size, modified: DateTime(2026, 1, day));

void main() {
  group('canciones repetidas', () {
    test('mismo tema con nombres distintos da la misma clave', () {
      final key = duplicateKey('LA DROGA.mp3');
      for (final name in [
        '003 - LA DROGA.mp3',
        'La Droga (HQ).mp3',
        'la droga - copia.wav',
        'La_Droga (1).mp3',
        'La Droga from YouTube.mp3',
        'La Dróga xxx.mp3',
      ]) {
        expect(duplicateKey(name), key, reason: name);
      }
      expect(duplicateKey('La Droga Mix.mp3'), isNot(key));
      // Números distintos son canciones distintas ("Vol. 1" y "Vol. 2").
      expect(duplicateKey('Salsa brava 1.mp3'),
          isNot(duplicateKey('Salsa brava 2.mp3')));
      expect(duplicateKey('La droga - copia (2).mp3'), key);
      // Número de pista con el punto pegado, como "007.grupo caneo".
      final negrita = duplicateKey('grupo caneo - negrita.mp3');
      for (final name in [
        '007.grupo caneo - negrita.mp3',
        '12. Grupo Caneo - Negrita.mp3',
        '05 Grupo Caneo - Negrita.mp3',
        '3)Grupo Caneo - Negrita (from YouTube).mp3',
      ]) {
        expect(duplicateKey(name), negrita, reason: name);
      }
      // Un número que es parte del título se queda.
      expect(duplicateKey('1999.mp3'), isNot(duplicateKey('2000.mp3')));
    });

    test('agrupa, marca las repetidas y detecta copias idénticas', () {
      final groups = groupDuplicates([
        _file(r'C:\a\Negrita.mp3', size: 500, day: 1),
        _file(r'D:\b\La droga.mp3', size: 900, day: 1),
        _file(r'C:\c\003 - LA DROGA.mp3', size: 900, day: 3),
        _file(r'C:\d\la droga (1).wav', size: 900, day: 2),
      ]);
      expect(groups, hasLength(2));
      final droga = groups.firstWhere((g) => g.repeated);
      expect(droga.files, hasLength(3));
      expect(droga.identicalCopies, isTrue);
      // La copia más reciente primero.
      expect(droga.first.path, r'C:\c\003 - LA DROGA.mp3');
      expect(groups.firstWhere((g) => !g.repeated).first.name, 'Negrita');
    });
  });

  group('archivos en disco', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('tk_files');
      File(p.join(root.path, 'uno.mp3')).writeAsBytesSync([1, 2, 3]);
      File(p.join(root.path, 'dos.WAV')).writeAsBytesSync([1]);
      File(p.join(root.path, 'tres.flac')).writeAsBytesSync([1]);
      File(p.join(root.path, 'nota.txt')).writeAsStringSync('x');
      Directory(p.join(root.path, 'sub')).createSync();
      File(p.join(root.path, 'sub', 'cuatro.mp3')).writeAsBytesSync([1]);
      Directory(p.join(root.path, r'$RECYCLE.BIN')).createSync();
      File(p.join(root.path, r'$RECYCLE.BIN', 'borrada.mp3'))
          .writeAsBytesSync([1]);
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('una carpeta muestra subcarpetas y solo MP3/WAV', () async {
      final listing = await listFolder(root.path);
      expect(listing.folders.map(p.basename), ['sub']);
      expect(listing.files.map((f) => f.format), ['WAV', 'MP3']);
    });

    test('el escaneo recorre todo, filtra y saltea la papelera', () async {
      final last = await scanMusic([root.path]).last;
      expect(last.done, isTrue);
      expect(last.found.map((f) => p.basename(f.path)).toSet(),
          {'uno.mp3', 'dos.WAV', 'cuatro.mp3'});
    });

    test('un archivo se carga como canción con su nombre', () {
      final song = _file(r'C:\m\El trovador.mp3').toSong();
      expect(song.title, 'El trovador');
      expect(song.filePath, r'C:\m\El trovador.mp3');
    });
  });

  test('tamaño legible', () {
    expect(formatFileSize(3565158), '3,4 MB');
    expect(formatFileSize(2048), '2 KB');
  });

  test('la búsqueda en los discos no se corta si uno no se puede leer',
      () async {
    final dir = await Directory.systemTemp.createTemp('tk_scan_skip');
    addTearDown(() => dir.delete(recursive: true));
    File('${dir.path}${Platform.pathSeparator}tema.mp3')
        .writeAsBytesSync([1, 2, 3]);
    final last = await scanMusic([r'Q:\', dir.path]).last;
    expect(last.done, isTrue);
    expect(last.found.map((f) => f.name), ['tema']);
    expect(last.unreadable.single.$1, r'Q:\');
  });

  test('listar los discos nunca falla', () {
    expect(() => listDriveInfo(), returnsNormally);
    expect(listDrives(), isNotEmpty);
  });
}
