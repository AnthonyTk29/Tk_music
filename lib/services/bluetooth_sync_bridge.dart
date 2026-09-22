import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

class PairedBluetoothDevice {
  const PairedBluetoothDevice({required this.name, required this.address});

  final String name;
  final String address;
}

/// Capacidad de sincronización Bluetooth del dispositivo, calculada del lado
/// nativo antes de ofrecer los roles: cuántas sesiones RFCOMM simultáneas
/// puede sostener (máximo del estándar BR/EDR) y si Bluetooth clásico
/// existe siquiera (sin eso la función no puede funcionar).
class SyncCapacity {
  const SyncCapacity({
    required this.supported,
    required this.maxConcurrent,
    this.reason,
  });

  final bool supported;
  final int maxConcurrent;
  final String? reason;
}

sealed class BluetoothSyncEvent {}

class ConnectedEvent extends BluetoothSyncEvent {
  ConnectedEvent(this.deviceName, this.address);
  final String deviceName;
  final String address;
}

class DisconnectedEvent extends BluetoothSyncEvent {
  DisconnectedEvent(this.reason, this.address);
  final String reason;
  final String address;
}

class ErrorEvent extends BluetoothSyncEvent {
  ErrorEvent(this.message);
  final String message;
}

/// Un dispositivo emparejado conectó (true) o desconectó (false) su sesión
/// Bluetooth activa (broadcast ACL del sistema). Lo usa la pantalla para
/// marcar en vivo cuáles tienen conexión "activa ahora".
class DeviceConnectionChangedEvent extends BluetoothSyncEvent {
  DeviceConnectionChangedEvent(this.address, this.connected);
  final String address;
  final bool connected;
}

class MessageEvent extends BluetoothSyncEvent {
  MessageEvent(this.payload, this.address);
  final Map<String, dynamic> payload;
  final String address;
}

class FileProgressEvent extends BluetoothSyncEvent {
  FileProgressEvent(this.received, this.total, this.address);
  final int received;
  final int total;
  final String address;
}

class SendProgressEvent extends BluetoothSyncEvent {
  SendProgressEvent(this.sent, this.total, this.address);
  final int sent;
  final int total;
  final String address;
}

class FileReceivedEvent extends BluetoothSyncEvent {
  FileReceivedEvent({
    required this.path,
    required this.title,
    this.artist,
    this.durationMs,
    required this.address,
  });
  final String path;
  final String title;
  final String? artist;
  final int? durationMs;
  final String address;
}

/// Puente con la sesión Bluetooth Classic (RFCOMM) nativa que usa
/// "Sincronizar con otro teléfono": transferencia del archivo de audio +
/// mensajes de control (play/pause/seek, sincronización de reloj), ahora
/// hacia hasta 4 invitados a la vez cuando se hace de anfitrión — por eso
/// cada evento trae [address], para saber de/hacia qué dispositivo es. La
/// lógica de sincronización en sí vive en [PartySyncEngine]; esto solo
/// entrega los eventos crudos. Ver BluetoothSyncBridge.kt.
class BluetoothSyncService {
  static const _channel = MethodChannel('tk_music/bluetooth_sync');
  static const _events = EventChannel('tk_music/bluetooth_sync/events');

  // `static`, no de instancia: un EventChannel solo admite un único
  // `receiveBroadcastStream()` registrado por canal. `BluetoothSyncService()`
  // se construye suelto en varios lugares (PartySyncEngine tiene el suyo
  // propio, y la pantalla de configuración crea otro aparte solo para
  // escuchar qué dispositivos tienen sesión Bluetooth activa) — si esto
  // fuera de instancia, el segundo `.listen()` le robaba el `eventSink`
  // nativo al primero sin que nadie se enterara (mismo bug ya visto y
  // arreglado en WaveformStore/SpectrogramStore), y esa pantalla dejaba de
  // recibir actualizaciones apenas arrancaba el motor de sincronización.
  static Stream<BluetoothSyncEvent>? _eventStream;

  Stream<BluetoothSyncEvent> get events {
    return _eventStream ??= _events.receiveBroadcastStream().map((raw) {
      final map = Map<String, dynamic>.from(raw as Map);
      final address = map['address'] as String? ?? '';
      return switch (map['type']) {
        'connected' =>
          ConnectedEvent(map['deviceName'] as String? ?? '', address),
        'disconnected' =>
          DisconnectedEvent(map['reason'] as String? ?? '', address),
        'error' => ErrorEvent(map['message'] as String? ?? 'Error'),
        'device_connected_changed' => DeviceConnectionChangedEvent(
          address,
          map['connected'] as bool? ?? false,
        ),
        'message' => MessageEvent(
            jsonDecode(map['json'] as String) as Map<String, dynamic>,
            address,
          ),
        'file_progress' => FileProgressEvent(
            (map['received'] as num).toInt(),
            (map['total'] as num).toInt(),
            address,
          ),
        'send_progress' => SendProgressEvent(
            (map['sent'] as num).toInt(),
            (map['total'] as num).toInt(),
            address,
          ),
        'file_received' => FileReceivedEvent(
            path: map['path'] as String,
            title: map['title'] as String? ?? '',
            artist: (map['artist'] as String? ?? '').isEmpty
                ? null
                : map['artist'] as String,
            durationMs: (map['durationMs'] as num?)?.toInt(),
            address: address,
          ),
        _ => ErrorEvent('Evento desconocido: ${map['type']}'),
      };
    });
  }

  Future<List<PairedBluetoothDevice>> getPairedDevices() async {
    final result =
        await _channel.invokeListMethod<Object?>('getPairedDevices');
    if (result == null) return const [];
    return result.map((item) {
      final map = Map<String, dynamic>.from(item as Map);
      return PairedBluetoothDevice(
        name: map['name'] as String,
        address: map['address'] as String,
      );
    }).toList();
  }

  Future<void> startHosting() => _channel.invokeMethod('startHosting');

  /// Direcciones de los dispositivos que tienen una sesión Bluetooth activa
  /// en este momento (no solo los conectados a esta app: cualquier ACL
  /// activo, p. ej. unos auriculares que están sonando esa conexión).
  Future<Set<String>> getActiveDeviceAddresses() async {
    final result =
        await _channel.invokeListMethod<String>('getActiveSessions');
    return (result ?? const []).toSet();
  }

  /// Pregunta al teléfono cuántas sesiones Bluetooth activas puede mantener
  /// y si Bluetooth clásico (RFCOMM) está disponible.
  Future<SyncCapacity> capacity() async {
    final result =
        await _channel.invokeMapMethod<String, Object?>('getCapacity');
    if (result == null) {
      return const SyncCapacity(supported: false, maxConcurrent: 0);
    }
    return SyncCapacity(
      supported: result['supported'] as bool? ?? false,
      maxConcurrent: result['maxConcurrent'] as int? ?? 0,
      reason: result['reason'] as String?,
    );
  }

  Future<void> connectToDevice(String address) =>
      _channel.invokeMethod('connectToDevice', {'address': address});

  Future<void> sendSongFile({
    required String path,
    required String title,
    String? artist,
    int? durationMs,
  }) {
    return _channel.invokeMethod('sendSongFile', {
      'path': path,
      'title': title,
      'artist': artist,
      'durationMs': durationMs,
    });
  }

  /// Le manda el archivo a un solo invitado — para alguien que se conecta
  /// después de que ya se mandó la canción al resto (p. ej. tras "Empezar
  /// con los que ya están"), sin reenviárselo de nuevo a los que ya lo
  /// tienen.
  Future<void> sendSongFileTo({
    required String address,
    required String path,
    required String title,
    String? artist,
    int? durationMs,
  }) {
    return _channel.invokeMethod('sendSongFileTo', {
      'address': address,
      'path': path,
      'title': title,
      'artist': artist,
      'durationMs': durationMs,
    });
  }

  /// Difunde [message] a todos los conectados (anfitrión -> todos los
  /// invitados, o invitado -> su único anfitrión).
  Future<void> sendControl(Map<String, dynamic> message) {
    return _channel
        .invokeMethod('sendControl', {'json': jsonEncode(message)});
  }

  /// Le manda [message] a un invitado puntual — lo usa el anfitrión para
  /// responder la ronda de reloj de cada invitado por separado.
  Future<void> sendControlTo(String address, Map<String, dynamic> message) {
    return _channel.invokeMethod(
      'sendControlTo',
      {'address': address, 'json': jsonEncode(message)},
    );
  }

  Future<void> disconnect() => _channel.invokeMethod('disconnect');
}
