import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'bluetooth_sync_bridge.dart';
import 'sync_transport.dart';

/// Un anfitrión encontrado en la red.
class WifiHost {
  const WifiHost(
      {required this.name, required this.address, required this.seenAt});

  final String name;

  /// "ip:puerto"
  final String address;
  final DateTime seenAt;
}

/// "Sincronizar con otro dispositivo" por Wi-Fi (misma red, o un teléfono
/// compartiendo datos como hotspot): TCP con el mismo protocolo que el
/// puente Bluetooth — mucho más rápido (las canciones llegan en segundos),
/// con más alcance y más invitados. Todo en Dart, igual en Android y
/// desktop.
///
/// Descubrimiento: el anfitrión se anuncia cada segundo por UDP
/// ([discoveryPort]); los invitados lo ven solo en la lista, o pueden
/// escribir su IP a mano.
class WifiSyncService implements SyncTransport {
  WifiSyncService({
    required this.deviceName,
    Future<Directory> Function()? receiveDir,
    InternetAddress? bindAddress,
    this.announce = true,
    this.helloTimeout = const Duration(seconds: 8),
  })  : _receiveDir = receiveDir ?? getTemporaryDirectory,
        _bindAddress = bindAddress ?? InternetAddress.anyIPv4;

  final String deviceName;
  final Future<Directory> Function() _receiveDir;
  final InternetAddress _bindAddress;

  /// Anunciarse en la red para que los invitados lo encuentren solos.
  final bool announce;

  /// Cuánto espera el invitado el saludo del anfitrión.
  final Duration helloTimeout;

  static const serverPort = 47810;
  static const discoveryPort = 47811;
  static const _frameHello = 0;
  static const _frameControl = 1;
  static const _frameFileStart = 3;
  static const _frameFileChunk = 4;
  static const _frameFileAbort = 5;
  static const _chunkSize = 64 * 1024;
  static const _tailSize = 256 * 1024;
  static const _progressStep = 256 * 1024;
  static const _wifiChannel = MethodChannel('tk_music/wifi');

  @override
  String get label => 'Wi-Fi';

  @override
  int get maxGuests => 15;

  final _events = StreamController<BluetoothSyncEvent>.broadcast();
  final Map<String, _Peer> _peers = {};
  ServerSocket? _server;
  RawDatagramSocket? _beaconSocket;
  Timer? _beaconTimer;
  bool _closing = false;

  @override
  Stream<BluetoothSyncEvent> get events => _events.stream;

  /// Puerto real del anfitrión (47810, u otro si ese estaba ocupado).
  int? get hostingPort => _server?.port;

  // ---------------------------------------------------------------------
  // Anfitrión
  // ---------------------------------------------------------------------

  @override
  Future<void> startHosting() async {
    _closing = false;
    try {
      _server = await ServerSocket.bind(_bindAddress, serverPort);
    } on SocketException {
      _server = await ServerSocket.bind(_bindAddress, 0);
    }
    _server!.listen((socket) {
      if (_peers.length >= maxGuests) {
        socket.destroy();
        return;
      }
      _attach(socket);
    });
    if (announce) await _startBeacon();
  }

  Future<void> _startBeacon() async {
    await _setMulticastLock(true);
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    _beaconSocket = socket;
    final targets = await _broadcastTargets();
    _beaconTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final payload = utf8.encode(jsonEncode({
        'app': 'tk_music',
        'v': 1,
        'name': deviceName,
        'port': _server?.port ?? serverPort,
      }));
      for (final target in targets) {
        try {
          socket.send(payload, target, discoveryPort);
        } catch (_) {
          // Una interfaz que no deja mandar broadcast: se sigue con las demás.
        }
      }
    });
  }

  /// 255.255.255.255 más el broadcast de cada red local (/24): en Windows
  /// con varias placas de red el broadcast general a veces sale por la
  /// equivocada.
  Future<List<InternetAddress>> _broadcastTargets() async {
    final targets = <InternetAddress>[InternetAddress('255.255.255.255')];
    for (final address in await localAddresses()) {
      final parts = address.split('.');
      if (parts.length == 4) {
        targets.add(InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'));
      }
    }
    return targets;
  }

  /// IPs de este dispositivo en la red local (para mostrarlas y que un
  /// invitado pueda escribirla a mano).
  static Future<List<String>> localAddresses() async {
    try {
      final interfaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      final addresses = <String>[];
      for (final interface in interfaces) {
        final name = interface.name.toLowerCase();
        // Adaptadores virtuales (VPN, VirtualBox, WSL…) quedan afuera.
        if (name.contains('virtual') ||
            name.contains('vethernet') ||
            name.contains('vmware')) {
          continue;
        }
        for (final address in interface.addresses) {
          if (!address.isLoopback && !address.isLinkLocal) {
            addresses.add(address.address);
          }
        }
      }
      return addresses;
    } catch (_) {
      return const [];
    }
  }

  // ---------------------------------------------------------------------
  // Invitado
  // ---------------------------------------------------------------------

  /// Anfitriones anunciándose en la red, actualizado en vivo.
  static Stream<List<WifiHost>> discoverHosts() {
    late StreamController<List<WifiHost>> controller;
    RawDatagramSocket? socket;
    Timer? pruneTimer;
    final hosts = <String, WifiHost>{};

    void publish() {
      final now = DateTime.now();
      hosts.removeWhere((_, host) =>
          now.difference(host.seenAt) > const Duration(seconds: 4));
      controller
          .add(hosts.values.toList()..sort((a, b) => a.name.compareTo(b.name)));
    }

    controller = StreamController<List<WifiHost>>(
      onListen: () async {
        await _setMulticastLock(true);
        try {
          socket = await RawDatagramSocket.bind(
              InternetAddress.anyIPv4, discoveryPort,
              reuseAddress: true);
        } catch (e) {
          controller.addError(e);
          return;
        }
        socket!.listen((event) {
          if (event != RawSocketEvent.read) return;
          final datagram = socket!.receive();
          if (datagram == null) return;
          try {
            final data =
                jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;
            if (data['app'] != 'tk_music') return;
            final address = '${datagram.address.address}:${data['port']}';
            hosts[address] = WifiHost(
              name: data['name'] as String? ?? datagram.address.address,
              address: address,
              seenAt: DateTime.now(),
            );
            publish();
          } catch (_) {
            // Paquete de otra cosa en ese puerto: se ignora.
          }
        });
        pruneTimer =
            Timer.periodic(const Duration(seconds: 2), (_) => publish());
        publish();
      },
      onCancel: () async {
        pruneTimer?.cancel();
        socket?.close();
        await _setMulticastLock(false);
      },
    );
    return controller.stream;
  }

  /// [address]: "ip", "ip:puerto" o varias separadas por coma (las del QR,
  /// con la de la misma red primero): se prueban en orden. Vuelve recién
  /// cuando el anfitrión saludó; si rechaza la conexión (sala llena) o no
  /// contesta, tira `PlatformException` con el motivo de cada intento.
  @override
  Future<void> connectToDevice(String address) async {
    _closing = false;
    final candidates = address
        .split(',')
        .map((a) => a.trim())
        .where((a) => a.isNotEmpty)
        .toList();
    final errors = <String>[];
    for (final candidate in candidates) {
      final (host, port) = _parseAddress(candidate);
      _Peer? peer;
      try {
        final socket = await Socket.connect(host, port,
            timeout: const Duration(seconds: 6));
        peer = _attach(socket, addressOverride: '$host:$port');
        await peer.hello.future.timeout(helloTimeout);
        return;
      } on TimeoutException {
        if (peer != null) _drop(peer, 'Sin respuesta');
        errors.add('$host:$port: el anfitrión no respondió');
      } on SocketException catch (e) {
        errors.add('$host:$port: ${e.osError?.message ?? e.message}');
      } on PlatformException catch (e) {
        errors.add('$host:$port: ${e.message}');
      }
    }
    throw PlatformException(
      code: 'CONNECT_FAILED',
      message:
          errors.isEmpty ? 'Sin dirección del anfitrión' : errors.join(' | '),
    );
  }

  static (String, int) _parseAddress(String address) {
    final trimmed = address.trim();
    final colon = trimmed.lastIndexOf(':');
    if (colon > 0) {
      final port = int.tryParse(trimmed.substring(colon + 1));
      if (port != null) return (trimmed.substring(0, colon), port);
    }
    return (trimmed, serverPort);
  }

  // ---------------------------------------------------------------------
  // Conexiones
  // ---------------------------------------------------------------------

  _Peer _attach(Socket socket, {String? addressOverride}) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    final address = addressOverride ??
        '${socket.remoteAddress.address}:${socket.remotePort}';
    final peer = _Peer(address, socket);
    _peers[address] = peer;
    socket.listen(
      (data) =>
          peer.receive(data, (type, payload) => _onFrame(peer, type, payload)),
      onError: (Object e) => _drop(peer, '$e'),
      onDone: () => _drop(peer, 'Se cerró la conexión'),
      cancelOnError: true,
    );
    unawaited(peer.write(
        _frame(_frameHello, utf8.encode(jsonEncode({'name': deviceName})))));
    return peer;
  }

  Future<void> _onFrame(_Peer peer, int type, Uint8List payload) async {
    switch (type) {
      case _frameHello:
        if (peer.greeted) return;
        peer.greeted = true;
        try {
          peer.name =
              (jsonDecode(utf8.decode(payload)) as Map)['name'] as String? ??
                  peer.address;
        } catch (_) {
          peer.name = peer.address;
        }
        _events.add(ConnectedEvent(peer.name, peer.address));
        if (!peer.hello.isCompleted) peer.hello.complete();
      case _frameControl:
        final map = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
        _events.add(MessageEvent(map, peer.address));
      case _frameFileStart:
        await _startIncoming(
            peer, jsonDecode(utf8.decode(payload)) as Map<String, dynamic>);
      case _frameFileChunk:
        await _writeChunk(peer, payload);
      case _frameFileAbort:
        await _abortIncoming(peer);
    }
  }

  Future<void> _startIncoming(_Peer peer, Map<String, dynamic> meta) async {
    await _abortIncoming(peer);
    final size = (meta['fileSize'] as num?)?.toInt() ?? 0;
    final transferId = meta['transferId'] as String? ?? '';
    final safeName = (meta['fileName'] as String? ?? 'cancion.mp3')
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final dir = Directory(
        '${(await _receiveDir()).path}${Platform.pathSeparator}tk_sync');
    await dir.create(recursive: true);
    final file = File(
        '${dir.path}${Platform.pathSeparator}sync_${DateTime.now().millisecondsSinceEpoch}_$safeName');
    final raf = await file.open(mode: FileMode.write);
    await raf.truncate(size);
    final incoming = _IncomingFile(transferId, meta, file, raf, size);
    peer.incoming = incoming;
    _events.add(FileStartedEvent(
      transferId: transferId,
      path: file.path,
      total: size,
      meta: meta,
      address: peer.address,
    ));
    if (size == 0) await _finishIncoming(peer);
  }

  Future<void> _writeChunk(_Peer peer, Uint8List frame) async {
    final incoming = peer.incoming;
    if (incoming == null || frame.length < 8) return;
    final offset = ByteData.sublistView(frame, 0, 8).getInt64(0);
    final data = Uint8List.sublistView(frame, 8);
    if (offset < 0 || offset + data.length > incoming.size) return;
    await incoming.raf.setPosition(offset);
    await incoming.raf.writeFrom(data);
    incoming.received += data.length;
    if (offset == incoming.head) {
      incoming.head += data.length;
    } else {
      if (incoming.tailFrom == incoming.size) incoming.tailEnd = offset;
      incoming.tailFrom = math.min(incoming.tailFrom, offset);
      incoming.tailEnd = math.max(incoming.tailEnd, offset + data.length);
    }
    final done = incoming.received >= incoming.size;
    if (done || incoming.received - incoming.lastEmitted >= _progressStep) {
      incoming.lastEmitted = incoming.received;
      _events.add(FileProgressEvent(
        transferId: incoming.transferId,
        received: incoming.received,
        total: incoming.size,
        head: incoming.head,
        tailFrom: incoming.tailFrom,
        tailEnd: incoming.tailEnd,
        address: peer.address,
      ));
    }
    if (done) await _finishIncoming(peer);
  }

  Future<void> _finishIncoming(_Peer peer) async {
    final incoming = peer.incoming;
    if (incoming == null) return;
    peer.incoming = null;
    await incoming.raf.close();
    final artist = incoming.meta['artist'] as String? ?? '';
    _events.add(FileReceivedEvent(
      transferId: incoming.transferId,
      path: incoming.file.path,
      title: incoming.meta['title'] as String? ?? '',
      artist: artist.isEmpty ? null : artist,
      durationMs: (incoming.meta['durationMs'] as num?)?.toInt(),
      meta: incoming.meta,
      address: peer.address,
    ));
  }

  Future<void> _abortIncoming(_Peer peer) async {
    final incoming = peer.incoming;
    if (incoming == null) return;
    peer.incoming = null;
    try {
      await incoming.raf.close();
      await incoming.file.delete();
    } catch (_) {}
    _events.add(FileAbortedEvent(incoming.transferId, peer.address));
  }

  void _drop(_Peer peer, String reason) {
    if (_peers[peer.address] != peer) return;
    _peers.remove(peer.address);
    peer.cancelOutgoing = true;
    unawaited(_abortIncoming(peer));
    peer.socket.destroy();
    if (!peer.hello.isCompleted) {
      // Se cortó antes del saludo: el anfitrión la rechazó (sala llena) o
      // no era TK Music.
      peer.hello.completeError(PlatformException(
        code: 'REJECTED',
        message: 'el anfitrión cerró la conexión sin responder (puede que la '
            'sala esté llena: hasta $maxGuests invitados)',
      ));
    }
    if (!_closing && peer.greeted) {
      _events.add(DisconnectedEvent(reason, peer.address));
    }
  }

  // ---------------------------------------------------------------------
  // Envío
  // ---------------------------------------------------------------------

  static Uint8List _frame(int type, List<int> payload) {
    final out = Uint8List(5 + payload.length);
    out[0] = type;
    ByteData.sublistView(out, 1, 5).setUint32(0, payload.length);
    out.setRange(5, out.length, payload);
    return out;
  }

  _Peer _peerFor(String address) {
    final peer = _peers[address];
    if (peer == null) {
      throw PlatformException(code: 'NOT_CONNECTED', message: 'No conectado');
    }
    return peer;
  }

  @override
  Future<void> sendControl(Map<String, dynamic> message) async {
    if (_peers.isEmpty) {
      throw PlatformException(
          code: 'NOT_CONNECTED', message: 'No hay conexión activa');
    }
    final frame = _frame(_frameControl, utf8.encode(jsonEncode(message)));
    await Future.wait([
      for (final peer in _peers.values.toList())
        peer.write(frame).catchError((Object _) {}),
    ]);
  }

  @override
  Future<void> sendControlTo(String address, Map<String, dynamic> message) =>
      _peerFor(address)
          .write(_frame(_frameControl, utf8.encode(jsonEncode(message))));

  @override
  Future<void> sendSongFileTo({
    required String address,
    required String path,
    required String title,
    String? artist,
    int? durationMs,
    required String transferId,
    Map<String, dynamic>? extra,
  }) async {
    final peer = _peerFor(address);
    // Un archivo saliente a la vez por conexión.
    final previous = peer.fileLock;
    final done = Completer<void>();
    peer.fileLock = done.future;
    await previous;
    try {
      peer.cancelOutgoing = false;
      final file = File(path);
      final total = await file.length();
      await peer.write(_frame(
        _frameFileStart,
        utf8.encode(jsonEncode({
          'transferId': transferId,
          'fileName': file.uri.pathSegments.isEmpty
              ? 'cancion.mp3'
              : file.uri.pathSegments.last,
          'fileSize': total,
          'title': title,
          'artist': artist ?? '',
          'durationMs': durationMs ?? 0,
          if (extra != null) 'extra': extra,
        })),
      ));
      // Primero el final (tags/índice que el reproductor lee al abrir), después
      // el resto en orden — igual que el puente Bluetooth.
      final ranges = total > 2 * _tailSize
          ? [(total - _tailSize, total), (0, total - _tailSize)]
          : [(0, total)];
      final raf = await file.open();
      var sent = 0;
      var lastEmitted = 0;
      try {
        for (final (start, end) in ranges) {
          var offset = start;
          while (offset < end) {
            if (peer.cancelOutgoing) {
              await peer
                  .write(_frame(_frameFileAbort, utf8.encode(transferId)));
              throw PlatformException(
                  code: 'CANCELLED', message: 'Envío cancelado');
            }
            final n = math.min(_chunkSize, end - offset);
            await raf.setPosition(offset);
            final data = await raf.read(n);
            final payload = Uint8List(8 + data.length);
            ByteData.sublistView(payload, 0, 8).setInt64(0, offset);
            payload.setRange(8, payload.length, data);
            await peer.write(_frame(_frameFileChunk, payload));
            offset += n;
            sent += n;
            if (sent == total || sent - lastEmitted >= _progressStep) {
              lastEmitted = sent;
              _events.add(SendProgressEvent(transferId, sent, total, address));
            }
          }
        }
      } finally {
        await raf.close();
      }
    } on SocketException catch (e) {
      throw PlatformException(code: 'SEND_FAILED', message: '$e');
    } finally {
      done.complete();
    }
  }

  @override
  Future<void> cancelTransfer(String address) async {
    _peers[address]?.cancelOutgoing = true;
  }

  @override
  Future<void> disconnect() async {
    _closing = true;
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _beaconSocket?.close();
    _beaconSocket = null;
    await _server?.close();
    _server = null;
    for (final peer in _peers.values.toList()) {
      peer.cancelOutgoing = true;
      await _abortIncoming(peer);
      peer.socket.destroy();
    }
    _peers.clear();
    await _setMulticastLock(false);
  }

  /// Android descarta los paquetes de difusión de la red si nadie pidió
  /// recibirlos (ahorro de batería): hace falta para el descubrimiento.
  static Future<void> _setMulticastLock(bool enabled) async {
    if (!Platform.isAndroid) return;
    try {
      await _wifiChannel.invokeMethod(
          enabled ? 'acquireMulticastLock' : 'releaseMulticastLock');
    } catch (e) {
      debugPrint('MulticastLock: $e');
    }
  }
}

class _Peer {
  _Peer(this.address, this.socket) {
    // Del lado del anfitrión nadie la espera: sin esto, un invitado que se
    // corta antes de saludar dejaría un error sin atender.
    hello.future.ignore();
  }

  /// Se completa con el saludo del otro lado (el invitado la espera para
  /// saber que el anfitrión lo aceptó).
  final hello = Completer<void>();

  final String address;
  final Socket socket;
  String name = '';
  bool greeted = false;
  bool cancelOutgoing = false;
  Future<void> fileLock = Future.value();
  _IncomingFile? incoming;

  // Escritura en orden: cada frame completo, uno detrás de otro (el socket
  // no admite escribir mientras espera a vaciarse).
  Future<void> _writeChain = Future.value();

  Future<void> write(Uint8List frame) {
    final next = _writeChain.then((_) async {
      socket.add(frame);
      await socket.flush();
    });
    _writeChain = next.catchError((Object _) {});
    return next;
  }

  // Lectura: se juntan los bytes hasta tener frames completos y se procesan
  // de a uno, en orden (escribir un trozo al disco es asincrónico).
  final _buffer = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);
  Future<void> _processChain = Future.value();

  void receive(Uint8List data,
      Future<void> Function(int type, Uint8List payload) onFrame) {
    _buffer.add(data);
    _processChain = _processChain.then((_) async {
      if (_buffer.isNotEmpty) {
        final added = _buffer.takeBytes();
        _pending = _pending.isEmpty
            ? added
            : (BytesBuilder(copy: false)
                  ..add(_pending)
                  ..add(added))
                .takeBytes();
      }
      var offset = 0;
      while (_pending.length - offset >= 5) {
        final length =
            ByteData.sublistView(_pending, offset + 1, offset + 5).getUint32(0);
        if (length > 16 * 1024 * 1024) {
          socket.destroy();
          return;
        }
        if (_pending.length - offset - 5 < length) break;
        final type = _pending[offset];
        final payload =
            Uint8List.sublistView(_pending, offset + 5, offset + 5 + length);
        offset += 5 + length;
        try {
          await onFrame(type, Uint8List.fromList(payload));
        } catch (e) {
          debugPrint('Frame Wi-Fi con error: $e');
        }
      }
      _pending = offset == 0
          ? _pending
          : Uint8List.fromList(Uint8List.sublistView(_pending, offset));
    });
  }
}

class _IncomingFile {
  _IncomingFile(this.transferId, this.meta, this.file, this.raf, this.size)
      : tailFrom = size,
        tailEnd = size;

  final String transferId;
  final Map<String, dynamic> meta;
  final File file;
  final RandomAccessFile raf;
  final int size;
  int received = 0;
  int head = 0;
  int tailFrom;
  int tailEnd;
  int lastEmitted = 0;
}
