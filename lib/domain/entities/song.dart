import 'package:meta/meta.dart';

@immutable
class Song {
  const Song({
    required this.mediaStoreId,
    required this.title,
    required this.filePath,
    this.artist,
    this.album,
    this.duration,
    this.dateAdded,
    this.genre,
  });

  final int mediaStoreId;
  final String title;
  final String filePath;
  final String? artist;
  final String? album;
  final Duration? duration;

  /// Fecha en que MediaStore indexó el archivo (no siempre es cuándo se
  /// descargó/copió realmente, pero es lo más cercano disponible).
  final DateTime? dateAdded;

  /// Género leído de las etiquetas ID3 del archivo, si tiene. Muchos MP3
  /// no lo traen, así que puede venir vacío o inconsistente.
  final String? genre;

  Song copyWith({
    String? title,
    String? artist,
    String? album,
    String? genre,
  }) =>
      Song(
        mediaStoreId: mediaStoreId,
        title: title ?? this.title,
        filePath: filePath,
        artist: artist ?? this.artist,
        album: album ?? this.album,
        duration: duration,
        dateAdded: dateAdded,
        genre: genre ?? this.genre,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Song && mediaStoreId == other.mediaStoreId;

  @override
  int get hashCode => mediaStoreId.hashCode;
}
