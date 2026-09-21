import 'package:flutter/foundation.dart';

@immutable
class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    required this.songIds,
  });

  final String id;
  final String name;

  /// Ids de MediaStore, en el orden de la playlist.
  final List<int> songIds;

  Playlist copyWith({String? name, List<int>? songIds}) => Playlist(
        id: id,
        name: name ?? this.name,
        songIds: songIds ?? this.songIds,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Playlist && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
