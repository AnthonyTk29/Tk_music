import 'package:tk_music/domain/entities/song.dart';

/// Agrupaciones puramente de UI, calculadas al vuelo desde la lista de
/// canciones ya cargada — no se persisten ni tienen identidad propia más
/// allá del nombre, así que no hace falta modelarlas como entidades de
/// dominio.
class AlbumGroup {
  const AlbumGroup({required this.name, required this.artist, required this.songs});

  final String name;
  final String? artist;
  final List<Song> songs;
}

class ArtistGroup {
  const ArtistGroup({required this.name, required this.songs});

  final String name;
  final List<Song> songs;
}

List<AlbumGroup> groupByAlbum(List<Song> songs) {
  final map = <String, List<Song>>{};
  for (final s in songs) {
    final key = '${s.album ?? 'Desconocido'}|${s.artist ?? ''}';
    map.putIfAbsent(key, () => []).add(s);
  }
  final groups = map.values.map((group) {
    return AlbumGroup(
      name: group.first.album ?? 'Desconocido',
      artist: group.first.artist,
      songs: group,
    );
  }).toList();
  groups.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return groups;
}

List<ArtistGroup> groupByArtist(List<Song> songs) {
  final map = <String, List<Song>>{};
  for (final s in songs) {
    final key = s.artist ?? 'Desconocido';
    map.putIfAbsent(key, () => []).add(s);
  }
  final groups =
      map.entries.map((e) => ArtistGroup(name: e.key, songs: e.value)).toList();
  groups.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return groups;
}
