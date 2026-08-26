import 'dart:typed_data';

import 'package:on_audio_query_forked/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:io';

class SongLocalDatasource {
  SongLocalDatasource({OnAudioQuery? query}) : _query = query ?? OnAudioQuery();

  final OnAudioQuery _query;

  Future<List<SongModel>> fetchSongs() async {
    final granted = await requestPermission();
    if (!granted) return [];
    return _query.querySongs();
  }

  Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return true;

    final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;

    if (sdk >= 33) {
      final audio = await Permission.audio.request();
      await Permission.notification.request();
      return audio.isGranted;
    }

    return (await Permission.storage.request()).isGranted;
  }

  Future<bool> get hasPermission async {
    if (!Platform.isAndroid) return true;

    final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;

    if (sdk >= 33) {
      return (await Permission.audio.status).isGranted;
    }

    return (await Permission.storage.status).isGranted;
  }

  Future<Uint8List?> fetchArtwork(int songId) => _query.queryArtwork(
        songId,
        ArtworkType.AUDIO,
        format: ArtworkFormat.JPEG,
        size: 512,
      );
}
