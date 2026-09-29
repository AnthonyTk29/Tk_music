import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tk_music/core/errors/app_error_code.dart';
import 'package:tk_music/core/errors/app_exception.dart';
import 'package:tk_music/domain/entities/song.dart';

import 'bluetooth_sync_bridge.dart';
import 'wifi_sync_transport.dart';
import 'artwork_bytes.dart';
import 'lyrics.dart';
import 'sync_transport.dart';
import 'track_features.dart';
import 'track_features_store.dart';
import 'basic_player.dart';
import 'sync_stream_server.dart';

enum PartyRole { host, guest }

enum PartySyncStatus {
  idle,

  /// Invitado: conectándose al anfitrión.
  connecting,

  /// Anfitrión: sesión abierta, esperando invitados antes de arrancar.
  waitingGuests,

  /// Invitado: conectado, esperando que el anfitrión arranque la música.
  waitingHost,

  /// Cargando la canción actual en todos antes de que suene a la vez.
  preparing,
  playing,
  paused,
  finished,

  /// Invitado: se cortó la conexión con el anfitrión (se puede reconectar).
  disconnected,
}

/// Orden automático de la lista compartida: se aplica a lo que viene
/// después de la canción actual y se mantiene solo cada vez que alguien
/// agrega canciones. [none] = en el orden en que se fueron agregando (o
/// como quedó después de "Mezclar").
enum QueueSortMode {
  none('Como se fueron agregando'),
  title('Título'),
  artist('Artista'),
  album('Álbum'),
  duration('Duración'),
  bpm('Ritmo (BPM)'),
  smart('Inteligente: ritmo y tonalidad');

  const QueueSortMode(this.label);
  final String label;
}

/// Una canción de la lista compartida. El anfitrión la arma desde su
/// biblioteca; cada invitado recibe la misma lista (sin los archivos) y los
/// archivos van llegando por detrás.
class SyncTrack {
  SyncTrack({
    required this.id,
    required this.title,
    this.artist,
    this.album,
    this.durationMs,
    this.localPath,
    this.songId,
    this.addedBy,
  });

  factory SyncTrack.fromSong(Song song, {String idPrefix = ''}) => SyncTrack(
        id: '$idPrefix${song.mediaStoreId}',
        title: song.title,
        artist: song.artist,
        album: song.album,
        durationMs: song.duration?.inMilliseconds,
        localPath: song.filePath,
        songId: song.mediaStoreId,
      );

  factory SyncTrack.fromJson(Map<String, dynamic> json) => SyncTrack(
        id: json['id'] as String,
        title: json['title'] as String? ?? '',
        artist: json['artist'] as String?,
        album: json['album'] as String?,
        durationMs: (json['durationMs'] as num?)?.toInt(),
        addedBy: json['addedBy'] as String?,
      )..featuresSummary = json['fx'] as String?;

  final String id;
  final String title;
  final String? artist;
  final String? album;
  final int? durationMs;

  /// Anfitrión: el archivo original. Invitado: el archivo ya recibido
  /// completo (null mientras sigue llegando).
  String? localPath;
  Uint8List? artwork;

  /// Id en la biblioteca de este dispositivo (para leer su carátula): las
  /// del anfitrión en el anfitrión, las que agregó un invitado en ese
  /// invitado.
  final int? songId;

  /// Nombre del invitado que la sumó a la lista (`null` = el anfitrión).
  String? addedBy;

  /// Anfitrión: orden de llegada a la lista, para "Orden en que se
  /// agregaron".
  int arrival = 0;

  /// "128 BPM · 8A" (lo calcula el anfitrión y lo ven todos).
  String? featuresSummary;

  /// Letra (formato LRC) para el modo karaoke.
  Lyrics? lyrics;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'album': album,
        'durationMs': durationMs,
        if (addedBy != null) 'addedBy': addedBy,
        if (featuresSummary != null) 'fx': featuresSummary,
      };
}

/// Reacción con emoji que aparece en la pantalla de todos.
class SyncReaction {
  const SyncReaction(this.emoji, this.from);
  final String emoji;
  final String from;
}

/// Emojis disponibles para reaccionar.
const syncReactionEmojis = ['❤️', '🔥', '😂', '👏', '🎉', '💃'];

/// Estado de un invitado desde el punto de vista del anfitrión.
class GuestInfo {
  GuestInfo({required this.address, required this.name});

  final String address;
  final String name;

  /// Canción que el invitado ya tiene cargada y lista para sonar.
  String? preparedTrackId;

  /// Canciones que ya tiene completas (enviadas o que ya tenía de antes de
  /// reconectarse).
  final Set<String> hasTracks = {};
  final Set<String> failedTracks = {};
  String? sendingTrackId;
  double sendingProgress = 0;
  bool _pumping = false;
}

/// Archivo que está llegando al invitado (streaming).
class _Incoming {
  _Incoming({required this.path, required this.total, required this.url})
      : tailFrom = total,
        tailEnd = total,
        startedAt = DateTime.now();

  final String path;
  final int total;
  final Uri url;
  final DateTime startedAt;
  int received = 0;
  int head = 0;
  int tailFrom;
  int tailEnd;
}

/// Motor de "Sincronizar con otro dispositivo": el anfitrión arma una lista
/// de canciones y controla play/pausa/siguiente/anterior/buscar; cada
/// invitado (hasta [maxGuests] a la vez) ve la misma lista y reproduce en
/// espejo. Funciona igual en Android y en desktop.
///
/// Archivos: el anfitrión se los manda a cada invitado en segundo plano, la
/// canción actual primero y después las que siguen. Viajan en trozos, así
/// que los controles nunca quedan trabados detrás de una transferencia, y el
/// invitado puede empezar a reproducir antes de tener el archivo completo
/// (streaming, vía [SyncStreamServer]) cuando la descarga va más rápido que
/// la reproducción.
///
/// Sincronización de reloj: ronda tipo NTP simplificada que corre CADA
/// invitado (5 ping/pong contra el anfitrión) para estimar su offset; con
/// eso el anfitrión manda "sonar desde la posición P a la hora T" en su
/// propio reloj y cada invitado lo convierte a su hora local.
///
/// Mientras suena, el anfitrión manda su posición cada 1 s como referencia
/// y cada invitado se corrige solo cada 300 ms: apurando o frenando un poco
/// en proporción al desfase (hasta ±6 %), o con un salto si se fue lejos. El
/// reloj se mide con varias idas y vueltas quedándose con las más rápidas,
/// y cada dispositivo puede compensar el retraso de su parlante
/// ([latencyMs]).
class PartySyncEngine extends ChangeNotifier {
  /// [transport]: Bluetooth (por defecto) o Wi-Fi. [localName]: cómo se
  /// muestran las reacciones de este dispositivo.
  PartySyncEngine({SyncTransport? transport, this.localName = 'Anfitrión'})
      : _bridge = transport ?? BluetoothSyncService() {
    unawaited(_loadLatency());
  }

  final SyncTransport _bridge;
  final String localName;
  final _reactions = StreamController<SyncReaction>.broadcast();
  final Map<String, DateTime> _lastReactionAt = {};

  /// Reacciones de todos (incluidas las propias), para mostrarlas.
  Stream<SyncReaction> get reactions => _reactions.stream;

  /// Modo karaoke: la letra de lo que suena, grande, en todos.
  bool karaoke = false;

  String get transportLabel => _bridge.label;
  int get guestLimit => _bridge.maxGuests;
  bool get isWifi => _bridge.label == 'Wi-Fi';

  Future<void> _loadLatency() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      latencyMs =
          (prefs.getInt(_latencyKey) ?? 0).clamp(-maxLatencyMs, maxLatencyMs);
      if (!_disposed) notifyListeners();
    } catch (_) {}
  }

  /// Cambia el ajuste fino de este dispositivo (se aplica en el momento: el
  /// invitado se reacomoda solo; el anfitrión mueve la referencia de todos).
  Future<void> setLatency(int ms) async {
    latencyMs = ms.clamp(-maxLatencyMs, maxLatencyMs);
    _driftSamples.clear();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_latencyKey, latencyMs);
    } catch (_) {}
  }

  /// Lo que se está escuchando ahora en este dispositivo (la posición del
  /// reproductor menos el retraso de su parlante).
  int get _audiblePositionMs => _player.position.inMilliseconds - latencyMs;

  static int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  /// Anfitrión: ya está escuchando (el QR se arma recién ahí, con el
  /// puerto o el canal reales).
  bool hostingReady = false;

  /// Anfitrión por Wi-Fi: el puerto en el que escucha (va en el QR).
  int? get wifiPort {
    final bridge = _bridge;
    return bridge is WifiSyncService ? bridge.hostingPort : null;
  }

  /// Mientras se analiza el ritmo de la lista para el orden inteligente.
  int analyzingCount = 0;
  final _player = BasicPlayer();
  final _streamServer = SyncStreamServer();
  StreamSubscription<BluetoothSyncEvent>? _eventsSub;
  StreamSubscription<void>? _completedSub;
  Timer? _driftTimer;

  /// Invitado: corrección continua de la posición (cada
  /// [_correctionInterval]).
  Timer? _correctionTimer;

  /// Invitado: vuelve a medir el reloj cada tanto (los relojes de dos
  /// equipos se separan de a poco).
  Timer? _clockRefreshTimer;

  /// Mediciones de reloj de la ronda en curso: (diferencia, ida y vuelta).
  final List<(int offset, int rtt)> _clockSamples = [];
  bool _clockRoundOpen = false;

  static const maxGuests = 6;
  static const _driftCheckInterval = Duration(seconds: 1);
  static const _correctionInterval = Duration(milliseconds: 300);
  static const _clockRefreshInterval = Duration(seconds: 30);
  static const _clockPings = 10;

  /// Por debajo de esto no se corrige (ruido de la medición).
  static const _deadbandMs = 12;

  /// Más desfasado que esto: salto directo en vez de apurar/frenar.
  static const _hardSeekDriftMs = 400;

  /// Cuánto puede apurar o frenar como máximo (±6 %: no se nota en el tono,
  /// que se mantiene).
  static const _maxSpeedDelta = 0.06;
  static const _startLeadMs = 1200;
  static const _catchUpLeadMs = 800;
  static const _tailSize = 256 * 1024;

  PartyRole? _role;
  bool _disposed = false;

  /// Se incrementa con cada orden de reproducción (preparar/pausar/sonar):
  /// un "sonar a la hora T" que quedó esperando se descarta si mientras
  /// tanto llegó otra orden.
  int _commandGeneration = 0;

  PartySyncStatus status = PartySyncStatus.idle;
  String? statusMessage;
  final List<SyncTrack> queue = [];
  int currentIndex = 0;
  String? _loadedTrackId;

  // Anfitrión.
  final Map<String, GuestInfo> _guests = {};
  int _expectedGuestCount = 1;
  bool _started = false;

  /// Ajuste fino de este dispositivo, en ms: cuánto tarda su parlante en
  /// hacer sonar lo que el reproductor ya "tocó" (un parlante Bluetooth
  /// suma 150–300 ms). Positivo = este dispositivo suena atrasado. Se
  /// guarda para la próxima vez.
  int latencyMs = 0;
  static const _latencyKey = 'sync.latencyMs';
  static const maxLatencyMs = 600;

  /// Invitado: desfase medido con el anfitrión (ms; + = atrasado), para
  /// mostrarlo.
  int? driftMs;

  /// Invitado: ida y vuelta de la mejor medición del reloj (ms): cuanto
  /// menor, más confiable la sincronía.
  int? clockRttMs;

  // Invitado.
  PairedBluetoothDevice? _hostDevice;
  Duration? _clockOffset;

  // Invitado: dónde estaba el anfitrión (lo que se ESCUCHA, ya descontado
  // su ajuste fino) a qué hora de su reloj. Se actualiza con cada
  // "play_at" y "position_sync"; entre uno y otro, el invitado calcula solo
  // dónde tendría que estar.
  int? _anchorHostTs;
  int? _anchorPositionMs;
  final List<int> _driftSamples = [];
  bool _clockSyncRunning = false;
  bool _resyncAfterClock = false;
  String? _pendingPrepareTrackId;
  bool _prepareInFlight = false;
  final Map<String, _Incoming> _incoming = {};
  final Set<String> _receivedFiles = {};

  // Orden de la lista (lo decide el anfitrión; el invitado lo ve).
  QueueSortMode sortMode = QueueSortMode.none;
  int _arrivalCounter = 0;

  // Anfitrión: canción que se quiso reproducir pero todavía se está
  // subiendo desde el invitado que la agregó.
  String? _waitingUploadTrackId;

  // Invitado: canciones que agregó él (su archivo original) y su subida al
  // anfitrión.
  String? _hostAddress;
  final String _uploadPrefix =
      'g${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-';
  final Map<String, SyncTrack> _ownTracks = {};
  final Set<String> _uploadedIds = {};
  final Map<String, double> _uploadProgress = {};
  bool _uploading = false;

  bool get isHost => _role == PartyRole.host;
  bool get isGuest => _role == PartyRole.guest;
  bool get started => _started;
  String? get hostName => _hostDevice?.name;
  List<GuestInfo> get guests => _guests.values.toList(growable: false);
  int get connectedGuestCount => _guests.length;
  int get expectedGuestCount => _expectedGuestCount;

  SyncTrack? get currentTrack =>
      currentIndex >= 0 && currentIndex < queue.length
          ? queue[currentIndex]
          : null;

  Duration get position =>
      _loadedTrackId == null ? Duration.zero : _player.position;

  Duration? get duration {
    final track = currentTrack;
    final fromTrack = track?.durationMs;
    return _player.duration ??
        (fromTrack != null && fromTrack > 0
            ? Duration(milliseconds: fromTrack)
            : null);
  }

  /// Invitado: la canción actual suena mientras todavía está llegando.
  bool get isStreamingCurrent {
    final track = currentTrack;
    return isGuest &&
        track != null &&
        _loadedTrackId == track.id &&
        track.localPath == null;
  }

  /// Cuánto de [track] ya está del otro lado (0..1). Anfitrión: el
  /// invitado más atrasado. Invitado: lo que ya llegó.
  double trackProgress(SyncTrack track) {
    if (isHost) {
      if (_guests.isEmpty) return 1;
      return _guests.values
          .map((g) => guestProgress(g, track))
          .reduce(math.min);
    }
    if (track.localPath != null) return 1;
    final incoming = _incoming[track.id];
    if (incoming == null || incoming.total == 0) return 0;
    return incoming.received / incoming.total;
  }

  /// Canción agregada por un invitado que todavía no terminó de llegar al
  /// anfitrión: cuánto va (0..1). `null` si no está subiéndose.
  double? uploadProgress(SyncTrack track) {
    if (isHost) {
      if (track.localPath != null) return null;
      final incoming = _incoming[track.id];
      if (incoming == null || incoming.total == 0) return 0;
      return incoming.received / incoming.total;
    }
    if (!_ownTracks.containsKey(track.id) || _uploadedIds.contains(track.id)) {
      return null;
    }
    return _uploadProgress[track.id] ?? 0;
  }

  /// Anfitrión: nombre de quien está subiendo la canción que se quiso
  /// reproducir (la lista espera a que termine).
  SyncTrack? get waitingUploadTrack {
    final id = _waitingUploadTrackId;
    return id == null ? null : _trackById(id);
  }

  double guestProgress(GuestInfo guest, SyncTrack track) {
    if (guest.hasTracks.contains(track.id)) return 1;
    if (guest.sendingTrackId == track.id) return guest.sendingProgress;
    return 0;
  }

  /// Invitados que todavía no tienen lista la canción actual.
  List<GuestInfo> get guestsNotReady {
    final track = currentTrack;
    if (track == null) return const [];
    return _guests.values.where((g) => g.preparedTrackId != track.id).toList();
  }

  // ---------------------------------------------------------------------
  // Arranque de sesión
  // ---------------------------------------------------------------------

  Future<void> startAsHost(
      List<PairedBluetoothDevice> expectedGuests, List<Song> songs) async {
    _role = PartyRole.host;
    queue
      ..clear()
      ..addAll(songs.map(SyncTrack.fromSong));
    for (final track in queue) {
      track.arrival = _arrivalCounter++;
    }
    sortMode = QueueSortMode.none;
    currentIndex = 0;
    _started = false;
    // 0 = sin lista de invitados esperados (Wi-Fi): arranca a mano.
    _expectedGuestCount = expectedGuests.length.clamp(0, _bridge.maxGuests);
    _guests.clear();
    status = PartySyncStatus.waitingGuests;
    statusMessage = _expectedGuestCount == 0
        ? 'Esperando invitados...'
        : 'Esperando invitados (0/$_expectedGuestCount)...';
    notifyListeners();

    _listen();
    _completedSub ??= _player.completed.listen((_) => _onTrackCompleted());
    try {
      await _bridge.startHosting();
    } catch (e) {
      // Todavía no hay sesión que mostrar: se vuelve al paso de
      // configuración antes de que la excepción suba a la alerta global.
      status = PartySyncStatus.idle;
      notifyListeners();
      throw AppException(
        isWifi ? AppErrorCode.wifiHostFailed : AppErrorCode.btHostFailed,
        userMessage: isWifi
            ? wifiHostFailedMessage(e)
            : 'No se pudo iniciar la sesión como anfitrión. Revisá '
                'que el Bluetooth esté activado y que le hayas dado el '
                'permiso a la app.',
        technicalMessage: 'startHosting ($transportLabel): $e',
      );
    }
    // Ya se sabe el puerto (Wi-Fi) o el canal (Bluetooth) para el QR.
    hostingReady = true;
    notifyListeners();
    unawaited(_loadArtworks(queue));
  }

  Future<void> joinAsGuest(PairedBluetoothDevice hostDevice) async {
    _role = PartyRole.guest;
    _hostDevice = hostDevice;
    queue.clear();
    currentIndex = 0;
    _clockOffset = null;
    await _connectToHost(reconnecting: false);
  }

  Future<void> _connectToHost({required bool reconnecting}) async {
    final host = _hostDevice!;
    status = PartySyncStatus.connecting;
    statusMessage = reconnecting
        ? 'Reconectando con "${host.name}"...'
        : 'Conectando con "${host.name}"...';
    notifyListeners();

    _listen();
    try {
      await _bridge.connectToDevice(host.address);
    } catch (e) {
      if (reconnecting) {
        status = PartySyncStatus.disconnected;
        statusMessage = 'No se pudo reconectar con "${host.name}". Revisá que '
            'siga en la sesión y probá de nuevo.';
        notifyListeners();
        return;
      }
      status = PartySyncStatus.idle;
      notifyListeners();
      throw AppException(
        isWifi ? AppErrorCode.wifiConnectFailed : AppErrorCode.btConnectFailed,
        userMessage: isWifi
            ? wifiConnectFailedMessage(host.name, e)
            : bluetoothConnectFailedMessage(host.name, e),
        technicalMessage: 'connectToDevice ($transportLabel): $e',
      );
    }
  }

  void _listen() {
    _eventsSub ??= _bridge.events.listen(_onEvent);
  }

  // ---------------------------------------------------------------------
  // Eventos del puente Bluetooth
  // ---------------------------------------------------------------------

  Future<void> _onEvent(BluetoothSyncEvent event) async {
    if (_disposed) return;
    switch (event) {
      case ConnectedEvent(:final deviceName, :final address):
        if (isHost) {
          _guests[address] = GuestInfo(address: address, name: deviceName);
          if (!_started) {
            statusMessage = _expectedGuestCount == 0
                ? 'Invitados conectados: $connectedGuestCount'
                : 'Invitados conectados: $connectedGuestCount/$_expectedGuestCount';
          }
          notifyListeners();
          // El resto (lista, archivos, arranque) sigue cuando el invitado
          // mande su "hello" con las canciones que ya tiene.
        } else {
          _hostAddress = address;
          status = PartySyncStatus.waitingHost;
          statusMessage = 'Conectado con $deviceName. Sincronizando reloj...';
          notifyListeners();
          await _sendToHost({
            'type': 'hello',
            'have': [
              for (final track in queue)
                if (track.localPath != null) track.id,
            ],
          });
          unawaited(_runClockSync());
          // Canciones que este invitado agregó y no terminaron de subir
          // (p. ej. se cortó la conexión a mitad): se retoman.
          unawaited(_pumpUploads());
        }

      case DisconnectedEvent(:final reason, :final address):
        if (isHost) {
          final guest = _guests.remove(address);
          if (guest != null) {
            statusMessage = '${guest.name} se desconectó'
                '${reason.isNotEmpty ? " ($reason)" : ""}';
          }
          notifyListeners();
          _checkAllPrepared();
        } else {
          _driftTimer?.cancel();
          _correctionTimer?.cancel();
          status = PartySyncStatus.disconnected;
          statusMessage = 'Se perdió la conexión con el anfitrión'
              '${reason.isNotEmpty ? " ($reason)" : ""}. Tocá "Reconectar".';
          notifyListeners();
        }

      case ErrorEvent(:final message):
        statusMessage = message;
        notifyListeners();

      case DeviceConnectionChangedEvent():
        // Solo la pantalla de configuración lo usa.
        break;

      case SendProgressEvent(
          :final transferId,
          :final sent,
          :final total,
          :final address
        ):
        if (isGuest) {
          _uploadProgress[transferId] = total == 0 ? 1 : sent / total;
          notifyListeners();
          return;
        }
        final guest = _guests[address];
        if (guest != null && guest.sendingTrackId == transferId) {
          guest.sendingProgress = total == 0 ? 1 : sent / total;
          notifyListeners();
        }

      case FileStartedEvent(:final transferId, :final path, :final total):
        final url =
            await _streamServer.register(transferId, path: path, total: total);
        _incoming[transferId] = _Incoming(path: path, total: total, url: url);
        _receivedFiles.add(path);
        notifyListeners();

      case FileProgressEvent(
          :final transferId,
          :final received,
          :final head,
          :final tailFrom,
          :final tailEnd,
        ):
        final incoming = _incoming[transferId];
        if (incoming == null) return;
        incoming
          ..received = received
          ..head = head
          ..tailFrom = tailFrom
          ..tailEnd = tailEnd;
        _streamServer.update(transferId,
            head: head, tailFrom: tailFrom, tailEnd: tailEnd);
        if (_pendingPrepareTrackId == transferId) await _tryPrepare();
        notifyListeners();

      case FileReceivedEvent(:final transferId, :final path):
        _streamServer.complete(transferId);
        _incoming.remove(transferId);
        _receivedFiles.add(path);
        final track = _trackById(transferId);
        track?.localPath = path;
        if (_pendingPrepareTrackId == transferId) await _tryPrepare();
        if (isHost && track != null) {
          // Ya la tiene el anfitrión: se reparte al resto de los invitados.
          for (final guest in _guests.values) {
            unawaited(_pumpTransfers(guest));
          }
          if (_waitingUploadTrackId == transferId) {
            _waitingUploadTrackId = null;
            final index = queue.indexOf(track);
            if (index >= 0) await playIndex(index);
          }
        }
        notifyListeners();

      case FileAbortedEvent(:final transferId):
        _incoming.remove(transferId);
        _streamServer.abort(transferId);
        notifyListeners();

      case MessageEvent(:final payload, :final address):
        await _handleControlMessage(payload, address);
    }
  }

  Future<void> _handleControlMessage(
      Map<String, dynamic> payload, String from) async {
    switch (payload['type']) {
      // ---- Le llegan al anfitrión ----
      case 'add_tracks':
        await _onGuestAddedTracks(from, payload);
      case 'hello':
        final guest = _guests[from];
        if (guest == null) return;
        guest.hasTracks
            .addAll((payload['have'] as List? ?? const []).cast<String>());
        await _welcomeGuest(guest);
      case 'clock_ping':
        // Respuesta dirigida solo a ESE invitado (cada uno tiene su t0).
        final t1 = DateTime.now().millisecondsSinceEpoch;
        await _sendTo(from, {
          'type': 'clock_pong',
          't0': payload['t0'] as int,
          't1': t1,
          't2': DateTime.now().millisecondsSinceEpoch,
        });
      case 'prepared':
        final guest = _guests[from];
        if (guest == null) return;
        guest.preparedTrackId = payload['trackId'] as String;
        notifyListeners();
        if (guest.preparedTrackId != currentTrack?.id) return;
        if (status == PartySyncStatus.preparing) {
          _checkAllPrepared();
        } else {
          // Llegó tarde (invitado nuevo, reconexión o descarga lenta): se
          // suma a lo que ya está sonando.
          await _catchUp(from);
        }
      case 'resync_request':
        final guest = _guests[from];
        final track = currentTrack;
        if (guest == null || track == null || !_started) return;
        if (guest.preparedTrackId == track.id) {
          await _catchUp(from);
        } else {
          await _sendTo(from, {'type': 'prepare', 'trackId': track.id});
          unawaited(_pumpTransfers(guest));
        }

      // ---- Le llegan al invitado ----
      case 'clock_pong':
        _onClockPong(payload);
      case 'queue':
        _applyQueue(payload);
      case 'artwork':
        final track = _trackById(payload['trackId'] as String);
        final data = payload['data'] as String?;
        if (track != null && data != null) {
          track.artwork = base64Decode(data);
          notifyListeners();
          // Carátula de una canción que agregó un invitado: el anfitrión se
          // la reenvía al resto.
          if (isHost) await _broadcastControl(payload);
        }
      case 'prepare':
        await _onPrepare(payload['trackId'] as String);
      case 'play_at':
        await _onPlayAt(payload);
      case 'pause':
        _commandGeneration++;
        _correctionTimer?.cancel();
        await _player.pause();
        if (_loadedTrackId == payload['trackId']) {
          await _player
              .seek(Duration(milliseconds: payload['positionMs'] as int? ?? 0));
        }
        status = PartySyncStatus.paused;
        statusMessage = null;
        notifyListeners();
      case 'position_sync':
        _onHostPosition(payload);
      case 'finished':
        _commandGeneration++;
        await _player.pause();
        status = PartySyncStatus.finished;
        statusMessage = null;
        notifyListeners();
      case 'reaction':
        final emoji = payload['emoji'] as String?;
        if (emoji == null || !syncReactionEmojis.contains(emoji)) return;
        if (isHost) {
          // De un invitado: se reenvía a todos con su nombre.
          final name = _guests[from]?.name ?? 'Invitado';
          if (!_allowReaction(from)) return;
          await _broadcastControl(
              {'type': 'reaction', 'emoji': emoji, 'from': name});
          _reactions.add(SyncReaction(emoji, name));
        } else {
          _reactions.add(SyncReaction(emoji, payload['from'] as String? ?? ''));
        }
      case 'karaoke':
        karaoke = payload['on'] == true;
        notifyListeners();
      case 'lyrics':
        final track = _trackById(payload['trackId'] as String? ?? '');
        final text = payload['text'] as String?;
        if (track != null && text != null) {
          track.lyrics = parseLyrics(text,
              source: payload['source'] as String? ?? 'anfitrión');
          notifyListeners();
        }
      case 'resync':
        await resync();
      case 'stop_session':
        await stop();
        statusMessage = 'El anfitrión terminó la sesión';
        if (!_disposed) notifyListeners();
    }
  }

  // ---------------------------------------------------------------------
  // Anfitrión
  // ---------------------------------------------------------------------

  Future<void> _welcomeGuest(GuestInfo guest) async {
    await _sendTo(guest.address, _queueMessage());
    for (final track in queue) {
      final art = track.artwork;
      if (art != null) {
        await _sendTo(guest.address, {
          'type': 'artwork',
          'trackId': track.id,
          'data': base64Encode(art),
        });
      }
    }
    final track = currentTrack;
    if (karaoke) await _sendTo(guest.address, {'type': 'karaoke', 'on': true});
    if (_started && track != null) {
      final lyrics = track.lyrics;
      if (lyrics != null) {
        await _sendTo(guest.address, _lyricsMessage(track.id, lyrics));
      }
      await _sendTo(guest.address, {'type': 'prepare', 'trackId': track.id});
    }
    unawaited(_pumpTransfers(guest));
    if (!_started &&
        _expectedGuestCount > 0 &&
        connectedGuestCount >= _expectedGuestCount) {
      await playIndex(currentIndex);
    }
  }

  Map<String, dynamic> _queueMessage() => {
        'type': 'queue',
        'tracks': [for (final track in queue) track.toJson()],
        'currentIndex': currentIndex,
        'started': _started,
        'sortMode': sortMode.name,
      };

  /// Arranca aunque no se hayan conectado todos los invitados esperados.
  Future<void> startWithConnectedGuestsNow() async {
    // También sin invitados: los que lleguen después se suman a lo que ya
    // está sonando.
    if (!isHost || _started) return;
    await playIndex(currentIndex);
  }

  /// Anfitrión: pasa a la canción [index] en todos. Suena cuando todos la
  /// tienen lista (o antes, con [startWithoutWaiting]).
  Future<void> playIndex(int index) async {
    if (!isHost || index < 0 || index >= queue.length) return;
    _commandGeneration++;
    _driftTimer?.cancel();
    _correctionTimer?.cancel();
    await _player.pause();
    currentIndex = index;
    _started = true;
    final track = queue[index];
    status = PartySyncStatus.preparing;
    statusMessage = null;
    for (final guest in _guests.values) {
      guest.preparedTrackId = null;
    }
    notifyListeners();

    final path = track.localPath;
    if (path == null) {
      // La agregó un invitado y todavía no terminó de llegar: arranca sola
      // apenas llegue (ver FileReceivedEvent).
      _waitingUploadTrackId = track.id;
      return;
    }
    _waitingUploadTrackId = null;
    try {
      await _player.setFilePath(path);
      _loadedTrackId = track.id;
    } catch (e) {
      debugPrint('No se pudo abrir ${track.localPath}: $e');
      statusMessage = 'No se pudo abrir "${track.title}"';
      notifyListeners();
      return;
    }

    await _broadcastControl(_queueMessage());
    await _broadcastControl({'type': 'prepare', 'trackId': track.id});
    unawaited(_shareLyrics(track));
    for (final guest in _guests.values) {
      // Si a un invitado le está llegando otra canción que todavía va por
      // la mitad, se corta: la actual tiene que llegar primero.
      if (guest.sendingTrackId != null &&
          guest.sendingTrackId != track.id &&
          !guest.hasTracks.contains(track.id) &&
          guest.sendingProgress < 0.7) {
        unawaited(_bridge.cancelTransfer(guest.address).catchError((_) {}));
      }
      unawaited(_pumpTransfers(guest));
    }
    _checkAllPrepared();
  }

  void _checkAllPrepared() {
    if (!isHost || status != PartySyncStatus.preparing) return;
    final track = currentTrack;
    if (track == null || _loadedTrackId != track.id) return;
    if (_guests.values.every((g) => g.preparedTrackId == track.id)) {
      unawaited(_startPlaybackAt(0));
    }
  }

  /// Anfitrión: arranca la canción actual sin esperar a los invitados que
  /// todavía no la tienen lista; se suman solos cuando la tengan.
  Future<void> startWithoutWaiting() async {
    if (!isHost || status != PartySyncStatus.preparing) return;
    await _startPlaybackAt(0);
  }

  Future<void> _startPlaybackAt(int positionMs,
      {int leadMs = _startLeadMs}) async {
    final track = currentTrack;
    if (track == null || _loadedTrackId != track.id) return;
    final hostTimestamp = DateTime.now().millisecondsSinceEpoch + leadMs;
    await _broadcastControl({
      'type': 'play_at',
      'trackId': track.id,
      'hostTimestamp': hostTimestamp,
      'positionMs': positionMs,
    });
    await _waitAndPlay(hostTimestamp, positionMs, ++_commandGeneration);
    _startDriftBroadcaster();
  }

  /// Pone a un invitado puntual en la misma canción/posición/estado que el
  /// anfitrión (invitado que llegó tarde o pidió resincronizar).
  Future<void> _catchUp(String address) async {
    final track = currentTrack;
    if (track == null) return;
    if (status == PartySyncStatus.playing) {
      final hostTimestamp =
          DateTime.now().millisecondsSinceEpoch + _catchUpLeadMs;
      await _sendTo(address, {
        'type': 'play_at',
        'trackId': track.id,
        'hostTimestamp': hostTimestamp,
        'positionMs': _audiblePositionMs + _catchUpLeadMs,
      });
    } else if (status == PartySyncStatus.paused ||
        status == PartySyncStatus.finished) {
      await _sendTo(address, {
        'type': 'pause',
        'trackId': track.id,
        'positionMs': _player.position.inMilliseconds,
      });
    }
  }

  Future<void> togglePlayPause() async {
    if (!isHost) return;
    switch (status) {
      case PartySyncStatus.waitingGuests:
        await startWithConnectedGuestsNow();
      case PartySyncStatus.preparing:
        await startWithoutWaiting();
      case PartySyncStatus.playing:
        _commandGeneration++;
        _driftTimer?.cancel();
        _correctionTimer?.cancel();
        await _player.pause();
        status = PartySyncStatus.paused;
        notifyListeners();
        await _broadcastControl({
          'type': 'pause',
          'trackId': currentTrack?.id,
          'positionMs': _player.position.inMilliseconds,
        });
      case PartySyncStatus.paused:
        await _startPlaybackAt(_audiblePositionMs, leadMs: 600);
      case PartySyncStatus.finished:
        await playIndex(0);
      default:
        break;
    }
  }

  Future<void> seek(Duration target) async {
    if (!isHost || _loadedTrackId == null) return;
    if (status == PartySyncStatus.playing) {
      _driftTimer?.cancel();
      await _startPlaybackAt(target.inMilliseconds, leadMs: 600);
    } else {
      await _player.seek(target);
      await _broadcastControl({
        'type': 'pause',
        'trackId': currentTrack?.id,
        'positionMs': target.inMilliseconds,
      });
      notifyListeners();
    }
  }

  Future<void> next() async {
    if (currentIndex < queue.length - 1) await playIndex(currentIndex + 1);
  }

  Future<void> previous() async {
    if (_player.position > const Duration(seconds: 3) || currentIndex == 0) {
      await seek(Duration.zero);
    } else {
      await playIndex(currentIndex - 1);
    }
  }

  Future<void> _onTrackCompleted() async {
    if (!isHost || status != PartySyncStatus.playing) return;
    if (currentIndex < queue.length - 1) {
      await playIndex(currentIndex + 1);
      return;
    }
    _driftTimer?.cancel();
    status = PartySyncStatus.finished;
    notifyListeners();
    await _broadcastControl({'type': 'finished'});
  }

  /// Suma canciones a la lista compartida. Las del anfitrión entran
  /// directo; las de un invitado se le avisan al anfitrión y el archivo se
  /// sube en segundo plano (el anfitrión después se lo reparte al resto).
  Future<void> addSongs(List<Song> songs) async {
    if (isGuest) {
      await _addSongsAsGuest(songs);
      return;
    }
    if (!isHost) return;
    final existing = queue.map((t) => t.id).toSet();
    final added = [
      for (final song in songs)
        if (!existing.contains('${song.mediaStoreId}'))
          SyncTrack.fromSong(song)..arrival = _arrivalCounter++,
    ];
    if (added.isEmpty) return;
    queue.addAll(added);
    _applySort();
    notifyListeners();
    await _broadcastControl(_queueMessage());
    for (final guest in _guests.values) {
      unawaited(_pumpTransfers(guest));
    }
    unawaited(_loadArtworks(added));
  }

  /// Anfitrión: un invitado agregó canciones de su biblioteca. Entran a la
  /// lista ya (sin archivo todavía); el archivo llega por detrás.
  Future<void> _onGuestAddedTracks(
      String from, Map<String, dynamic> payload) async {
    final guest = _guests[from];
    if (guest == null) return;
    final existing = queue.map((t) => t.id).toSet();
    final tracks = (payload['tracks'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(SyncTrack.fromJson)
        .where((t) => !existing.contains(t.id))
        .toList();
    if (tracks.isEmpty) return;
    for (final track in tracks) {
      track
        ..addedBy = guest.name
        ..arrival = _arrivalCounter++;
      // El que la agregó ya tiene el archivo: no hace falta mandárselo.
      guest.hasTracks.add(track.id);
    }
    queue.addAll(tracks);
    _applySort();
    statusMessage = '${guest.name} agregó ${tracks.length} '
        '${tracks.length == 1 ? 'canción' : 'canciones'}';
    notifyListeners();
    await _broadcastControl(_queueMessage());
  }

  Future<void> _addSongsAsGuest(List<Song> songs) async {
    if (_hostAddress == null || status == PartySyncStatus.disconnected) {
      statusMessage = 'Conectate al anfitrión para agregar canciones';
      notifyListeners();
      return;
    }
    final tracks = [
      for (final song in songs)
        if (!_ownTracks.containsKey('$_uploadPrefix${song.mediaStoreId}'))
          SyncTrack.fromSong(song, idPrefix: _uploadPrefix),
    ];
    if (tracks.isEmpty) return;
    for (final track in tracks) {
      _ownTracks[track.id] = track;
    }
    await _sendToHost({
      'type': 'add_tracks',
      'tracks': [for (final track in tracks) track.toJson()],
    });
    statusMessage = tracks.length == 1
        ? 'Mandando "${tracks.first.title}" al anfitrión...'
        : 'Mandando ${tracks.length} canciones al anfitrión...';
    notifyListeners();
    unawaited(_loadArtworks(tracks));
    unawaited(_pumpUploads());
  }

  /// Invitado: sube de a una las canciones que agregó y el anfitrión
  /// todavía no tiene.
  Future<void> _pumpUploads() async {
    if (_uploading) return;
    _uploading = true;
    try {
      while (!_disposed && isGuest && _hostAddress != null) {
        SyncTrack? next;
        for (final track in _ownTracks.values) {
          if (!_uploadedIds.contains(track.id)) {
            next = track;
            break;
          }
        }
        if (next == null) break;
        _uploadProgress[next.id] = 0;
        notifyListeners();
        try {
          await _bridge.sendSongFileTo(
            address: _hostAddress!,
            path: next.localPath!,
            title: next.title,
            artist: next.artist,
            durationMs: next.durationMs,
            transferId: next.id,
            extra: {'trackId': next.id},
          );
          _uploadedIds.add(next.id);
          _uploadProgress.remove(next.id);
        } on PlatformException catch (e) {
          // Se cortó la conexión: se retoma al reconectar.
          debugPrint('Subida de "${next.title}" falló: $e');
          break;
        } finally {
          notifyListeners();
        }
      }
    } finally {
      _uploading = false;
    }
  }

  /// Manda una reacción a todos (y la muestra acá).
  Future<void> sendReaction(String emoji) async {
    if (!syncReactionEmojis.contains(emoji) || !_allowReaction('me')) return;
    if (isHost) {
      _reactions.add(SyncReaction(emoji, localName));
      await _broadcastControl(
          {'type': 'reaction', 'emoji': emoji, 'from': localName});
    } else if (isGuest) {
      // Vuelve rebotada del anfitrión con el nombre de este dispositivo.
      await _sendToHost({'type': 'reaction', 'emoji': emoji});
    }
  }

  /// Como mucho 4 reacciones por segundo por dispositivo, para que nadie
  /// llene la pantalla de todos.
  bool _allowReaction(String key) {
    final now = DateTime.now();
    final last = _lastReactionAt[key];
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 250)) {
      return false;
    }
    _lastReactionAt[key] = now;
    return true;
  }

  /// Anfitrión: prende/apaga el karaoke en todos. Invitado: solo en su
  /// pantalla.
  Future<void> setKaraoke(bool on) async {
    karaoke = on;
    notifyListeners();
    if (isHost) {
      await _broadcastControl({'type': 'karaoke', 'on': on});
      final track = currentTrack;
      if (on && track != null) unawaited(_shareLyrics(track));
    } else if (on) {
      final track = currentTrack;
      if (track != null && track.lyrics == null) {
        unawaited(_findLyricsLocally(track));
      }
    }
  }

  Map<String, dynamic> _lyricsMessage(String trackId, Lyrics lyrics) => {
        'type': 'lyrics',
        'trackId': trackId,
        'text': lyrics.raw,
        'source': lyrics.source,
      };

  /// Anfitrión: busca la letra de [track] y se la manda a todos.
  Future<void> _shareLyrics(SyncTrack track) async {
    final path = track.localPath;
    if (path == null) return;
    final lyrics = track.lyrics ??
        await LyricsStore.instance.lyricsFor(
          path: path,
          title: track.title,
          artist: track.artist,
          album: track.album,
          durationMs: track.durationMs,
        );
    if (lyrics == null || _disposed) return;
    track.lyrics = lyrics;
    notifyListeners();
    await _broadcastControl(_lyricsMessage(track.id, lyrics));
  }

  /// Invitado con el karaoke prendido y sin letra del anfitrión: la busca
  /// por su cuenta (internet).
  Future<void> _findLyricsLocally(SyncTrack track) async {
    final lyrics = await LyricsStore.instance.lyricsFor(
      path: 'sync:${track.id}',
      title: track.title,
      artist: track.artist,
      album: track.album,
      durationMs: track.durationMs,
    );
    if (lyrics == null || _disposed) return;
    track.lyrics = lyrics;
    notifyListeners();
  }

  /// Anfitrión: reordena al azar lo que viene después de la canción actual
  /// (y deja de ordenar automáticamente, si no lo volvería a acomodar).
  Future<void> shuffleUpcoming() async {
    if (!isHost) return;
    final start = _upcomingStart;
    if (queue.length - start < 2) return;
    final upcoming = queue.sublist(start)..shuffle(math.Random());
    queue.replaceRange(start, queue.length, upcoming);
    sortMode = QueueSortMode.none;
    notifyListeners();
    await _broadcastControl(_queueMessage());
  }

  /// Anfitrión: ordena lo que viene y lo mantiene ordenado cada vez que
  /// alguien agrega canciones.
  Future<void> setSortMode(QueueSortMode mode) async {
    if (!isHost) return;
    sortMode = mode;
    _applySort(restoreArrival: mode == QueueSortMode.none);
    _publishFeatureSummaries();
    notifyListeners();
    await _broadcastControl(_queueMessage());
  }

  /// Primera posición que se puede reordenar: lo que viene después de la
  /// canción actual (o toda la lista si todavía no arrancó).
  int get _upcomingStart =>
      _started ? (currentIndex + 1).clamp(0, queue.length) : 0;

  void _applySort({bool restoreArrival = false}) {
    if (sortMode == QueueSortMode.none && !restoreArrival) return;
    sortQueueFrom(queue,
        from: _upcomingStart, mode: sortMode, featuresOf: _featuresOf);
    if (sortMode == QueueSortMode.bpm || sortMode == QueueSortMode.smart) {
      unawaited(_analyzeQueue());
    }
  }

  TrackFeatures? _featuresOf(SyncTrack track) {
    final path = track.localPath;
    return path == null ? null : TrackFeaturesStore.instance.cached(path);
  }

  bool _analyzingQueue = false;

  /// Anfitrión: analiza ritmo y tonalidad de las canciones de la lista que
  /// todavía no lo tienen, y si el orden lo usa, reordena al terminar.
  Future<void> _analyzeQueue() async {
    if (!isHost || _analyzingQueue) return;
    final pending = queue
        .where((t) => t.localPath != null && _featuresOf(t) == null)
        .toList();
    if (pending.isEmpty) {
      _publishFeatureSummaries();
      return;
    }
    _analyzingQueue = true;
    analyzingCount = pending.length;
    notifyListeners();
    try {
      for (final track in pending) {
        await TrackFeaturesStore.instance
            .featuresFor(track.localPath!, durationMs: track.durationMs);
        analyzingCount--;
        notifyListeners();
        if (_disposed || !isHost) return;
      }
    } finally {
      _analyzingQueue = false;
      analyzingCount = 0;
    }
    if (sortMode == QueueSortMode.bpm || sortMode == QueueSortMode.smart) {
      sortQueueFrom(queue,
          from: _upcomingStart, mode: sortMode, featuresOf: _featuresOf);
    }
    _publishFeatureSummaries();
    notifyListeners();
    await _broadcastControl(_queueMessage());
  }

  void _publishFeatureSummaries() {
    for (final track in queue) {
      final summary = _featuresOf(track)?.summary;
      if (summary != null && summary.isNotEmpty) {
        track.featuresSummary = summary;
      }
    }
  }

  /// Anfitrión: saca una canción de la lista (no la que está sonando).
  Future<void> removeTrack(int index) async {
    if (!isHost ||
        index == currentIndex ||
        index < 0 ||
        index >= queue.length) {
      return;
    }
    queue.removeAt(index);
    if (index < currentIndex) currentIndex--;
    notifyListeners();
    await _broadcastControl(_queueMessage());
  }

  /// Manda en segundo plano, de a una, las canciones que le faltan a
  /// [guest]: la actual primero, después las que siguen y al final las
  /// anteriores.
  Future<void> _pumpTransfers(GuestInfo guest) async {
    if (guest._pumping) return;
    guest._pumping = true;
    try {
      while (!_disposed && identical(_guests[guest.address], guest)) {
        final track = _nextTrackFor(guest);
        if (track == null) break;
        guest
          ..sendingTrackId = track.id
          ..sendingProgress = 0;
        notifyListeners();
        try {
          await _bridge.sendSongFileTo(
            address: guest.address,
            path: track.localPath!,
            title: track.title,
            artist: track.artist,
            durationMs: track.durationMs,
            transferId: track.id,
            extra: {'trackId': track.id},
          );
          guest.hasTracks.add(track.id);
        } on PlatformException catch (e) {
          // CANCELLED: se cortó a propósito para priorizar otra canción; el
          // loop la retoma más adelante.
          if (e.code != 'CANCELLED') {
            debugPrint('Envío de "${track.title}" a ${guest.name} falló: $e');
            guest.failedTracks.add(track.id);
          }
        } finally {
          guest.sendingTrackId = null;
          notifyListeners();
        }
      }
    } finally {
      guest._pumping = false;
    }
  }

  SyncTrack? _nextTrackFor(GuestInfo guest) {
    if (queue.isEmpty) return null;
    final start = currentIndex.clamp(0, queue.length - 1);
    for (var offset = 0; offset < queue.length; offset++) {
      final track = queue[(start + offset) % queue.length];
      if (track.localPath != null &&
          !guest.hasTracks.contains(track.id) &&
          !guest.failedTracks.contains(track.id)) {
        return track;
      }
    }
    return null;
  }

  /// Carátulas de la biblioteca de este dispositivo (MediaStore en Android,
  /// la embebida en el archivo en Windows). El anfitrión se las manda a los
  /// invitados; un invitado, las de las canciones que agregó, al anfitrión
  /// (que las reenvía al resto).
  Future<void> _loadArtworks(List<SyncTrack> tracks) async {
    for (final track in tracks) {
      final songId = track.songId;
      if (_disposed || songId == null || track.artwork != null) continue;
      final art = await ArtworkBytes.forSong(songId);
      if (art == null || art.isEmpty) continue;
      track.artwork = art;
      notifyListeners();
      final message = {
        'type': 'artwork',
        'trackId': track.id,
        'data': base64Encode(art),
      };
      if (isHost) {
        await _broadcastControl(message);
      } else {
        await _sendToHost(message);
      }
    }
  }

  void _startDriftBroadcaster() {
    _driftTimer?.cancel();
    _driftTimer = Timer.periodic(_driftCheckInterval, (_) async {
      if (!_player.playing) return;
      await _broadcastControl({
        'type': 'position_sync',
        'trackId': currentTrack?.id,
        'hostTimestamp': _nowMs,
        'positionMs': _audiblePositionMs,
      });
    });
  }

  // ---------------------------------------------------------------------
  // Invitado
  // ---------------------------------------------------------------------

  void _applyQueue(Map<String, dynamic> payload) {
    final previous = {for (final track in queue) track.id: track};
    final tracks = (payload['tracks'] as List).cast<Map<String, dynamic>>();
    queue
      ..clear()
      ..addAll(tracks.map((json) {
        final track = SyncTrack.fromJson(json);
        final old = previous[track.id] ?? _ownTracks[track.id];
        if (old != null) {
          track
            ..localPath = old.localPath
            ..artwork = old.artwork;
        }
        return track;
      }));
    sortMode = QueueSortMode.values.firstWhere(
      (m) => m.name == payload['sortMode'],
      orElse: () => QueueSortMode.none,
    );
    currentIndex = (payload['currentIndex'] as int? ?? 0)
        .clamp(0, math.max(0, queue.length - 1));
    if (payload['started'] != true && status == PartySyncStatus.waitingHost) {
      statusMessage =
          'Conectado. Esperando que el anfitrión arranque la música...';
    }
    notifyListeners();
  }

  Future<void> _onPrepare(String trackId) async {
    _commandGeneration++;
    _correctionTimer?.cancel();
    await _player.pause();
    final index = queue.indexWhere((t) => t.id == trackId);
    if (index >= 0) currentIndex = index;
    _pendingPrepareTrackId = trackId;
    status = PartySyncStatus.preparing;
    statusMessage = null;
    notifyListeners();
    await _tryPrepare();
  }

  /// Carga la canción pendiente apenas se puede: si ya llegó entera, desde
  /// el archivo; si todavía está llegando pero hay colchón suficiente, por
  /// streaming. Recién entonces le avisa al anfitrión que está lista.
  Future<void> _tryPrepare() async {
    final trackId = _pendingPrepareTrackId;
    if (trackId == null || _prepareInFlight || _clockOffset == null) return;
    final track = _trackById(trackId);
    if (track == null) return;

    final path = track.localPath;
    final incoming = _incoming[trackId];
    final canStream =
        path == null && incoming != null && _streamReady(track, incoming);
    if (path == null && !canStream) return;

    _prepareInFlight = true;
    try {
      if (_loadedTrackId != trackId) {
        if (path != null) {
          await _player.setFilePath(path);
        } else {
          await _player.setUrl(incoming!.url);
        }
        _loadedTrackId = trackId;
      }
      _pendingPrepareTrackId = null;
      await _sendToHost({'type': 'prepared', 'trackId': trackId});
    } catch (e) {
      debugPrint('No se pudo cargar "${track.title}": $e');
    } finally {
      _prepareInFlight = false;
    }
    notifyListeners();
  }

  /// ¿Alcanza lo que ya llegó para empezar a sonar sin cortes? Hace falta
  /// el final del archivo (se manda primero) y un colchón al principio
  /// según qué tan rápido está llegando comparado con lo que consume la
  /// reproducción.
  bool _streamReady(SyncTrack track, _Incoming incoming) {
    final total = incoming.total;
    if (total == 0) return false;
    final tailDone = total <= 2 * _tailSize ||
        incoming.tailEnd >= total && incoming.tailFrom < total;
    if (!tailDone) return false;

    final elapsed =
        DateTime.now().difference(incoming.startedAt).inMilliseconds / 1000;
    if (elapsed < 1 || incoming.received < 128 * 1024) return false;
    final rate = incoming.received / elapsed; // bytes/s que llegan
    final durationSec = (track.durationMs ?? 0) / 1000;
    final bitrate = durationSec > 0
        ? total / durationSec
        : 40 * 1024; // bytes/s que consume
    final double needed;
    if (rate >= bitrate * 1.3) {
      needed = math.max(192 * 1024, bitrate * 8);
    } else if (durationSec > 0) {
      // Llega más lento que lo que suena: se espera lo justo para que la
      // descarga termine antes de que la reproducción la alcance.
      needed = total - rate * durationSec * 0.85;
    } else {
      return false;
    }
    return incoming.head >= needed;
  }

  Future<void> _onPlayAt(Map<String, dynamic> payload) async {
    final trackId = payload['trackId'] as String?;
    if (trackId != null && _loadedTrackId != trackId) {
      // Todavía no la tiene cargada: cuando la tenga manda "prepared" y el
      // anfitrión lo suma a lo que ya está sonando.
      if (_pendingPrepareTrackId != trackId) await _onPrepare(trackId);
      return;
    }
    final generation = ++_commandGeneration;
    await _waitAndPlay(
      payload['hostTimestamp'] as int,
      payload['positionMs'] as int? ?? 0,
      generation,
    );
  }

  /// Resincroniza con el anfitrión: si se cortó la conexión, reconecta; si
  /// no, repite la ronda de reloj y le pide al anfitrión que lo vuelva a
  /// poner en su canción y posición. Anfitrión: se lo pide a todos.
  Future<void> resync() async {
    if (isHost) {
      statusMessage = 'Resincronizando invitados...';
      notifyListeners();
      await _broadcastControl({'type': 'resync'});
      return;
    }
    if (!isGuest || _hostDevice == null) return;
    if (status == PartySyncStatus.disconnected) {
      await _connectToHost(reconnecting: true);
      return;
    }
    _resyncAfterClock = true;
    statusMessage = 'Resincronizando...';
    notifyListeners();
    await _runClockSync();
  }

  // ---- Reloj (protocolo NTP simplificado, lo inicia el invitado) ----

  /// Una ronda de medición del reloj: [_clockPings] idas y vueltas. Vale
  /// la de menor demora (NTP): una respuesta que viajó detrás de un pedazo
  /// de archivo tarda más y en un solo sentido, y falsearía la diferencia.
  Future<void> _runClockSync() async {
    if (_clockSyncRunning) return;
    _clockSyncRunning = true;
    _clockSamples.clear();
    _clockRoundOpen = true;
    try {
      for (var i = 0; i < _clockPings; i++) {
        if (_disposed) return;
        await _sendToHost({'type': 'clock_ping', 't0': _nowMs});
        await Future.delayed(const Duration(milliseconds: 80));
      }
      // Las últimas respuestas pueden venir un poco después.
      await Future.delayed(const Duration(milliseconds: 700));
      _finishClockRound();
    } finally {
      _clockSyncRunning = false;
    }
  }

  void _onClockPong(Map<String, dynamic> payload) {
    final t0 = payload['t0'] as int;
    final t1 = payload['t1'] as int;
    final t2 = payload['t2'] as int;
    final t3 = _nowMs;
    final rtt = (t3 - t0) - (t2 - t1);
    if (rtt < 0) return;
    _clockSamples.add((((t1 - t0) + (t2 - t3)) ~/ 2, rtt));
    if (_clockSamples.length >= _clockPings) _finishClockRound();
  }

  /// Cierra la ronda: la diferencia de reloj sale del promedio de las 3
  /// mediciones más rápidas.
  void _finishClockRound() {
    if (!_clockRoundOpen || _clockSamples.isEmpty) return;
    _clockRoundOpen = false;
    final best = [..._clockSamples]..sort((a, b) => a.$2.compareTo(b.$2));
    _clockSamples.clear();
    final top = best.take(3).toList();
    final offset =
        (top.map((s) => s.$1).reduce((a, b) => a + b) / top.length).round();
    clockRttMs = top.first.$2;
    final first = _clockOffset == null;
    _clockOffset = Duration(milliseconds: offset);
    if (first) {
      _clockRefreshTimer?.cancel();
      _clockRefreshTimer = Timer.periodic(_clockRefreshInterval, (_) {
        if (isGuest && status != PartySyncStatus.disconnected) {
          unawaited(_runClockSync());
        }
      });
    }
    if (status == PartySyncStatus.waitingHost) {
      statusMessage =
          'Conectado. Esperando que el anfitrión arranque la música...';
    } else if (statusMessage == 'Resincronizando...') {
      statusMessage = null;
    }
    notifyListeners();
    if (_resyncAfterClock) {
      _resyncAfterClock = false;
      unawaited(_sendToHost({'type': 'resync_request'}));
    }
    unawaited(_tryPrepare());
  }

  // ---------------------------------------------------------------------
  // Reproducción sincronizada
  // ---------------------------------------------------------------------

  /// Suena desde [positionMs] (lo que se tiene que ESCUCHAR) a la hora
  /// [hostTimestamp] del reloj del anfitrión. Si esa hora ya pasó (llegó
  /// tarde), arranca adelantado lo que corresponde para quedar alineado.
  /// Si ya está sonando (buscar, resincronizar), se acomoda la posición sin
  /// cortar el audio. El retraso del parlante de este dispositivo
  /// ([latencyMs]) se compensa adelantando el reproductor.
  Future<void> _waitAndPlay(
      int hostTimestamp, int positionMs, int generation) async {
    final localTarget = isGuest
        ? hostTimestamp - (_clockOffset?.inMilliseconds ?? 0)
        : hostTimestamp;
    final playerTarget = positionMs + latencyMs;
    _correctionTimer?.cancel();
    await _player.setSpeed(1.0);
    final delay = localTarget - _nowMs;
    if (delay <= 0) {
      await _player.seek(Duration(milliseconds: playerTarget - delay));
    } else if (_player.playing && playerTarget - delay >= 0) {
      // Dónde tiene que estar AHORA para llegar a positionMs justo a la
      // hora pedida sin dejar de sonar.
      await _player.seek(Duration(milliseconds: playerTarget - delay));
    } else {
      await _player.pause();
      await _player.seek(Duration(milliseconds: math.max(0, playerTarget)));
      await _waitUntil(localTarget);
    }
    if (_disposed || generation != _commandGeneration) return;
    if (!_player.playing) await _player.play();
    if (isGuest) {
      _anchorHostTs = hostTimestamp;
      _anchorPositionMs = positionMs;
      _driftSamples.clear();
      _startCorrectionLoop();
    }
    status = PartySyncStatus.playing;
    statusMessage = null;
    notifyListeners();
  }

  /// Espera hasta [targetMs] con precisión de ~1 ms: el temporizador común
  /// puede pasarse hasta 15 ms en Windows, así que el último tramo se
  /// espera cediendo el turno sin dormir.
  Future<void> _waitUntil(int targetMs) async {
    final coarse = targetMs - _nowMs - 25;
    if (coarse > 0) await Future.delayed(Duration(milliseconds: coarse));
    while (_nowMs < targetMs) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// "position_sync" del anfitrión: nueva referencia de dónde está.
  void _onHostPosition(Map<String, dynamic> payload) {
    if (payload['trackId'] != _loadedTrackId) return;
    _anchorHostTs = payload['hostTimestamp'] as int;
    _anchorPositionMs = payload['positionMs'] as int;
    if (_player.playing && !(_correctionTimer?.isActive ?? false)) {
      _startCorrectionLoop();
    }
  }

  void _startCorrectionLoop() {
    _correctionTimer?.cancel();
    _correctionTimer =
        Timer.periodic(_correctionInterval, (_) => unawaited(_correct()));
  }

  /// Corrección continua (invitado), cada [_correctionInterval]: compara
  /// dónde está con dónde tendría que estar según la última referencia del
  /// anfitrión y el reloj compartido.
  ///  - Hasta [_deadbandMs]: nada.
  ///  - Hasta [_hardSeekDriftMs]: apura o frena en proporción al desfase
  ///    (hasta ±6 %), así se acerca de a poco sin pasarse ni cortar.
  ///  - Más: salto directo.
  /// Se decide con la mediana de las últimas 3 mediciones (sin saltos por
  /// una lectura suelta).
  Future<void> _correct() async {
    final offset = _clockOffset;
    final anchorTs = _anchorHostTs;
    final anchorPos = _anchorPositionMs;
    if (offset == null ||
        anchorTs == null ||
        anchorPos == null ||
        !_player.playing ||
        _player.buffering) {
      return;
    }
    final hostNow = _nowMs + offset.inMilliseconds;
    final expected = anchorPos + (hostNow - anchorTs) + latencyMs;
    // Positivo = este invitado está atrasado.
    final drift = expected - _player.position.inMilliseconds;
    _driftSamples.add(drift);
    if (_driftSamples.length > 3) _driftSamples.removeAt(0);
    final sorted = [..._driftSamples]..sort();
    final median = sorted[sorted.length ~/ 2];
    final previous = driftMs;
    driftMs = median;
    if (previous == null || (previous - median).abs() >= 5) {
      notifyListeners();
    }
    if (median.abs() > _hardSeekDriftMs && _driftSamples.length >= 2) {
      _driftSamples.clear();
      await _player.setSpeed(1.0);
      await _player.seek(Duration(milliseconds: expected));
      return;
    }
    final target = median.abs() <= _deadbandMs
        ? 1.0
        : 1.0 + (median / 1500).clamp(-_maxSpeedDelta, _maxSpeedDelta);
    // De a pasos de 0,25 %: no se cambia la velocidad por décimas.
    final speed = (target * 400).round() / 400;
    if ((_player.speed - speed).abs() > 0.0001) await _player.setSpeed(speed);
  }

  // ---------------------------------------------------------------------
  // Envío de mensajes
  // ---------------------------------------------------------------------

  /// Difunde un mensaje de control a todos (anfitrión). Sin conexiones
  /// activas el puente responde NOT_CONNECTED: es un caso esperado, no un
  /// error de la sesión.
  Future<void> _broadcastControl(Map<String, dynamic> payload) async {
    if (isHost && _guests.isEmpty) return;
    try {
      await _bridge.sendControl(payload);
    } catch (e) {
      debugPrint('Control "${payload['type']}" omitido: $e');
    }
  }

  Future<void> _sendTo(String address, Map<String, dynamic> payload) async {
    try {
      await _bridge.sendControlTo(address, payload);
    } catch (e) {
      debugPrint('Control "${payload['type']}" a $address omitido: $e');
    }
  }

  /// Invitado: su única conexión es el anfitrión, así que "difundir" es
  /// mandárselo a él.
  Future<void> _sendToHost(Map<String, dynamic> payload) async {
    try {
      await _bridge.sendControl(payload);
    } catch (e) {
      debugPrint('Control "${payload['type']}" al anfitrión omitido: $e');
    }
  }

  SyncTrack? _trackById(String id) {
    for (final track in queue) {
      if (track.id == id) return track;
    }
    return null;
  }

  // ---------------------------------------------------------------------
  // Cierre
  // ---------------------------------------------------------------------

  Future<void> stop() async {
    _commandGeneration++;
    _driftTimer?.cancel();
    _correctionTimer?.cancel();
    _clockRefreshTimer?.cancel();
    _anchorHostTs = null;
    _anchorPositionMs = null;
    driftMs = null;
    clockRttMs = null;
    await _player.stop();
    if (isHost) await _broadcastControl({'type': 'stop_session'});
    await _streamServer.close();
    try {
      await _bridge.disconnect();
    } catch (e) {
      debugPrint('disconnect falló: $e');
    }
    _deleteReceivedFiles();
    status = PartySyncStatus.idle;
    statusMessage = null;
    queue.clear();
    currentIndex = 0;
    _loadedTrackId = null;
    _guests.clear();
    _started = false;
    hostingReady = false;
    _clockOffset = null;
    _pendingPrepareTrackId = null;
    _incoming.clear();
    sortMode = QueueSortMode.none;
    karaoke = false;
    _waitingUploadTrackId = null;
    _hostAddress = null;
    _ownTracks.clear();
    _uploadedIds.clear();
    _uploadProgress.clear();
    if (!_disposed) notifyListeners();
  }

  /// Los archivos recibidos (canciones del anfitrión en el invitado, o las
  /// que subieron los invitados en el anfitrión) son solo para esta sesión.
  /// Los originales de la biblioteca nunca están en esta lista.
  void _deleteReceivedFiles() {
    for (final path in _receivedFiles) {
      try {
        final file = File(path);
        if (file.existsSync()) file.deleteSync();
      } catch (e) {
        debugPrint('No se pudo borrar $path: $e');
      }
    }
    _receivedFiles.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_reactions.close());
    _driftTimer?.cancel();
    _correctionTimer?.cancel();
    _clockRefreshTimer?.cancel();
    _eventsSub?.cancel();
    _completedSub?.cancel();
    unawaited(_streamServer.close());
    unawaited(_player.dispose());
    _deleteReceivedFiles();
    super.dispose();
  }
}

/// Ordena [queue] desde la posición [from] (lo anterior —lo que ya sonó y
/// lo que está sonando— no se toca) según [mode]. Los empates quedan en el
/// orden en que se agregaron. [QueueSortMode.none] vuelve a ese orden de
/// llegada.
void sortQueueFrom(
  List<SyncTrack> queue, {
  required int from,
  required QueueSortMode mode,
  TrackFeatures? Function(SyncTrack track)? featuresOf,
}) {
  final start = from.clamp(0, queue.length);
  if (queue.length - start < 2) return;
  TrackFeatures? fx(SyncTrack t) => featuresOf?.call(t);

  if (mode == QueueSortMode.smart) {
    // Como un DJ: cada una seguida de la que mejor encadena con la
    // anterior (tempo, tonalidad, energía). Si todavía no arrancó, empieza
    // por la más tranquila.
    final anchor = start > 0 ? queue[start - 1] : null;
    final upcoming = queue.sublist(start);
    if (anchor == null) {
      final known = upcoming.where((t) => fx(t) != null).toList()
        ..sort((a, b) => fx(a)!.energy.compareTo(fx(b)!.energy));
      if (known.isNotEmpty) {
        upcoming
          ..remove(known.first)
          ..insert(0, known.first);
      }
    }
    final ordered =
        orderForMixing([if (anchor != null) anchor, ...upcoming], fx);
    queue.replaceRange(
        start, queue.length, anchor == null ? ordered : ordered.skip(1));
    return;
  }

  String text(String? value) => (value ?? '').toLowerCase();
  int byText(String? a, String? b) => text(a).compareTo(text(b));
  int compare(SyncTrack a, SyncTrack b) {
    final result = switch (mode) {
      QueueSortMode.none => 0,
      QueueSortMode.title => byText(a.title, b.title),
      QueueSortMode.artist => byText(a.artist, b.artist) != 0
          ? byText(a.artist, b.artist)
          : byText(a.title, b.title),
      QueueSortMode.album => byText(a.album, b.album) != 0
          ? byText(a.album, b.album)
          : byText(a.title, b.title),
      QueueSortMode.duration =>
        (a.durationMs ?? 0).compareTo(b.durationMs ?? 0),
      // Sin analizar, al final.
      QueueSortMode.bpm => (fx(a)?.bpm ?? 9999).compareTo(fx(b)?.bpm ?? 9999),
      QueueSortMode.smart => 0,
    };
    return result != 0 ? result : a.arrival.compareTo(b.arrival);
  }

  final upcoming = queue.sublist(start)..sort(compare);
  queue.replaceRange(start, queue.length, upcoming);
}

/// El motivo técnico de un error, corto, para el final de los avisos.
String _errorDetail(Object error) {
  var detail = error is PlatformException ? (error.message ?? '') : '$error';
  if (detail.length > 300) detail = '${detail.substring(0, 300)}…';
  return detail.isEmpty ? '' : '\n\nDetalle: $detail';
}

/// El aviso cuando el invitado no puede conectarse por Wi-Fi.
String wifiConnectFailedMessage(String hostName, Object error) =>
    'No se pudo conectar con "$hostName" por Wi-Fi. Revisá:\n'
    '• Que los dos estén en la misma red Wi-Fi (o conectados a la zona '
    'Wi-Fi del teléfono anfitrión).\n'
    '• Que en "$hostName" la sesión esté iniciada como anfitrión por Wi-Fi.\n'
    '• En una PC con Windows: que TK Music tenga permiso en el firewall '
    '(el aviso aparece la primera vez; hay que permitir las redes '
    'privadas).\n'
    '• Algunas redes (hoteles, empresas) no dejan que los dispositivos se '
    'vean entre sí: probá con la zona Wi-Fi de un teléfono o por Bluetooth.'
    '${_errorDetail(error)}';

/// El aviso cuando no se puede abrir la sala por Wi-Fi.
String wifiHostFailedMessage(Object error) =>
    'No se pudo iniciar la sesión por Wi-Fi. Revisá que este dispositivo '
    'esté conectado a una red Wi-Fi (o compartiendo su zona Wi-Fi) y probá '
    'de nuevo.${_errorDetail(error)}';

/// El aviso cuando el invitado no puede conectarse por Bluetooth: qué
/// revisar y, abajo, el motivo técnico de cada intento (para diagnosticar).
String bluetoothConnectFailedMessage(String hostName, Object error) {
  return 'No se pudo conectar con "$hostName". Revisá:\n'
      '• En "$hostName", TK Music abierto en Sincronizar como anfitrión por '
      'Bluetooth (no Wi-Fi) y con la sesión iniciada.\n'
      '• Los dos vinculados en el Bluetooth del sistema. Si ya lo estaban, '
      'quitá el vínculo en los dos y volvé a vincular.\n'
      '• Que otro programa no esté usando el Bluetooth de la PC.'
      '${_errorDetail(error)}';
}
