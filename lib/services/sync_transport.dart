import 'bluetooth_sync_bridge.dart';

/// Canal por el que viaja una sesión de "Sincronizar con otro dispositivo":
/// Bluetooth clásico ([BluetoothSyncService]) o Wi-Fi
/// (WifiSyncService). Los dos emiten los mismos eventos
/// ([BluetoothSyncEvent] y sus subclases, con `address` identificando a
/// cada dispositivo) y hablan el mismo protocolo (mensajes de control en
/// JSON y archivos en trozos), así [PartySyncEngine] no sabe cuál usa.
abstract class SyncTransport {
  /// "Bluetooth" / "Wi-Fi", para mostrar.
  String get label;

  /// Cuántos invitados puede sostener a la vez.
  int get maxGuests;

  Stream<BluetoothSyncEvent> get events;

  Future<void> startHosting();
  Future<void> connectToDevice(String address);
  Future<void> sendControl(Map<String, dynamic> message);
  Future<void> sendControlTo(String address, Map<String, dynamic> message);

  /// Tira `PlatformException` con código `CANCELLED` si se cortó con
  /// [cancelTransfer].
  Future<void> sendSongFileTo({
    required String address,
    required String path,
    required String title,
    String? artist,
    int? durationMs,
    required String transferId,
    Map<String, dynamic>? extra,
  });

  Future<void> cancelTransfer(String address);
  Future<void> disconnect();
}
