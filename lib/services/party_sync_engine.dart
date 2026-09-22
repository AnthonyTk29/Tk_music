import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'package:tk_music/core/errors/app_error_code.dart';
import 'package:tk_music/core/errors/app_exception.dart';
import 'package:tk_music/domain/entities/song.dart';

import 'bluetooth_sync_bridge.dart';

enum PartyRole { host, guest }

enum PartySyncStatus {
  idle,
  waitingConnection,
  connected,
  transferringFile,
  syncingClock,
  waitingStart,
  playing,
  paused,
  finished,
  error,
}

/// Estado de un invitado desde el punto de vista del anfitrión.
class GuestInfo {
  GuestInfo({required this.address, required this.name});

  final String address;
  final String name;
  bool connected = true;
  bool ready = false;
}

/// Motor de "Sincronizar con otro teléfono": el anfitrión manda el archivo
/// y controla play/pause/seek; cada invitado (hasta [maxGuests] a la vez)
/// solo escucha y reproduce en espejo (así nunca compiten por el control y
/// no se desincronizan por decisiones contradictorias).
///
/// Sincronización de reloj: ronda tipo NTP simplificada iniciada por CADA
/// invitado por separado (5 ping/pong contra el anfitrión) para estimar su
/// propio offset de reloj; con eso el anfitrión manda un "arrancá a las X"
/// en su propio reloj (difundido a todos) y cada invitado lo convierte a su
/// hora local con SU offset.
///
/// Mientras suena, el anfitrión manda su posición cada 1s a todos (un timer
/// periódico corriendo todo el tiempo en segundo plano) para que cada
/// invitado corrija su propio drift: si es chico (25-300ms) lo hace con un
/// pequeño cambio de velocidad temporal en vez de un salto, para que no se
/// note el "tirón"; si es grande (>300ms, p. ej. tras una pausa) corrige de
/// una con un seek directo. No apunta a precisión de microsegundos porque
/// ni la posición que reporta el reproductor ni la latencia de Bluetooth
/// Classic la sostienen — el techo real son decenas de milisegundos, ya por
/// debajo del umbral en el que el oído humano distingue un eco.
class PartySyncEngine extends ChangeNotifier {
  final _bridge = BluetoothSyncService();
  final _player = AudioPlayer();
  StreamSubscription<BluetoothSyncEvent>? _eventsSub;
  Timer? _driftTimer;
  Timer? _speedResetTimer;
  final List<int> _offsetSamples = []; // Invitado: ronda contra el anfitrión.

  static const maxGuests = 4;
  static const _driftCheckInterval = Duration(seconds: 1);
  static const _ignoreDriftMs = 25;
  static const _hardSeekDriftMs = 300;
  static const _nudgeSpeedDelta = 0.04;

  PartyRole? _role;
  Song? _pendingSong;
  Duration? _clockOffset; // Invitado: offset respecto al anfitrión.
  bool _disposed = false;
  bool _songSent = false;
  int _expectedGuestCount = 1;

  final Map<String, GuestInfo> _guests = {}; // Anfitrión: por invitado.
  final Map<String, double> _sendProgressByGuest = {};

  PartySyncStatus status = PartySyncStatus.idle;
  String? statusMessage;
  double transferProgress = 0;
  String? currentTitle;
  String? currentArtist;

  bool get isHost => _role == PartyRole.host;
  AudioPlayer get player => _player;
  List<GuestInfo> get guests => _guests.values.toList(growable: false);
  int get connectedGuestCount =>
      _guests.values.where((g) => g.connected).length;

  /// Difunde un mensaje de control solo si hay a quién mandárselo. Cuando no
  /// quedan conexiones activas (todos los invitados se desconectaron, o el
  /// invitado todavía no terminó de conectarse), el puente nativo responde
  /// NOT_CONNECTED; interceptarlo acá evita que ese caso esperado llegue a
  /// Crashlytics como si fuera un crash.
  Future<void> _broadcastControl(Map<String, dynamic> payload) async {
    if (isHost && _guests.isEmpty) return;
    try {
      await _bridge.sendControl(payload);
    } catch (e) {
      debugPrint(
          'Control "${payload['type']}" omitido sin conexiones activas: $e');
    }
  }

  Future<void> startAsHost(List<PairedBluetoothDevice> expectedGuests, Song song) async {
    _role = PartyRole.host;
    _pendingSong = song;
    _expectedGuestCount = expectedGuests.length.clamp(1, maxGuests);
    _guests.clear();
    _songSent = false;
    status = PartySyncStatus.waitingConnection;
    statusMessage = 'Esperando invitados (0/$_expectedGuestCount)...';
    notifyListeners();

    _listen();
    try {
      await _bridge.startHosting();
    } catch (e) {
      // Todavía no hay ninguna sesión que mostrar (la pantalla sigue en el
      // paso de configuración) — no tiene sentido dejarla mostrando
      // "esperando invitados" para siempre, así que se vuelve a idle antes
      // de que la excepción suba sola hasta la alerta global.
      status = PartySyncStatus.idle;
      notifyListeners();
      throw AppException(
        AppErrorCode.btHostFailed,
        userMessage: 'No se pudo iniciar la sesión como anfitrión. Revisá '
            'que el Bluetooth esté activado y que le hayas dado el permiso '
            'a la app.',
        technicalMessage: 'startHosting: $e',
      );
    }
  }

  Future<void> joinAsGuest(PairedBluetoothDevice hostDevice) async {
    _role = PartyRole.guest;
    status = PartySyncStatus.waitingConnection;
    statusMessage = 'Conectando con "${hostDevice.name}"...';
    notifyListeners();

    _listen();
    try {
      await _bridge.connectToDevice(hostDevice.address);
    } catch (e) {
      status = PartySyncStatus.idle;
      notifyListeners();
      throw AppException(
        AppErrorCode.btConnectFailed,
        userMessage: 'No se pudo conectar con "${hostDevice.name}". '
            'Verificá que el anfitrión ya haya iniciado la sesión.',
        technicalMessage: 'connectToDevice: $e',
      );
    }
  }

  /// El anfitrión puede arrancar antes de que se conecten todos los
  /// invitados esperados, con los que ya están.
  void startWithConnectedGuestsNow() {
    if (!isHost || _songSent || _guests.isEmpty) return;
    unawaited(_sendPendingSong());
  }

  void _listen() {
    _eventsSub?.cancel();
    _eventsSub = _bridge.events.listen(_onEvent);
  }

  Future<void> _onEvent(BluetoothSyncEvent event) async {
    if (_disposed) return;
    switch (event) {
      case ConnectedEvent(:final deviceName, :final address):
        if (isHost) {
          _guests[address] = GuestInfo(address: address, name: deviceName);
          statusMessage =
              'Invitados conectados: $connectedGuestCount/$_expectedGuestCount';
          notifyListeners();
          if (!_songSent && connectedGuestCount >= _expectedGuestCount) {
            unawaited(_sendPendingSong());
          } else if (_songSent) {
            // Se conectó después de que ya se mandó la canción al resto
            // (p. ej. tras "Empezar con los que ya están") — se le manda
            // solo a él en vez de dejarlo esperando para siempre.
            unawaited(_sendSongTo(address));
          }
        } else {
          status = PartySyncStatus.connected;
          statusMessage = 'Conectado con $deviceName';
          notifyListeners();
        }
      case DisconnectedEvent(:final reason, :final address):
        if (isHost) {
          _guests.remove(address);
          _sendProgressByGuest.remove(address);
          if (_guests.isEmpty && status != PartySyncStatus.waitingConnection) {
            _driftTimer?.cancel();
            status = PartySyncStatus.error;
            statusMessage = 'Todos los invitados se desconectaron';
          } else {
            statusMessage =
                'Un invitado se desconectó${reason.isNotEmpty ? ": $reason" : ""} '
                '($connectedGuestCount/$_expectedGuestCount)';
          }
          notifyListeners();
        } else {
          _driftTimer?.cancel();
          status = PartySyncStatus.error;
          statusMessage =
              'Se cortó la conexión${reason.isNotEmpty ? ": $reason" : ""}';
          notifyListeners();
        }
      case ErrorEvent(:final message):
        status = PartySyncStatus.error;
        statusMessage = message;
        notifyListeners();
      case DeviceConnectionChangedEvent():
        // Solo la pantalla de configuración lo usa para marcar qué
        // dispositivos tienen sesión activa; el motor no necesita hacer nada.
        break;
      case SendProgressEvent(:final sent, :final total, :final address):
        status = PartySyncStatus.transferringFile;
        _sendProgressByGuest[address] = total == 0 ? 0 : sent / total;
        // El más atrasado de los invitados, para no mostrar 100% hasta que
        // todos terminaron de verdad.
        transferProgress = _sendProgressByGuest.values.isEmpty
            ? 0
            : _sendProgressByGuest.values.reduce((a, b) => a < b ? a : b);
        notifyListeners();
      case FileProgressEvent(:final received, :final total):
        status = PartySyncStatus.transferringFile;
        transferProgress = total == 0 ? 0 : received / total;
        notifyListeners();
      case FileReceivedEvent(:final path, :final title, :final artist):
        currentTitle = title.isEmpty ? currentTitle : title;
        currentArtist = artist;
        await _player.setAudioSource(AudioSource.uri(Uri.file(path)));
        status = PartySyncStatus.syncingClock;
        statusMessage = 'Sincronizando reloj con el anfitrión...';
        notifyListeners();
        if (_role == PartyRole.guest) {
          await _runClockSync();
        }
      case MessageEvent(:final payload, :final address):
        await _handleControlMessage(payload, address);
    }
  }

  Future<void> _sendPendingSong() async {
    if (_songSent) return;
    _songSent = true;
    final song = _pendingSong!;
    currentTitle = song.title;
    currentArtist = song.artist;
    status = PartySyncStatus.transferringFile;
    statusMessage = 'Enviando la canción a $connectedGuestCount invitado(s)...';
    notifyListeners();

    try {
      await _bridge.sendSongFile(
        path: song.filePath,
        title: song.title,
        artist: song.artist,
        durationMs: song.duration?.inMilliseconds,
      );
    } catch (e) {
      // Sin invitados conectados al momento de mandar (se desconectaron en
      // el tramo entre chequear y enviar): se pasa a estado de error en vez
      // de dejar la excepción sin capturar.
      debugPrint('sendSongFile falló: $e');
      if (_disposed) return;
      status = PartySyncStatus.error;
      statusMessage = 'Se desconectó antes de poder enviar la canción';
      notifyListeners();
      return;
    }
    if (_disposed) return;

    // El anfitrión ya tiene el archivo local, no necesita recibirlo de
    // vuelta: lo carga directo apenas termina de mandarlo.
    await _player.setAudioSource(AudioSource.uri(Uri.file(song.filePath)));
    status = PartySyncStatus.syncingClock;
    statusMessage = 'Sincronizando reloj con $connectedGuestCount invitado(s)...';
    notifyListeners();
    // A partir de acá se espera a que cada invitado corra su propia ronda
    // de "clock_ping" (llega como MessageEvent con su address) y mande
    // "ready_to_start".
  }

  /// Invitado tardío: se conectó después de que [_sendPendingSong] ya le
  /// mandó el archivo a los demás. Se le manda solo a él — reenviar con
  /// [_sendPendingSong] de nuevo interrumpiría a los que ya están
  /// sincronizando el reloj o reproduciendo.
  Future<void> _sendSongTo(String address) async {
    final song = _pendingSong;
    if (song == null) return;
    try {
      await _bridge.sendSongFileTo(
        address: address,
        path: song.filePath,
        title: song.title,
        artist: song.artist,
        durationMs: song.duration?.inMilliseconds,
      );
    } catch (e) {
      // Se desconectó entre que se conectó y que se le pudo mandar el
      // archivo — el DisconnectedEvent natural ya se encarga de sacarlo de
      // _guests, no hace falta nada más acá.
      debugPrint('sendSongFileTo($address) falló: $e');
    }
  }

  // ---- Sincronización de reloj (protocolo NTP simplificado) ----
  // La inicia cada INVITADO porque es quien necesita calcular el offset
  // respecto al reloj del anfitrión.

  Future<void> _runClockSync() async {
    _offsetSamples.clear();
    for (var i = 0; i < 5; i++) {
      if (_disposed) return;
      final t0 = DateTime.now().millisecondsSinceEpoch;
      await _broadcastControl({'type': 'clock_ping', 't0': t0});
      await Future.delayed(const Duration(milliseconds: 150));
    }
  }

  Future<void> _handleControlMessage(
      Map<String, dynamic> payload, String fromAddress) async {
    switch (payload['type']) {
      case 'clock_ping':
        // Le llega al anfitrión: respuesta dirigida solo a ESE invitado, no
        // difundida (cada uno tiene su propio t0).
        final t0 = payload['t0'] as int;
        final t1 = DateTime.now().millisecondsSinceEpoch;
        try {
          await _bridge.sendControlTo(fromAddress, {
            'type': 'clock_pong',
            't0': t0,
            't1': t1,
            't2': DateTime.now().millisecondsSinceEpoch,
          });
        } catch (e) {
          // Ese invitado se desconectó entre su ping y esta respuesta: el
          // pong ya no tiene a quién irle, no es un error de la sesión.
          debugPrint('clock_pong omitido para $fromAddress: $e');
        }
      case 'clock_pong':
        // Le llega al invitado (el anfitrión nunca manda clock_ping).
        final t0 = payload['t0'] as int;
        final t1 = payload['t1'] as int;
        final t2 = payload['t2'] as int;
        final t3 = DateTime.now().millisecondsSinceEpoch;
        final offset = ((t1 - t0) + (t2 - t3)) ~/ 2;
        _offsetSamples.add(offset);
        if (_offsetSamples.length >= 5) {
          _offsetSamples.sort();
          final median = _offsetSamples[_offsetSamples.length ~/ 2];
          _clockOffset = Duration(milliseconds: median);
          await _broadcastControl({'type': 'ready_to_start'});
          status = PartySyncStatus.waitingStart;
          statusMessage = 'Esperando que arranque la música...';
          notifyListeners();
        }
      case 'ready_to_start':
        // Le llega al anfitrión: marca a ESE invitado como listo y, si ya
        // están todos, arranca la cuenta regresiva para todos a la vez.
        final guest = _guests[fromAddress];
        if (guest != null) guest.ready = true;
        final readyCount = _guests.values.where((g) => g.ready).length;
        statusMessage = 'Invitados listos: $readyCount/$connectedGuestCount';
        notifyListeners();
        if (_guests.isNotEmpty && _guests.values.every((g) => g.ready)) {
          await _scheduleStart();
        }
      case 'play_at':
        await _onPlayAt(payload);
      case 'pause':
        _driftTimer?.cancel();
        _speedResetTimer?.cancel();
        await _player.pause();
        status = PartySyncStatus.paused;
        notifyListeners();
      case 'resume':
        await _onPlayAt(payload);
      case 'seek':
        final positionMs = payload['positionMs'] as int;
        await _player.seek(Duration(milliseconds: positionMs));
      case 'position_sync':
        await _applyDriftCorrection(payload);
      case 'stop_session':
        await stop();
    }
  }

  Future<void> _scheduleStart() async {
    final hostStartAt = DateTime.now().millisecondsSinceEpoch + 3000;
    await _broadcastControl({
      'type': 'play_at',
      'hostTimestamp': hostStartAt,
      'positionMs': 0,
    });
    await _waitAndPlay(hostStartAt, 0);
    _startDriftBroadcaster();
  }

  Future<void> _onPlayAt(Map<String, dynamic> payload) async {
    final hostTimestamp = payload['hostTimestamp'] as int;
    final positionMs = payload['positionMs'] as int? ?? 0;
    await _waitAndPlay(hostTimestamp, positionMs);
  }

  Future<void> _waitAndPlay(int hostTimestamp, int positionMs) async {
    final localTarget = _role == PartyRole.guest
        ? hostTimestamp - (_clockOffset?.inMilliseconds ?? 0)
        : hostTimestamp;
    final delay = localTarget - DateTime.now().millisecondsSinceEpoch;
    _speedResetTimer?.cancel();
    await _player.setSpeed(1.0);
    await _player.seek(Duration(milliseconds: positionMs));
    if (delay > 0) {
      await Future.delayed(Duration(milliseconds: delay));
    }
    if (_disposed) return;
    await _player.play();
    status = PartySyncStatus.playing;
    notifyListeners();
  }

  void _startDriftBroadcaster() {
    _driftTimer?.cancel();
    _driftTimer = Timer.periodic(_driftCheckInterval, (_) async {
      if (!_player.playing) return;
      await _broadcastControl({
        'type': 'position_sync',
        'hostTimestamp': DateTime.now().millisecondsSinceEpoch,
        'positionMs': _player.position.inMilliseconds,
      });
    });
  }

  /// Se llama en cada "position_sync" que llega del anfitrión (cada
  /// [_driftCheckInterval], mientras la sesión sigue viva, difundido a
  /// todos los invitados). Corrección en tres niveles según qué tan
  /// desviado esté este invitado en particular:
  ///  - `<= _ignoreDriftMs`: no hace nada (ya está alineado, evita
  ///    oscilar corrigiendo ruido de medición).
  ///  - entre eso y `_hardSeekDriftMs`: nudge de velocidad (±4%) durante el
  ///    próximo ciclo, se siente como el audio "respirando" un poco, no
  ///    como un salto.
  ///  - `> _hardSeekDriftMs`: salto directo, ya es tarde para corregir
  ///    suave sin quedar atrás varios ciclos.
  Future<void> _applyDriftCorrection(Map<String, dynamic> payload) async {
    final offset = _clockOffset;
    if (offset == null || !_player.playing) return;
    final hostTimestamp = payload['hostTimestamp'] as int;
    final hostPositionMs = payload['positionMs'] as int;
    final localNow = DateTime.now().millisecondsSinceEpoch;
    final hostNowEstimate = localNow + offset.inMilliseconds;
    final elapsedSinceHostSent = hostNowEstimate - hostTimestamp;
    final expectedPositionMs = hostPositionMs + elapsedSinceHostSent;
    final actualPositionMs = _player.position.inMilliseconds;
    // Positivo = este invitado está atrasado respecto al anfitrión.
    final drift = expectedPositionMs - actualPositionMs;

    if (drift.abs() <= _ignoreDriftMs) {
      await _resetSpeed();
      return;
    }

    if (drift.abs() > _hardSeekDriftMs) {
      _speedResetTimer?.cancel();
      await _player.setSpeed(1.0);
      await _player.seek(Duration(milliseconds: expectedPositionMs));
      return;
    }

    final nudgedSpeed =
        drift > 0 ? 1.0 + _nudgeSpeedDelta : 1.0 - _nudgeSpeedDelta;
    await _player.setSpeed(nudgedSpeed);
    _speedResetTimer?.cancel();
    _speedResetTimer = Timer(_driftCheckInterval, _resetSpeed);
  }

  Future<void> _resetSpeed() async {
    if (_player.speed != 1.0) {
      await _player.setSpeed(1.0);
    }
  }

  // ---- Controles: solo el anfitrión los dispara, se difunden a todos ----

  Future<void> togglePlayPause() async {
    if (_role != PartyRole.host) return;
    if (_player.playing) {
      _driftTimer?.cancel();
      _speedResetTimer?.cancel();
      await _player.pause();
      await _broadcastControl({'type': 'pause'});
      status = PartySyncStatus.paused;
    } else {
      final hostTimestamp = DateTime.now().millisecondsSinceEpoch + 500;
      final positionMs = _player.position.inMilliseconds;
      await _broadcastControl({
        'type': 'resume',
        'hostTimestamp': hostTimestamp,
        'positionMs': positionMs,
      });
      await _waitAndPlay(hostTimestamp, positionMs);
      _startDriftBroadcaster();
    }
    notifyListeners();
  }

  Future<void> stop() async {
    _driftTimer?.cancel();
    _speedResetTimer?.cancel();
    await _player.stop();
    if (_role == PartyRole.host) {
      await _broadcastControl({'type': 'stop_session'});
    }
    try {
      await _bridge.disconnect();
    } catch (e) {
      debugPrint('disconnect falló: $e');
    }
    status = PartySyncStatus.idle;
    statusMessage = null;
    _guests.clear();
    _sendProgressByGuest.clear();
    _songSent = false;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _driftTimer?.cancel();
    _speedResetTimer?.cancel();
    _eventsSub?.cancel();
    _player.dispose();
    super.dispose();
  }
}
