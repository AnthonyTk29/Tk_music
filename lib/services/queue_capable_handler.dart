import 'package:audio_service/audio_service.dart';

/// `MyAudioHandler` (Android) y `DesktopAudioHandler` (Windows/Linux/macOS)
/// implementan esto con la misma firma — así el resto de la app puede
/// armar/reordenar la cola sin importar cuál de los dos está corriendo, en
/// vez de castear directo a `MyAudioHandler` (que en desktop tiraría
/// `TypeError` porque ahí el handler real es otra clase).
abstract class QueueCapableHandler {
  Future<void> setQueue(
    List<MediaItem> items, {
    int startIndex = 0,
    bool resumeLastPosition = false,
  });

  Future<void> moveQueueItem(int oldIndex, int newIndex);
}
