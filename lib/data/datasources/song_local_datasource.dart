import 'dart:typed_data';

import 'package:on_audio_query_forked/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:io';

/// Extensiones de archivo que se muestran en la biblioteca. MediaStore indexa
/// como "audio" cualquier cosa, incluyendo notas de voz y audios reenviados
/// por WhatsApp — esas se sacan por ruta/patrón de nombre (ver más abajo),
/// no por extensión, así que acá se listan los formatos de música real más
/// comunes (incluye los que WhatsApp también usa para audios reenviados,
/// como m4a/opus/ogg, ya que "Importar de WhatsApp" copia el archivo tal
/// cual sin recodificarlo).
const _allowedExtensions = {'mp3', 'wav', 'm4a', 'aac', 'opus', 'ogg', 'flac'};

/// WhatsApp guarda las notas de voz y los audios reenviados con este patrón
/// de nombre (AUD-20260127-WA0014.mp3), incluso cuando el archivo termina en
/// .mp3 — así que el filtro de extensión solo no alcanza para sacarlos.
final _whatsappAudioPattern = RegExp(r'AUD-\d{8}-WA\d+', caseSensitive: false);

class SongLocalDatasource {
  SongLocalDatasource({OnAudioQuery? query}) : _query = query ?? OnAudioQuery();

  final OnAudioQuery _query;
  Future<bool>? _pendingRequest;

  Future<List<SongModel>> fetchSongs() async {
    // Si ya está concedido no hace falta volver a pedirlo en cada carga.
    final granted = await hasPermission || await requestPermission();
    if (!granted) return [];

    final songs = await _query.querySongs();
    return songs.where(_isRealMusic).toList();
  }

  /// Audios de WhatsApp (notas de voz y reenviados) que [fetchSongs] excluye
  /// de la biblioteca normal. Los usa la pantalla "Importar de WhatsApp"
  /// para poder elegir manualmente cuáles copiar a Download.
  Future<List<SongModel>> fetchWhatsAppAudios() async {
    final granted = await hasPermission || await requestPermission();
    if (!granted) return [];

    final songs = await _query.querySongs();
    return songs.where(_isWhatsAppAudio).toList();
  }

  bool _isRealMusic(SongModel song) {
    if (!_allowedExtensions.contains(song.fileExtension.toLowerCase())) {
      return false;
    }
    return !_isWhatsAppAudio(song);
  }

  bool _isWhatsAppAudio(SongModel song) {
    final path = song.data.toLowerCase();
    if (path.contains('/whatsapp/') || path.contains('whatsapp audio')) {
      return true;
    }
    return _whatsappAudioPattern.hasMatch(song.data);
  }

  /// `PermissionProvider` y `SongProvider` piden permiso de forma
  /// independiente al arrancar la app; sin esto, ambos llaman a
  /// `Permission.audio.request()` casi al mismo tiempo, y permission_handler
  /// lanza si hay dos solicitudes en curso. Se comparte la misma Future para
  /// que la segunda llamada espere el resultado de la primera en vez de
  /// disparar otra solicitud al sistema.
  Future<bool> requestPermission() {
    return _pendingRequest ??= _requestPermission().whenComplete(() {
      _pendingRequest = null;
    });
  }

  Future<bool> _requestPermission() async {
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
