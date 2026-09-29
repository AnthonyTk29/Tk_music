import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tk_music/services/id3.dart';

/// Audio "falso" reconocible, para comprobar que no se toca.
final _audio = Uint8List.fromList(List.generate(5000, (i) => (i * 7) % 256));

Uint8List _withTag(Id3Tag tag, Map<String, String> texts, {Uint8List? cover}) =>
    tag.rebuild(Uint8List.fromList([..._audio]), texts: texts, cover: cover);

void main() {
  test('crea una etiqueta en un MP3 que no tenía y conserva el audio', () {
    final empty = Id3Tag.parse(_audio)!;
    expect(empty.version, 0);
    final bytes = _withTag(empty, {'TIT2': 'Canción ñandú', 'TPE1': 'Artista'});
    final tag = Id3Tag.parse(bytes)!;
    expect(tag.version, 3);
    expect(tag.text('TIT2'), 'Canción ñandú');
    expect(tag.text('TPE1'), 'Artista');
    expect(bytes.sublist(tag.audioOffset), _audio);
  });

  test('reemplaza solo lo editado y deja el resto de los frames', () {
    final first =
        _withTag(Id3Tag.parse(_audio)!, {'TIT2': 'Viejo', 'TALB': 'Álbum'});
    final tag = Id3Tag.parse(first)!;
    final second = tag.rebuild(first, texts: {'TIT2': 'Nuevo'});
    final edited = Id3Tag.parse(second)!;
    expect(edited.text('TIT2'), 'Nuevo');
    expect(edited.text('TALB'), 'Álbum');
    expect(second.sublist(edited.audioOffset), _audio);
  });

  test('pone y saca la carátula', () {
    final jpeg = Uint8List.fromList([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]);
    final withCover = _withTag(Id3Tag.parse(_audio)!, {}, cover: jpeg);
    final tag = Id3Tag.parse(withCover)!;
    final apic = tag.frame('APIC')!;
    expect(apic.data.sublist(apic.data.length - jpeg.length), jpeg);
    final without = tag.rebuild(withCover, removeCover: true);
    expect(Id3Tag.parse(without)!.frame('APIC'), isNull);
  });

  test('lee la letra embebida (USLT)', () {
    final data = [
      0,
      ...ascii.encode('spa'),
      0,
      ...latin1.encode('[00:01.00]Hola\n[00:02.50]Chau')
    ];
    final frame = [
      ...ascii.encode('USLT'),
      0,
      0,
      0,
      data.length,
      0,
      0,
      ...data
    ];
    final header = [...ascii.encode('ID3'), 3, 0, 0, 0, 0, 0, frame.length];
    final tag =
        Id3Tag.parse(Uint8List.fromList([...header, ...frame, ..._audio]))!;
    expect(tag.lyrics, '[00:01.00]Hola\n[00:02.50]Chau');
  });

  test('writeMp3Tags escribe el archivo sin tocar el audio', () async {
    final dir = await Directory.systemTemp.createTemp('id3_test');
    final file = File('${dir.path}/tema.mp3');
    await file.writeAsBytes(_audio);
    expect(
        await writeMp3Tags(file.path, title: 'Título', artist: 'Yo'), isTrue);
    final bytes = await file.readAsBytes();
    final tag = Id3Tag.parse(bytes)!;
    expect(tag.text('TIT2'), 'Título');
    expect(bytes.sublist(tag.audioOffset), _audio);
    await dir.delete(recursive: true);
  });
}
