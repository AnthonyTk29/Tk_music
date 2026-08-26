import 'package:flutter/foundation.dart';

@immutable
class Song {
  const Song({
    required this.id,
    required this.mediaStoreId,
    required this.title,
    required this.filePath,
    this.artist,
    this.album,
    this.duration,
  });

  final int id;
  final int mediaStoreId;
  final String title;
  final String filePath;
  final String? artist;
  final String? album;
  final Duration? duration;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Song && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
