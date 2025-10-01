import 'package:audio_service/audio_service.dart';
import '../services/audio_handler.dart';

class AudioController {
  static late AudioHandler audioHandler;

  // Inicializa el AudioHandler en background
  static Future<void> init() async {
    audioHandler = await AudioService.init(
      builder: () => MyAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.tumusica.channel.audio',
        androidNotificationChannelName: 'Reproductor',
        androidNotificationOngoing: true,
      ),
    );
  }

  // Método para cargar canción
  static Future<void> loadSong(String path) async {
    // Forzamos el tipo a MyAudioHandler para poder usar load()
    final handler = audioHandler as MyAudioHandler;
    await handler.load(path);
  }

  static Future<void> play() => audioHandler.play();
  static Future<void> pause() => audioHandler.pause();
  static Future<void> stop() => audioHandler.stop();
}
