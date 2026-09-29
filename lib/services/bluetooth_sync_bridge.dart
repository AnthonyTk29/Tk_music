import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'sync_transport.dart';

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

/// Empezó a llegar un archivo: ya existe en [path] (con su tamaño final) y
/// se va llenando a medida que llegan los trozos — lo usa el streaming para
/// reproducir antes de tenerlo completo.
class FileStartedEvent extends BluetoothSyncEvent {
  FileStartedEvent({
    required this.transferId,
    required this.path,
    required this.total,
    required this.meta,
    required this.address,
  });
  final String transferId;
  final String path;
  final int total;
  final Map<String, dynamic> meta;
  final String address;
}

/// Avance de un archivo entrante. Los bytes ya escritos en disco son
/// `[0, head)` más `[tailFrom, tailEnd)`: el final del archivo viaja primero
/// (tags/índice que el reproductor lee al abrirlo) y después el resto en
/// orden.
class FileProgressEvent extends BluetoothSyncEvent {
  FileProgressEvent({
    required this.transferId,
    required this.received,
    required this.total,
    required this.head,
    required this.tailFrom,
    required this.tailEnd,
    required this.address,
  });
  final String transferId;
  final int received;
  final int total;
  final int head;
  final int tailFrom;
  final int tailEnd;
  final String address;
}

class SendProgressEvent extends BluetoothSyncEvent {
  SendProgressEvent(this.transferId, this.sent, this.total, this.address);
  final String transferId;
  final int sent;
  final int total;
  final String address;
}

class FileReceivedEvent extends BluetoothSyncEvent {
  FileReceivedEvent({
    required this.transferId,
    required this.path,
    required this.title,
    this.artist,
    this.durationMs,
    required this.meta,
    required this.address,
  });
  final String transferId;
  final String path;
  final String title;
  final String? artist;
  final int? durationMs;
  final Map<String, dynamic> meta;
  final String address;
}

/// Un archivo entrante se descartó a medias (el anfitrión canceló el envío
/// o se cortó la conexión); el archivo parcial ya se borró.
class FileAbortedEvent extends BluetoothSyncEvent {
  FileAbortedEvent(this.transferId, this.address);
  final String transferId;
  final String address;
}

/// Puente con la sesión Bluetooth Classic (RFCOMM) nativa que usa
/// "Sincronizar con otro dispositivo": transferencia de archivos de audio +
/// mensajes de control (play/pause/seek, sincronización de reloj), ahora
/// hacia hasta 6 invitados a la vez cuando se hace de anfitrión — por eso
/// cada evento trae [address], para saber de/hacia qué dispositivo es. La
/// lógica de sincronización en sí vive en [PartySyncEngine]; esto solo
/// entrega los eventos crudos. Ver BluetoothSyncBridge.kt.
class BluetoothSyncService implements SyncTransport {
  @override
  String get label => 'Bluetooth';

  /// 1 anfitrión + 6 invitados: deja un lugar libre del Bluetooth clásico
  /// (7 activos por anfitrión) para auriculares o un parlante.
  @override
  int get maxGuests => 6;

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

  @override
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
        'file_started' => FileStartedEvent(
            transferId: map['transferId'] as String? ?? '',
            path: map['path'] as String,
            total: (map['total'] as num).toInt(),
            meta: _decodeMeta(map['meta']),
            address: address,
          ),
        'file_progress' => FileProgressEvent(
            transferId: map['transferId'] as String? ?? '',
            received: (map['received'] as num).toInt(),
            total: (map['total'] as num).toInt(),
            head: (map['head'] as num?)?.toInt() ?? 0,
            tailFrom: (map['tailFrom'] as num?)?.toInt() ?? 0,
            tailEnd: (map['tailEnd'] as num?)?.toInt() ?? 0,
            address: address,
          ),
        'send_progress' => SendProgressEvent(
            map['transferId'] as String? ?? '',
            (map['sent'] as num).toInt(),
            (map['total'] as num).toInt(),
            address,
          ),
        'file_received' => FileReceivedEvent(
            transferId: map['transferId'] as String? ?? '',
            path: map['path'] as String,
            title: map['title'] as String? ?? '',
            artist: (map['artist'] as String? ?? '').isEmpty
                ? null
                : map['artist'] as String,
            durationMs: (map['durationMs'] as num?)?.toInt(),
            meta: _decodeMeta(map['meta']),
            address: address,
          ),
        'file_aborted' =>
          FileAbortedEvent(map['transferId'] as String? ?? '', address),
        _ => ErrorEvent('Evento desconocido: ${map['type']}'),
      };
    });
  }

  Future<List<PairedBluetoothDevice>> getPairedDevices() async {
    final result = await _channel.invokeListMethod<Object?>('getPairedDevices');
    if (result == null) return const [];
    return result.map((item) {
      final map = Map<String, dynamic>.from(item as Map);
      return PairedBluetoothDevice(
        name: map['name'] as String,
        address: map['address'] as String,
      );
    }).toList();
  }

  /// Nombre (y en Windows, dirección) del Bluetooth de este dispositivo:
  /// va en el QR para que el invitado encuentre al anfitrión entre sus
  /// emparejados. Android no deja a las apps leer la propia dirección.
  /// Siendo anfitrión en Windows, también el canal RFCOMM en el que escucha
  /// (va en el QR: el invitado lo prueba directo si no lo encuentra por SDP).
  Future<({String? name, String? address, int? channel})> localAdapter() async {
    try {
      final result =
          await _channel.invokeMapMethod<String, Object?>('getLocalAdapter');
      String? text(Object? v) =>
          v is String && v.trim().isNotEmpty ? v.trim() : null;
      final channel = result?['channel'];
      return (
        name: text(result?['name']),
        address: text(result?['address']),
        channel: channel is int && channel > 0 ? channel : null,
      );
    } catch (_) {
      return (name: null, address: null, channel: null);
    }
  }

  /// Canal RFCOMM de un anfitrión, conocido por su QR (dirección → canal).
  static final channelHints = <String, int>{};

  /// Abre el Bluetooth del sistema (para emparejar con el anfitrión).
  Future<void> openSystemSettings() async {
    try {
      if (Platform.isWindows) {
        await launchUrl(Uri.parse('ms-settings:bluetooth'));
      } else {
        await _channel.invokeMethod('openBluetoothSettings');
      }
    } catch (_) {
      // Sin forma de abrirlo: el mensaje ya dice qué hacer.
    }
  }

  @override
  Future<void> startHosting() => _channel.invokeMethod('startHosting');

  /// Direcciones de los dispositivos que tienen una sesión Bluetooth activa
  /// en este momento (no solo los conectados a esta app: cualquier ACL
  /// activo, p. ej. unos auriculares que están sonando esa conexión).
  Future<Set<String>> getActiveDeviceAddresses() async {
    final result = await _channel.invokeListMethod<String>('getActiveSessions');
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

  /// Conecta con el anfitrión. En Android se prueban varias formas (ver
  /// BluetoothSyncBridge.kt), con el canal del QR si se conoce.
  @override
  Future<void> connectToDevice(String address) =>
      _channel.invokeMethod('connectToDevice', {
        'address': address,
        if (channelHints[address.toUpperCase()] != null)
          'channel': channelHints[address.toUpperCase()],
      });

  /// Le manda un archivo a un invitado. Viaja en trozos: mientras tanto los
  /// mensajes de control siguen pasando. [transferId] identifica el envío
  /// en los eventos de progreso de los dos lados; [extra] llega intacto en
  /// la metadata del lado que recibe. Tira `PlatformException` con código
  /// `CANCELLED` si se cortó con [cancelTransfer].
  @override
  Future<void> sendSongFileTo({
    required String address,
    required String path,
    required String title,
    String? artist,
    int? durationMs,
    required String transferId,
    Map<String, dynamic>? extra,
  }) {
    return _channel.invokeMethod('sendSongFileTo', {
      'address': address,
      'path': path,
      'title': title,
      'artist': artist,
      'durationMs': durationMs,
      'transferId': transferId,
      'extraJson': extra == null ? null : jsonEncode(extra),
    });
  }

  /// Corta el envío de archivo en curso hacia [address], si hay uno.
  @override
  Future<void> cancelTransfer(String address) =>
      _channel.invokeMethod('cancelTransfer', {'address': address});

  /// Difunde [message] a todos los conectados (anfitrión -> todos los
  /// invitados, o invitado -> su único anfitrión).
  @override
  Future<void> sendControl(Map<String, dynamic> message) {
    return _channel.invokeMethod('sendControl', {'json': jsonEncode(message)});
  }

  /// Le manda [message] a un invitado puntual — lo usa el anfitrión para
  /// responder la ronda de reloj de cada invitado por separado.
  @override
  Future<void> sendControlTo(String address, Map<String, dynamic> message) {
    return _channel.invokeMethod(
      'sendControlTo',
      {'address': address, 'json': jsonEncode(message)},
    );
  }

  @override
  Future<void> disconnect() => _channel.invokeMethod('disconnect');

  static Map<String, dynamic> _decodeMeta(Object? raw) {
    if (raw is! String || raw.isEmpty) return const {};
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } on FormatException {
      return const {};
    }
  }
}
