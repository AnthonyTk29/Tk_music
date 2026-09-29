import 'package:flutter_test/flutter_test.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/presentation/models/library_groups.dart';

Song _song(int id, {String? album, String? artist}) => Song(
      mediaStoreId: id,
      title: 'Song $id',
      filePath: '/music/$id.mp3',
      album: album,
      artist: artist,
    );

void main() {
  group('groupByAlbum', () {
    test('agrupa canciones del mismo álbum y artista', () {
      final songs = [
        _song(1, album: 'Greatest Hits', artist: 'Queen'),
        _song(2, album: 'Greatest Hits', artist: 'Queen'),
        _song(3, album: 'Thriller', artist: 'Michael Jackson'),
      ];

      final groups = groupByAlbum(songs);

      expect(groups.length, 2);
      expect(
          groups.firstWhere((g) => g.name == 'Greatest Hits').songs.length, 2);
      expect(groups.firstWhere((g) => g.name == 'Thriller').songs.length, 1);
    });

    test('usa "Desconocido" para álbumes sin nombre', () {
      final groups = groupByAlbum([_song(1)]);
      expect(groups.single.name, 'Desconocido');
    });

    test('separa mismo nombre de álbum si el artista es distinto', () {
      final songs = [
        _song(1, album: 'Greatest Hits', artist: 'Queen'),
        _song(2, album: 'Greatest Hits', artist: 'Sia'),
      ];

      expect(groupByAlbum(songs).length, 2);
    });

    test('ordena alfabéticamente por nombre', () {
      final songs = [
        _song(1, album: 'Zeta'),
        _song(2, album: 'Alfa'),
      ];

      final groups = groupByAlbum(songs);
      expect(groups.map((g) => g.name), ['Alfa', 'Zeta']);
    });
  });

  group('groupByArtist', () {
    test('agrupa canciones del mismo artista', () {
      final songs = [
        _song(1, artist: 'Queen'),
        _song(2, artist: 'Queen'),
        _song(3, artist: 'Sia'),
      ];

      final groups = groupByArtist(songs);

      expect(groups.length, 2);
      expect(groups.firstWhere((g) => g.name == 'Queen').songs.length, 2);
    });

    test('usa "Desconocido" para artistas sin nombre', () {
      final groups = groupByArtist([_song(1)]);
      expect(groups.single.name, 'Desconocido');
    });
  });
}
