import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:tk_music/core/errors/app_exception.dart';
import 'package:tk_music/data/repositories/desktop_audio_import_repository.dart';
import 'package:tk_music/domain/entities/song.dart';

void main() {
  late Directory temp;
  late List<String> added;
  late DesktopAudioImportRepository repository;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tk_import');
    added = [];
    repository = DesktopAudioImportRepository(
      musicFolder: p.join(temp.path, 'TK Music'),
      onAdded: (paths) async => added.addAll(paths),
    );
  });

  tearDown(() => temp.delete(recursive: true));

  test('copia a su subcarpeta, no pisa y lo suma a la biblioteca', () async {
    final source = File(p.join(temp.path, 'AUD-20260101-WA0001.opus'));
    await source.writeAsString('audio');
    final original = Song(mediaStoreId: 1, title: 'x', filePath: source.path);

    final first = await repository.importWhatsAppAudio(original,
        fileName: 'Nota.opus', mimeType: 'audio/ogg');
    final second = await repository.importWhatsAppAudio(original,
        fileName: 'Nota.opus', mimeType: 'audio/ogg');
    final download = await repository.saveDownloadedSong(source.path,
        fileName: 'Tema.mp3', mimeType: 'audio/mpeg');

    expect(p.basename(p.dirname(first)), 'Audios de WhatsApp');
    expect(p.basename(first), 'Nota.opus');
    expect(p.basename(second), 'Nota (2).opus');
    expect(p.basename(p.dirname(download)), 'Descargas');
    expect(added, [first, second, download]);
    // El original no se toca.
    expect(await source.readAsString(), 'audio');
  });

  test('si el original no existe, avisa con un mensaje para mostrar', () async {
    await expectLater(
      repository.saveDownloadedSong(p.join(temp.path, 'no_existe.mp3'),
          fileName: 'Tema.mp3', mimeType: 'audio/mpeg'),
      throwsA(isA<AppException>()
          .having((e) => e.userMessage, 'userMessage', startsWith('Tema.mp3'))),
    );
    expect(added, isEmpty);
  });
}
