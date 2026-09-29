import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/domain/entities/playlist.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/presentation/pages/qr_scan_screen.dart';
import 'package:tk_music/presentation/widgets/app_header.dart';
import 'package:tk_music/presentation/widgets/app_logo.dart';
import 'package:tk_music/presentation/widgets/app_providers.dart';
import 'package:tk_music/presentation/widgets/artwork_backdrop.dart';
import 'package:tk_music/presentation/widgets/lyrics_view.dart';
import 'package:tk_music/presentation/widgets/song_artwork.dart';
import 'package:tk_music/presentation/widgets/sync_invite_card.dart';
import 'package:tk_music/core/platform.dart';
import 'package:tk_music/services/device_name.dart';
import 'package:tk_music/services/bluetooth_sync_bridge.dart';
import 'package:tk_music/services/party_sync_engine.dart';
import 'package:tk_music/services/playlist_store.dart';
import 'package:tk_music/services/sync_invite.dart';
import 'package:tk_music/services/wifi_sync_transport.dart';

enum _Step { chooseRole, hostSetup, guestSetup }

/// Sincroniza la música entre este dispositivo y otros (Android o
/// desktop), por Wi-Fi o por Bluetooth: el anfitrión arma una lista de
/// canciones y la controla; los invitados ven lo mismo, escuchan en espejo,
/// suman canciones y reaccionan. Sesión aparte y en primer plano (pausa el
/// reproductor principal al entrar), igual que el Mezclador automático.
class PartySyncScreen extends StatefulWidget {
  const PartySyncScreen({super.key});

  @override
  State<PartySyncScreen> createState() => _PartySyncScreenState();
}

class _PartySyncScreenState extends State<PartySyncScreen> {
  PartySyncEngine _engine = PartySyncEngine();
  _Step _step = _Step.chooseRole;

  /// Wi-Fi (recomendado: más rápido, más alcance y más invitados) o
  /// Bluetooth (sin red de por medio).
  bool _useWifi = true;
  String _deviceName = 'Anfitrión';
  List<PairedBluetoothDevice>? _devices;
  SyncCapacity? _capacity;
  final Set<String> _activeAddresses = {};
  StreamSubscription<BluetoothSyncEvent>? _aclSub;
  final List<PairedBluetoothDevice> _selectedGuestDevices = [];
  PairedBluetoothDevice? _selectedHostDevice;
  final List<Song> _selectedSongs = [];
  String? _permissionError;

  /// Nombre de la sala que ven los invitados (en el QR y en la lista de
  /// anfitriones por Wi-Fi). Vacío = el nombre del dispositivo.
  final _roomName = TextEditingController();
  String get _room =>
      _roomName.text.trim().isEmpty ? _deviceName : _roomName.text.trim();

  @override
  void initState() {
    super.initState();
    if (isAudioAvailable) sl<AudioHandler>().pause();
    unawaited(_loadDeviceName());
  }

  /// Cómo lo ven los demás (lista de anfitriones, reacciones).
  Future<void> _loadDeviceName() async {
    final name = await localDeviceName();
    // Sin datos del equipo: queda el nombre genérico.
    if (mounted && name != null) setState(() => _deviceName = name);
  }

  /// Motor nuevo con el transporte elegido (antes de arrancar una sesión).
  /// El anfitrión se anuncia en la red con el nombre de la sala.
  void _prepareEngine({bool host = false}) {
    final old = _engine;
    _engine = PartySyncEngine(
      transport: _useWifi
          ? WifiSyncService(deviceName: host ? _room : _deviceName)
          : null,
      localName: _deviceName,
    );
    old.dispose();
  }

  @override
  void dispose() {
    _roomName.dispose();
    _aclSub?.cancel();
    // Salir con la flecha de atrás también cierra la sesión Bluetooth: si
    // no, la conexión quedaba abierta del lado nativo.
    final engine = _engine;
    unawaited(engine.stop().whenComplete(engine.dispose));
    super.dispose();
  }

  Future<void> _loadDevices() async {
    // El permiso de Bluetooth es de Android (12+); en Windows no existe.
    final status = isAndroidPlatform
        ? await Permission.bluetoothConnect.request()
        : PermissionStatus.granted;
    if (!status.isGranted) {
      setState(() => _permissionError =
          'Hace falta el permiso de Bluetooth para ver los dispositivos emparejados.');
      return;
    }
    final devices = await BluetoothSyncService().getPairedDevices();
    final capacity = await BluetoothSyncService().capacity();
    final active = await BluetoothSyncService().getActiveDeviceAddresses();
    // Actualiza en vivo qué dispositivos tienen sesión Bluetooth activa
    // (se conectan/desconectan mientras mirás la lista).
    _aclSub ??= BluetoothSyncService().events.listen((event) {
      if (event is! DeviceConnectionChangedEvent || !mounted) return;
      setState(() {
        if (event.connected) {
          _activeAddresses.add(event.address);
        } else {
          _activeAddresses.remove(event.address);
        }
      });
    });
    if (!mounted) return;
    setState(() {
      _devices = devices;
      _capacity = capacity;
      _activeAddresses
        ..clear()
        ..addAll(active);
      _permissionError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: const AppHeaderTitle(
              section: 'Sincronizar con otro dispositivo')),
      // En desktop la ventana es mucho más ancha que un teléfono: todo el
      // contenido va centrado y con ancho acotado para que no quede pegado
      // a la izquierda ni se estire de borde a borde.
      // Durante la sesión, todo toma el color de la carátula de lo que
      // suena (la del anfitrión, o la imagen que él mandó).
      body: AnimatedBuilder(
        animation: _engine,
        builder: (context, child) {
          final track = _engine.status == PartySyncStatus.idle
              ? null
              : _engine.currentTrack;
          if (track == null) return child!;
          return ArtworkGradient(
            songId: track.artwork == null ? track.songId : null,
            artwork: track.artwork,
            artworkKey: 'sync:${track.id}',
            child: child!,
          );
        },
        child: Stack(
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: AnimatedBuilder(
                  animation: _engine,
                  builder: (context, _) => _buildStep(),
                ),
              ),
            ),
            // Emojis que suben por la pantalla cuando alguien reacciona.
            Positioned.fill(
              child: IgnorePointer(
                child: _ReactionOverlay(
                  key: ObjectKey(_engine),
                  reactions: _engine.reactions,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStep() {
    if (_engine.status != PartySyncStatus.idle) {
      return _SessionView(
        engine: _engine,
        room: _room,
        onExit: _exitSession,
        onAddSongs: _addSongsToSession,
      );
    }
    return switch (_step) {
      _Step.chooseRole => _RoleChoice(
          useWifi: _useWifi,
          onScanQr: _joinWithQr,
          onTransportChanged: (wifi) => setState(() => _useWifi = wifi),
          onHost: () {
            setState(() => _step = _Step.hostSetup);
            if (!_useWifi) _loadDevices();
          },
          onGuest: () {
            setState(() => _step = _Step.guestSetup);
            if (!_useWifi) _loadDevices();
          },
        ),
      _Step.hostSetup => _HostSetup(
          wifi: _useWifi,
          roomName: _roomName,
          defaultRoomName: _deviceName,
          devices: _devices,
          capacity: _capacity,
          activeAddresses: _activeAddresses,
          permissionError: _permissionError,
          selectedDevices: _selectedGuestDevices,
          selectedSongs: _selectedSongs,
          onDevicesChanged: (d) => setState(() {
            _selectedGuestDevices
              ..clear()
              ..addAll(d);
          }),
          onPickSongs: _pickSongs,
          onPickPlaylist: _pickPlaylist,
          onRemoveSong: (song) => setState(() => _selectedSongs.remove(song)),
          onStart: _startHost,
        ),
      _Step.guestSetup when _useWifi => _WifiGuestSetup(
          deviceName: _deviceName,
          onScanQr: _joinWithQr,
          onJoin: (host) => _joinAsGuest(host),
        ),
      _Step.guestSetup => _GuestSetup(
          onScanQr: _joinWithQr,
          devices: _devices,
          capacity: _capacity,
          activeAddresses: _activeAddresses,
          permissionError: _permissionError,
          selectedDevice: _selectedHostDevice,
          onDeviceChanged: (d) => setState(() => _selectedHostDevice = d),
          onJoin: () {
            final device = _selectedHostDevice;
            if (device != null) _joinAsGuest(device);
          },
        ),
    };
  }

  Future<List<Song>?> _openSongPicker({List<Song> initial = const []}) {
    final songs = AppProviders.songOf(context).songs;
    return Navigator.of(context).push<List<Song>>(
      MaterialPageRoute(
        builder: (_) =>
            _SongPickerScreen(songs: songs, initialSelection: initial),
      ),
    );
  }

  /// Canciones de una playlist guardada, en su orden (las que ya no están
  /// en la biblioteca se saltean).
  Future<List<Song>?> _choosePlaylistSongs() async {
    final library = AppProviders.songOf(context).songs;
    final byId = {for (final song in library) song.mediaStoreId: song};
    final playlists = await PlaylistStore.instance.getAll();
    if (!mounted) return null;
    final chosen = await showModalBottomSheet<Playlist>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: playlists.isEmpty
            ? const Padding(
                padding: EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Text('Todavía no tenés listas guardadas.'),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final playlist in playlists)
                    ListTile(
                      leading: const Icon(Icons.queue_music),
                      title: Text(playlist.name),
                      subtitle: Text('${playlist.songIds.length} canciones'),
                      onTap: () => Navigator.of(sheetContext).pop(playlist),
                    ),
                ],
              ),
      ),
    );
    if (chosen == null) return null;
    return [
      for (final id in chosen.songIds)
        if (byId[id] != null) byId[id]!,
    ];
  }

  Future<void> _pickSongs() async {
    final picked = await _openSongPicker(initial: _selectedSongs);
    if (picked == null) return;
    setState(() {
      _selectedSongs
        ..clear()
        ..addAll(picked);
    });
  }

  Future<void> _pickPlaylist() async {
    final songs = await _choosePlaylistSongs();
    if (songs == null || songs.isEmpty) return;
    setState(() {
      for (final song in songs) {
        if (!_selectedSongs.contains(song)) _selectedSongs.add(song);
      }
    });
  }

  Future<void> _addSongsToSession() async {
    final source = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.library_music),
              title: const Text('Elegir canciones'),
              onTap: () => Navigator.of(sheetContext).pop('songs'),
            ),
            ListTile(
              leading: const Icon(Icons.queue_music),
              title: const Text('Agregar una lista'),
              onTap: () => Navigator.of(sheetContext).pop('playlist'),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    final songs = source == 'playlist'
        ? await _choosePlaylistSongs()
        : await _openSongPicker();
    if (songs != null && songs.isNotEmpty) await _engine.addSongs(songs);
  }

  Future<void> _startHost() async {
    if (_selectedSongs.isEmpty) return;
    setState(() => _prepareEngine(host: true));
    // Sin lista de invitados esperados (Wi-Fi, o Bluetooth con los que se
    // unen escaneando el QR): el anfitrión arranca cuando quiere y los que
    // llegan después se suman solos.
    await _engine.startAsHost(
      _useWifi ? const [] : List.of(_selectedGuestDevices),
      List.of(_selectedSongs),
    );
  }

  Future<void> _joinAsGuest(PairedBluetoothDevice host) async {
    setState(_prepareEngine);
    await _engine.joinAsGuest(host);
  }

  /// "Unirse con QR": escanea el código del anfitrión y se conecta solo,
  /// por Wi-Fi o por Bluetooth según lo que diga el QR.
  Future<void> _joinWithQr() async {
    final invite = await Navigator.of(context).push<SyncInvite>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (invite == null || !mounted) return;

    if (invite.transport == InviteTransport.wifi) {
      final own = await WifiSyncService.localAddresses();
      final best = pickHostAddress(invite.addresses, own);
      // La de la misma red primero y después las demás, con el puerto del
      // QR (el anfitrión usa otro si el habitual estaba ocupado).
      final port = invite.port;
      final target = [best, ...invite.addresses.where((a) => a != best)]
          .map((a) => port == null ? a : '$a:$port')
          .join(',');
      if (!mounted) return;
      setState(() {
        _useWifi = true;
        _step = _Step.guestSetup;
      });
      await _joinAsGuest(PairedBluetoothDevice(
          name: invite.room.isEmpty ? best : invite.room, address: target));
      return;
    }

    if (!supportsBluetoothSync) {
      _showQrProblem('Este dispositivo no puede usar Bluetooth para '
          'sincronizar. Pedile al anfitrión que abra la sala por Wi-Fi.');
      return;
    }
    setState(() {
      _useWifi = false;
      _step = _Step.guestSetup;
    });
    await _loadDevices();
    final devices = _devices;
    if (!mounted || devices == null) return; // sin permiso: ya se muestra
    final host = findInvitedHost(invite, devices);
    if (host == null) {
      final name = invite.bluetoothName ?? invite.room;
      _showQrProblem(
        'Para unirte por Bluetooth, primero emparejá este dispositivo con '
        '"$name" desde el Bluetooth del sistema. Después volvé a escanear '
        'el QR.',
        openBluetooth: true,
      );
      return;
    }
    final channel = invite.bluetoothChannel;
    if (channel != null) {
      BluetoothSyncService.channelHints[host.address.toUpperCase()] = channel;
    }
    setState(() => _selectedHostDevice = host);
    await _joinAsGuest(host);
  }

  void _showQrProblem(String message, {bool openBluetooth = false}) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Unirse con QR'),
        content: Text(message),
        actions: [
          if (openBluetooth)
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                unawaited(BluetoothSyncService().openSystemSettings());
              },
              child: const Text('Abrir Bluetooth'),
            ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
  }

  Future<void> _exitSession() async {
    await _engine.stop();
    setState(() {
      _step = _Step.chooseRole;
      _selectedGuestDevices.clear();
      _selectedHostDevice = null;
      _selectedSongs.clear();
    });
  }
}

class _RoleChoice extends StatelessWidget {
  const _RoleChoice({
    required this.useWifi,
    required this.onScanQr,
    required this.onTransportChanged,
    required this.onHost,
    required this.onGuest,
  });

  final bool useWifi;
  final VoidCallback onScanQr;
  final ValueChanged<bool> onTransportChanged;
  final VoidCallback onHost;
  final VoidCallback onGuest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(useWifi ? Icons.wifi : Icons.bluetooth_audio,
                size: 48, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                    value: true, icon: Icon(Icons.wifi), label: Text('Wi-Fi')),
                ButtonSegment(
                    value: false,
                    icon: Icon(Icons.bluetooth),
                    label: Text('Bluetooth')),
              ],
              selected: {useWifi},
              onSelectionChanged: (value) => onTransportChanged(value.first),
            ),
            const SizedBox(height: 12),
            Text(
              useWifi
                  ? 'Todos en la misma red Wi-Fi (o conectados a la zona Wi-Fi '
                      'de un teléfono). Más rápido y hasta 15 invitados.'
                  : 'Dispositivos ya emparejados por Bluetooth, sin red de por '
                      'medio. Hasta ${PartySyncEngine.maxGuests} invitados.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onHost,
              icon: const Icon(Icons.upload),
              label: const Text('Ser anfitrión (elijo la canción)'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onGuest,
              icon: const Icon(Icons.download),
              label: const Text('Unirme a una sesión'),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: onScanQr,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Unirse con QR'),
            ),
            const SizedBox(height: 8),
            Text(
              'Escaneá el QR que muestra el anfitrión: se conecta solo, por '
              'Wi-Fi o Bluetooth.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _DevicePicker extends StatelessWidget {
  const _DevicePicker({
    required this.devices,
    required this.permissionError,
    required this.selectedDevice,
    required this.onDeviceChanged,
  });

  final List<PairedBluetoothDevice>? devices;
  final String? permissionError;
  final PairedBluetoothDevice? selectedDevice;
  final ValueChanged<PairedBluetoothDevice?> onDeviceChanged;

  @override
  Widget build(BuildContext context) {
    if (permissionError != null) {
      return Text(
        permissionError!,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      );
    }
    if (devices == null) {
      return const LinearProgressIndicator();
    }
    if (devices!.isEmpty) {
      return const Text(
        'No tenés ningún dispositivo Bluetooth emparejado. Emparejá los dos '
        'teléfonos desde los ajustes de Android primero.',
      );
    }
    return DropdownButtonFormField<PairedBluetoothDevice>(
      value: selectedDevice,
      decoration: const InputDecoration(labelText: 'Dispositivo'),
      items: devices!
          .map((d) => DropdownMenuItem(value: d, child: Text(d.name)))
          .toList(),
      onChanged: onDeviceChanged,
    );
  }
}

/// Muestra el resultado de la validación de capacidad Bluetooth antes de
/// armar la sesión: avisa si el dispositivo no puede sostener la cantidad de
/// conexiones activas que pide esta función (o si solo trae Bluetooth LE,
/// que no soporta RFCOMM), o informa el límite cuando sí puede.
class _CapacityNotice extends StatelessWidget {
  const _CapacityNotice({required this.capacity, required this.guestMode});

  final SyncCapacity? capacity;
  final bool guestMode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cap = capacity;
    if (cap == null) return const SizedBox.shrink();

    if (!cap.supported) {
      final message = switch (cap.reason) {
        'le_only' => 'Este dispositivo tiene Bluetooth solo de bajo consumo '
            '(LE) y no soporta el modo clásico que usa la sincronización. '
            'No puede participar.',
        'no_bluetooth' => 'Este dispositivo no tiene Bluetooth.',
        _ => 'No se pudo verificar la capacidad Bluetooth de este '
            'dispositivo.',
      };
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 18, color: Colors.red),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
        ],
      );
    }

    if (guestMode) {
      return Text(
        'Bluetooth clásico disponible (este teléfono va a mantener una sola '
        'conexión con el anfitrión).',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    }

    final maxHost = cap.maxConcurrent == 0
        ? PartySyncEngine.maxGuests
        : cap.maxConcurrent.clamp(1, PartySyncEngine.maxGuests);
    return Text(
      'Bluetooth clásico disponible: este teléfono puede sostener hasta '
      '$maxHost sesiones activas a la vez. La sincronización necesita una '
      'sesión por invitado (máximo ${PartySyncEngine.maxGuests}).',
      style: theme.textTheme.bodySmall
          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    );
  }
}

class _HostSetup extends StatelessWidget {
  const _HostSetup({
    required this.wifi,
    required this.roomName,
    required this.defaultRoomName,
    required this.devices,
    required this.capacity,
    required this.activeAddresses,
    required this.permissionError,
    required this.selectedDevices,
    required this.selectedSongs,
    required this.onDevicesChanged,
    required this.onPickSongs,
    required this.onPickPlaylist,
    required this.onRemoveSong,
    required this.onStart,
  });

  static const _previewCount = 8;

  final bool wifi;
  final TextEditingController roomName;
  final String defaultRoomName;
  final List<PairedBluetoothDevice>? devices;
  final SyncCapacity? capacity;
  final Set<String> activeAddresses;
  final String? permissionError;
  final List<PairedBluetoothDevice> selectedDevices;
  final List<Song> selectedSongs;
  final ValueChanged<List<PairedBluetoothDevice>> onDevicesChanged;
  final VoidCallback onPickSongs;
  final VoidCallback onPickPlaylist;
  final ValueChanged<Song> onRemoveSong;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: roomName,
            textCapitalization: TextCapitalization.sentences,
            maxLength: 30,
            decoration: InputDecoration(
              labelText: 'Nombre de la sala',
              hintText: defaultRoomName,
              helperText: 'Lo ven los invitados en el QR y en la lista',
              prefixIcon: const Icon(Icons.celebration_outlined),
            ),
          ),
          const SizedBox(height: 12),
          if (!wifi) ...[
            _CapacityNotice(capacity: capacity, guestMode: false),
            const SizedBox(height: 12),
            Text(
              '1. Invitados (opcional, hasta ${PartySyncEngine.maxGuests})',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Elegí a quién esperar, o dejalo vacío: los invitados se unen '
              'escaneando el QR que vas a ver al empezar.',
              style: muted,
            ),
            const SizedBox(height: 8),
            _MultiDevicePicker(
              devices: devices,
              capacity: capacity,
              activeAddresses: activeAddresses,
              permissionError: permissionError,
              selectedDevices: selectedDevices,
              onChanged: onDevicesChanged,
            ),
            const SizedBox(height: 20),
          ],
          Text(
              wifi
                  ? 'Armá la lista de canciones'
                  : '2. Armá la lista de canciones',
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onPickSongs,
                icon: const Icon(Icons.library_music),
                label: Text(selectedSongs.isEmpty
                    ? 'Elegir canciones'
                    : 'Cambiar canciones'),
              ),
              OutlinedButton.icon(
                onPressed: onPickPlaylist,
                icon: const Icon(Icons.queue_music),
                label: const Text('Agregar una lista'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (selectedSongs.isEmpty)
            Text('Ninguna canción elegida', style: muted)
          else ...[
            Text('${selectedSongs.length} canciones en la lista', style: muted),
            for (final (index, song)
                in selectedSongs.take(_previewCount).indexed)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: SizedBox(
                  width: 24,
                  child: Text('${index + 1}', textAlign: TextAlign.center),
                ),
                title: Text(song.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: song.artist == null
                    ? null
                    : Text(song.artist!,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  tooltip: 'Quitar',
                  icon: const Icon(Icons.close),
                  onPressed: () => onRemoveSong(song),
                ),
              ),
            if (selectedSongs.length > _previewCount)
              Text('y ${selectedSongs.length - _previewCount} más...',
                  style: muted),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: selectedSongs.isEmpty ? null : onStart,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Iniciar sincronización'),
          ),
          const SizedBox(height: 12),
          Text(
            wifi
                ? 'Los invitados escanean tu QR o abren esta misma app en '
                    '"Unirme a una sesión" (con Wi-Fi) y te ven en la lista. '
                    'Arrancás cuando quieras: '
                    'los que lleguen después se suman a lo que está sonando. '
                    'Las canciones se les van mandando en segundo plano y '
                    'pueden empezar a escucharlas antes de que terminen de '
                    'llegar.'
                : 'Los invitados se unen escaneando tu QR, o abriendo esta '
                    'misma app en "Unirme a una sesión". Si elegiste '
                    'invitados, la música arranca sola apenas se conectan '
                    'todos; si no, la arrancás vos cuando quieras. Las '
                    'canciones se les van mandando en segundo plano: la que '
                    'suena primero, y pueden empezar a escucharla antes de '
                    'que termine de llegar.',
            style: muted,
          ),
        ],
      ),
    );
  }
}

class _MultiDevicePicker extends StatelessWidget {
  const _MultiDevicePicker({
    required this.devices,
    required this.capacity,
    required this.activeAddresses,
    required this.permissionError,
    required this.selectedDevices,
    required this.onChanged,
  });

  final List<PairedBluetoothDevice>? devices;
  final SyncCapacity? capacity;
  final Set<String> activeAddresses;
  final String? permissionError;
  final List<PairedBluetoothDevice> selectedDevices;
  final ValueChanged<List<PairedBluetoothDevice>> onChanged;

  @override
  Widget build(BuildContext context) {
    if (permissionError != null) {
      return Text(
        permissionError!,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      );
    }
    if (devices == null) {
      return const LinearProgressIndicator();
    }
    if (capacity != null && !capacity!.supported) {
      // Sin Bluetooth clásico no se puede ni montar la sesión: se corta la
      // selección antes de que el usuario arme una lista que nunca va a
      // poder conectar.
      return const SizedBox.shrink();
    }
    if (devices!.isEmpty) {
      return const Text(
        'No tenés ningún dispositivo Bluetooth emparejado. Emparejá los '
        'teléfonos desde los ajustes de Android primero.',
      );
    }
    // La capacidad medida limita cuántos invitados se pueden elegir: nunca
    // más que lo que soporta el estándar del dispositivo, y nunca más que
    // los que permite el motor de sincronización.
    final cap = capacity?.maxConcurrent ?? PartySyncEngine.maxGuests;
    final maxSelectable =
        cap <= 0 ? 0 : cap.clamp(1, PartySyncEngine.maxGuests).toInt();
    return Column(
      children: [
        for (final device in devices!)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(device.name),
            value: selectedDevices.any((d) => d.address == device.address),
            onChanged: (checked) {
              final next = [...selectedDevices];
              if (checked ?? false) {
                if (next.length >= maxSelectable) return;
                next.add(device);
              } else {
                next.removeWhere((d) => d.address == device.address);
              }
              onChanged(next);
            },
          ),
      ],
    );
  }
}

class _GuestSetup extends StatelessWidget {
  const _GuestSetup({
    required this.onScanQr,
    required this.devices,
    required this.capacity,
    required this.activeAddresses,
    required this.permissionError,
    required this.selectedDevice,
    required this.onDeviceChanged,
    required this.onJoin,
  });

  final VoidCallback onScanQr;
  final List<PairedBluetoothDevice>? devices;
  final SyncCapacity? capacity;
  final Set<String> activeAddresses;
  final String? permissionError;
  final PairedBluetoothDevice? selectedDevice;
  final ValueChanged<PairedBluetoothDevice?> onDeviceChanged;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CapacityNotice(capacity: capacity, guestMode: true),
          const SizedBox(height: 12),
          ScanQrButton(onPressed: onScanQr),
          const SizedBox(height: 20),
          Text('O elegí el anfitrión', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          _DevicePicker(
            devices: devices,
            permissionError: permissionError,
            selectedDevice: selectedDevice,
            onDeviceChanged: onDeviceChanged,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: selectedDevice == null ||
                    (capacity != null && !capacity!.supported)
                ? null
                : onJoin,
            icon: const Icon(Icons.bluetooth_connected),
            label: const Text('Conectarme'),
          ),
        ],
      ),
    );
  }
}

/// Vista de la sesión en curso — la misma para anfitrión e invitado: lo que
/// suena (carátula, título, artista, álbum), el avance, el estado de las
/// transferencias y la lista compartida. Solo el anfitrión tiene los
/// controles; el invitado tiene "Resincronizar" / "Reconectar".
class _SessionView extends StatefulWidget {
  const _SessionView({
    required this.engine,
    required this.room,
    required this.onExit,
    required this.onAddSongs,
  });

  final PartySyncEngine engine;
  final String room;
  final VoidCallback onExit;
  final VoidCallback onAddSongs;

  @override
  State<_SessionView> createState() => _SessionViewState();
}

class _SessionViewState extends State<_SessionView> {
  Timer? _ticker;
  double? _dragMs;

  @override
  void initState() {
    super.initState();
    // La posición del reproductor no avisa sola: se refresca la barra (y
    // la letra del karaoke, que necesita más precisión).
    var tick = 0;
    _ticker = Timer.periodic(const Duration(milliseconds: 150), (_) {
      tick++;
      final engine = widget.engine;
      if (!mounted ||
          _dragMs != null ||
          engine.status != PartySyncStatus.playing) {
        return;
      }
      if (engine.karaoke || tick % 3 == 0) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engine = widget.engine;
    final theme = Theme.of(context);
    final track = engine.currentTrack;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        if (engine.isHost)
          // Con key: se rearma cuando el anfitrión ya sabe su puerto.
          SyncInviteCard(
              key: ValueKey((engine.hostingReady, engine.wifiPort)),
              wifi: engine.isWifi,
              room: widget.room,
              port: engine.wifiPort),
        if (engine.karaoke)
          _KaraokePanel(engine: engine)
        else
          _NowPlayingHeader(track: track),
        const SizedBox(height: 12),
        _buildProgress(theme),
        const SizedBox(height: 4),
        _buildControls(theme),
        const SizedBox(height: 12),
        _StatusPanel(engine: engine),
        const SizedBox(height: 12),
        _buildActions(),
        const SizedBox(height: 12),
        _SyncTuningPanel(engine: engine),
        if (engine.status != PartySyncStatus.connecting &&
            engine.status != PartySyncStatus.disconnected) ...[
          const SizedBox(height: 12),
          _ReactionBar(engine: engine),
        ],
        if (engine.isHost && engine.guests.isNotEmpty) ...[
          const SizedBox(height: 20),
          _SectionTitle('Invitados (${engine.connectedGuestCount})'),
          for (final guest in engine.guests)
            _GuestTile(engine: engine, guest: guest),
        ],
        const SizedBox(height: 20),
        _QueueHeader(engine: engine),
        if (engine.queue.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'El anfitrión todavía no mandó la lista.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        for (final (index, item) in engine.queue.indexed)
          _QueueTile(engine: engine, track: item, index: index),
      ],
    );
  }

  Widget _buildProgress(ThemeData theme) {
    final engine = widget.engine;
    final maxMs = (engine.duration?.inMilliseconds ?? 0).toDouble();
    final positionMs = _dragMs ?? engine.position.inMilliseconds.toDouble();
    final value = maxMs > 0 ? positionMs.clamp(0, maxMs).toDouble() : 0.0;
    final labels = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(_formatMs(value), style: theme.textTheme.bodySmall),
          Text(maxMs > 0 ? _formatMs(maxMs) : '--:--',
              style: theme.textTheme.bodySmall),
        ],
      ),
    );

    if (!engine.isHost) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: maxMs > 0 ? value / maxMs : 0,
                minHeight: 4,
              ),
            ),
          ),
          labels,
        ],
      );
    }

    return Column(
      children: [
        Slider(
          value: value,
          max: maxMs > 0 ? maxMs : 1,
          onChanged: maxMs > 0 ? (v) => setState(() => _dragMs = v) : null,
          onChangeEnd: maxMs > 0
              ? (v) {
                  setState(() => _dragMs = null);
                  engine.seek(Duration(milliseconds: v.round()));
                }
              : null,
        ),
        labels,
      ],
    );
  }

  Widget _buildControls(ThemeData theme) {
    final engine = widget.engine;
    final status = engine.status;
    final playing = status == PartySyncStatus.playing;

    if (!engine.isHost) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            playing ? Icons.graphic_eq : Icons.pause_circle_outline,
            size: 20,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'Controla ${engine.hostName ?? 'el anfitrión'}',
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      );
    }

    final canPlay = switch (status) {
      PartySyncStatus.waitingGuests =>
        engine.guests.isNotEmpty || engine.expectedGuestCount == 0,
      _ => engine.queue.isNotEmpty,
    };
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: 'Anterior',
          iconSize: 32,
          onPressed: engine.started ? engine.previous : null,
          icon: const Icon(Icons.skip_previous),
        ),
        const SizedBox(width: 16),
        IconButton.filled(
          tooltip: playing ? 'Pausar' : 'Reproducir',
          iconSize: 44,
          onPressed: canPlay ? engine.togglePlayPause : null,
          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
        ),
        const SizedBox(width: 16),
        IconButton(
          tooltip: 'Siguiente',
          iconSize: 32,
          onPressed:
              engine.started && engine.currentIndex < engine.queue.length - 1
                  ? engine.next
                  : null,
          icon: const Icon(Icons.skip_next),
        ),
      ],
    );
  }

  Widget _buildActions() {
    final engine = widget.engine;
    final status = engine.status;
    final buttons = <Widget>[
      if (engine.isHost) ...[
        if (status == PartySyncStatus.waitingGuests)
          FilledButton.tonalIcon(
            onPressed: engine.guests.isEmpty && engine.expectedGuestCount > 0
                ? null
                : engine.startWithConnectedGuestsNow,
            icon: const Icon(Icons.play_arrow),
            label: Text(engine.expectedGuestCount == 0
                ? 'Empezar ahora'
                : 'Empezar con los que ya están'),
          ),
        if (status == PartySyncStatus.preparing &&
            engine.guestsNotReady.isNotEmpty)
          FilledButton.tonalIcon(
            onPressed: engine.startWithoutWaiting,
            icon: const Icon(Icons.fast_forward),
            label: const Text('Empezar sin esperar'),
          ),
        OutlinedButton.icon(
          onPressed: widget.onAddSongs,
          icon: const Icon(Icons.playlist_add),
          label: const Text('Agregar canciones'),
        ),
        if (engine.started && engine.guests.isNotEmpty)
          OutlinedButton.icon(
            onPressed: engine.resync,
            icon: const Icon(Icons.sync),
            label: const Text('Resincronizar invitados'),
          ),
        _KaraokeButton(engine: engine),
        OutlinedButton.icon(
          onPressed: widget.onExit,
          icon: const Icon(Icons.stop),
          label: const Text('Terminar sesión'),
        ),
      ] else ...[
        if (status != PartySyncStatus.disconnected &&
            status != PartySyncStatus.connecting)
          FilledButton.tonalIcon(
            onPressed: widget.onAddSongs,
            icon: const Icon(Icons.playlist_add),
            label: const Text('Agregar canciones'),
          ),
        if (status == PartySyncStatus.disconnected)
          FilledButton.icon(
            onPressed: engine.resync,
            icon: const Icon(Icons.bluetooth_searching),
            label: const Text('Reconectar'),
          )
        else
          OutlinedButton.icon(
            onPressed:
                status == PartySyncStatus.connecting ? null : engine.resync,
            icon: const Icon(Icons.sync),
            label: const Text('Resincronizar'),
          ),
        _KaraokeButton(engine: engine),
        OutlinedButton.icon(
          onPressed: widget.onExit,
          icon: const Icon(Icons.logout),
          label: const Text('Salir'),
        ),
      ],
    ];
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: buttons,
    );
  }
}

String _formatMs(double ms) {
  final total = Duration(milliseconds: ms.round());
  final minutes = total.inMinutes;
  final seconds = total.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String _percent(double value) => '${(value * 100).clamp(0, 100).round()}%';

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );
}

class _TrackArtwork extends StatelessWidget {
  const _TrackArtwork({required this.track, required this.size});

  final SyncTrack? track;
  final double size;

  @override
  Widget build(BuildContext context) {
    final radius = size * 0.16;
    final art = track?.artwork;
    if (art != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Image.memory(
          art,
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );
    }
    final songId = track?.songId;
    if (songId != null) {
      return SongArtwork(songId: songId, size: size, borderRadius: radius);
    }
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(Icons.music_note,
          size: size * 0.5, color: scheme.onSurfaceVariant),
    );
  }
}

class _NowPlayingHeader extends StatelessWidget {
  const _NowPlayingHeader({required this.track});

  final SyncTrack? track;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final current = track;
    return Row(
      children: [
        _TrackArtwork(track: current, size: 112),
        const SizedBox(width: 16),
        Expanded(
          child: current == null
              ? Text('Todavía no hay nada sonando',
                  style: theme.textTheme.titleMedium)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      current.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge,
                    ),
                    if ((current.artist ?? '').isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(current.artist!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muted),
                    ],
                    if ((current.album ?? '').isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.album,
                              size: 16,
                              color: theme.colorScheme.onSurfaceVariant),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              current.album!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

/// Estado de la sesión y de la transferencia de la canción actual (con
/// porcentaje): del lado invitado lo que le va llegando; del lado anfitrión,
/// a quién le falta todavía.
class _StatusPanel extends StatelessWidget {
  const _StatusPanel({required this.engine});

  final PartySyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final track = engine.currentTrack;
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    final transfer = <Widget>[];
    if (track != null &&
        engine.isGuest &&
        track.localPath == null &&
        engine.started) {
      final progress = engine.trackProgress(track);
      transfer.add(_ProgressLine(
        label: engine.isStreamingCurrent
            ? 'Sonando mientras termina de llegar · ${_percent(progress)}'
            : 'Recibiendo la canción · ${_percent(progress)}',
        value: progress,
      ));
    }
    final waiting = engine.isHost ? engine.waitingUploadTrack : null;
    if (waiting != null) {
      final progress = engine.uploadProgress(waiting) ?? 0;
      transfer.add(_ProgressLine(
        label: 'Esperando que ${waiting.addedBy ?? 'el invitado'} termine de '
            'mandar "${waiting.title}" · ${_percent(progress)}',
        value: progress,
      ));
    } else if (track != null &&
        engine.isHost &&
        engine.status == PartySyncStatus.preparing) {
      for (final guest in engine.guestsNotReady) {
        final progress = engine.guestProgress(guest, track);
        final detail = guest.sendingTrackId == track.id
            ? 'recibiendo · ${_percent(progress)}'
            : guest.hasTracks.contains(track.id)
                ? 'cargando...'
                : 'en cola';
        transfer.add(_ProgressLine(
          label: '${guest.name}: $detail',
          value: guest.sendingTrackId == track.id ? progress : null,
        ));
      }
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_statusIcon(engine.status),
                  size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(_statusLabel(engine),
                      style: theme.textTheme.bodyMedium)),
            ],
          ),
          if (engine.statusMessage != null) ...[
            const SizedBox(height: 4),
            Text(engine.statusMessage!, style: muted),
          ],
          for (final line in transfer) ...[const SizedBox(height: 8), line],
        ],
      ),
    );
  }

  static IconData _statusIcon(PartySyncStatus status) => switch (status) {
        PartySyncStatus.playing => Icons.graphic_eq,
        PartySyncStatus.paused => Icons.pause,
        PartySyncStatus.preparing => Icons.hourglass_top,
        PartySyncStatus.finished => Icons.check_circle_outline,
        PartySyncStatus.disconnected => Icons.bluetooth_disabled,
        _ => Icons.bluetooth_searching,
      };

  static String _statusLabel(PartySyncEngine engine) {
    final others = engine.connectedGuestCount;
    return switch (engine.status) {
      PartySyncStatus.idle => '',
      PartySyncStatus.connecting => 'Conectando...',
      PartySyncStatus.waitingGuests => engine.expectedGuestCount == 0
          ? (others == 0
              ? 'Esperando invitados'
              : '$others ${others == 1 ? 'invitado conectado' : 'invitados conectados'}')
          : 'Esperando invitados ($others/${engine.expectedGuestCount})',
      PartySyncStatus.waitingHost => 'Esperando al anfitrión',
      PartySyncStatus.preparing => engine.isHost
          ? 'Preparando la canción en los invitados'
          : 'Preparando la canción',
      PartySyncStatus.playing => engine.isHost
          ? (others == 0
              ? 'Sonando (sin invitados conectados)'
              : 'Sonando en ${others + 1} dispositivos a la vez')
          : 'Sonando en sincronía con ${engine.hostName ?? 'el anfitrión'}',
      PartySyncStatus.paused => 'En pausa',
      PartySyncStatus.finished => 'Terminó la lista',
      PartySyncStatus.disconnected => 'Desconectado del anfitrión',
    };
  }
}

class _ProgressLine extends StatelessWidget {
  const _ProgressLine({required this.label, required this.value});

  final String label;
  final double? value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: value, minHeight: 6),
        ),
      ],
    );
  }
}

class _GuestTile extends StatelessWidget {
  const _GuestTile({required this.engine, required this.guest});

  final PartySyncEngine engine;
  final GuestInfo guest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = engine.currentTrack;
    final ready = current != null && guest.preparedTrackId == current.id;
    SyncTrack? sending;
    for (final track in engine.queue) {
      if (track.id == guest.sendingTrackId) sending = track;
    }
    final String subtitle;
    if (sending != null) {
      subtitle =
          'Recibiendo "${sending.title}" · ${_percent(guest.sendingProgress)}';
    } else if (engine.queue.every((t) => guest.hasTracks.contains(t.id))) {
      subtitle = 'Tiene toda la lista';
    } else {
      subtitle = ready ? 'Listo' : 'Conectado';
    }
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        ready ? Icons.check_circle : Icons.bluetooth_connected,
        color: ready
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(guest.name),
      subtitle: Text(subtitle),
    );
  }
}

class _QueueTile extends StatelessWidget {
  const _QueueTile(
      {required this.engine, required this.track, required this.index});

  final PartySyncEngine engine;
  final SyncTrack track;
  final int index;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCurrent = index == engine.currentIndex && engine.started;
    final details = [
      track.artist,
      track.album,
      if (track.featuresSummary != null) track.featuresSummary,
      if (track.addedBy != null) 'agregó ${track.addedBy}',
    ].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    final upload = engine.uploadProgress(track);
    final showTransfer =
        upload != null || engine.isGuest || engine.guests.isNotEmpty;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      selected: isCurrent,
      selectedTileColor:
          theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
      leading: Stack(
        alignment: Alignment.center,
        children: [
          _TrackArtwork(track: track, size: 44),
          if (isCurrent)
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(44 * 0.16),
              ),
              child:
                  const Icon(Icons.graphic_eq, color: Colors.white, size: 22),
            ),
        ],
      ),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: isCurrent ? const TextStyle(fontWeight: FontWeight.w600) : null,
      ),
      subtitle: details.isEmpty
          ? null
          : Text(details, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showTransfer)
            upload != null
                ? _TransferBadge(progress: upload, uploading: true)
                : _TransferBadge(progress: engine.trackProgress(track)),
          if (engine.isHost && index != engine.currentIndex)
            IconButton(
              tooltip: 'Quitar de la lista',
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => engine.removeTrack(index),
            ),
        ],
      ),
      onTap: engine.isHost ? () => engine.playIndex(index) : null,
    );
  }
}

/// Título de la lista compartida. El anfitrión tiene "Mezclar" (orden al
/// azar de lo que viene) y "Ordenar" (se mantiene solo cuando alguien
/// agrega canciones); los invitados ven cómo está ordenada.
class _QueueHeader extends StatelessWidget {
  const _QueueHeader({required this.engine});

  final PartySyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sorted = engine.sortMode != QueueSortMode.none;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Lista de reproducción (${engine.queue.length})',
                  style: theme.textTheme.titleMedium,
                ),
                if (engine.analyzingCount > 0)
                  Text(
                    'Analizando ritmo y tonalidad… faltan ${engine.analyzingCount}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.primary),
                  )
                else if (sorted)
                  Text(
                    'Ordenada por ${engine.sortMode.label.toLowerCase()} '
                    '(automático)',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          if (engine.isHost) ...[
            IconButton(
              tooltip: 'Mezclar lo que viene',
              icon: const Icon(Icons.shuffle),
              onPressed:
                  engine.queue.length < 2 ? null : engine.shuffleUpcoming,
            ),
            PopupMenuButton<QueueSortMode>(
              tooltip: 'Ordenar automáticamente',
              icon: Icon(
                Icons.sort,
                color: sorted ? theme.colorScheme.primary : null,
              ),
              onSelected: engine.setSortMode,
              itemBuilder: (context) => [
                for (final mode in QueueSortMode.values)
                  CheckedPopupMenuItem(
                    value: mode,
                    checked: engine.sortMode == mode,
                    child: Text(mode.label),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Cuánto de la canción ya está del otro lado: ✓, porcentaje o en cola.
class _TransferBadge extends StatelessWidget {
  const _TransferBadge({required this.progress, this.uploading = false});

  final double progress;

  /// Canción que agregó un invitado y todavía está subiendo al anfitrión.
  final bool uploading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (uploading) {
      return Tooltip(
        message: 'Subiendo al anfitrión',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.upload, size: 16, color: scheme.tertiary),
            const SizedBox(width: 2),
            Text(
              _percent(progress),
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(color: scheme.tertiary),
            ),
          ],
        ),
      );
    }
    if (progress >= 1) {
      return Tooltip(
        message: 'Ya llegó',
        child: Icon(Icons.download_done, size: 20, color: scheme.primary),
      );
    }
    if (progress <= 0) {
      return Tooltip(
        message: 'En cola',
        child: Icon(Icons.schedule, size: 18, color: scheme.onSurfaceVariant),
      );
    }
    return SizedBox(
      width: 44,
      child: Text(
        _percent(progress),
        textAlign: TextAlign.end,
        style: Theme.of(context)
            .textTheme
            .labelMedium
            ?.copyWith(color: scheme.primary),
      ),
    );
  }
}

class _SongPickerScreen extends StatefulWidget {
  const _SongPickerScreen(
      {required this.songs, this.initialSelection = const []});

  final List<Song> songs;
  final List<Song> initialSelection;

  @override
  State<_SongPickerScreen> createState() => _SongPickerScreenState();
}

class _SongPickerScreenState extends State<_SongPickerScreen> {
  String _query = '';
  // En el orden en que se fueron eligiendo: así queda la lista.
  late final List<Song> _selected = [...widget.initialSelection];

  @override
  Widget build(BuildContext context) {
    final results = _query.isEmpty
        ? widget.songs
        : widget.songs.where((s) {
            final text =
                '${s.title} ${s.artist ?? ''} ${s.album ?? ''}'.toLowerCase();
            return text.contains(_query.toLowerCase());
          }).toList();

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const AppLogo(size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Buscar canción',
                  border: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(_selected),
            child: Text('Listo (${_selected.length})'),
          ),
        ],
      ),
      body: ListView.builder(
        itemCount: results.length,
        itemBuilder: (context, index) {
          final song = results[index];
          final order = _selected.indexOf(song);
          return CheckboxListTile(
            value: order >= 0,
            title:
                Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: song.artist != null
                ? Text(song.artist!,
                    maxLines: 1, overflow: TextOverflow.ellipsis)
                : null,
            secondary: order >= 0
                ? CircleAvatar(radius: 14, child: Text('${order + 1}'))
                : const Icon(Icons.music_note),
            onChanged: (checked) => setState(() {
              if (checked ?? false) {
                _selected.add(song);
              } else {
                _selected.remove(song);
              }
            }),
          );
        },
      ),
    );
  }
}

/// Anfitrión por Wi-Fi: su dirección, por si un invitado no lo ve solo en
/// la lista (redes que bloquean los anuncios) y la tiene que escribir.
class _KaraokeButton extends StatelessWidget {
  const _KaraokeButton({required this.engine});

  final PartySyncEngine engine;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      avatar: const Icon(Icons.mic_external_on, size: 18),
      label: Text(engine.isHost ? 'Karaoke para todos' : 'Karaoke'),
      selected: engine.karaoke,
      onSelected: engine.setKaraoke,
    );
  }
}

/// Modo karaoke: la letra de lo que suena, grande y sincronizada.
class _KaraokePanel extends StatelessWidget {
  const _KaraokePanel({required this.engine});

  final PartySyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final track = engine.currentTrack;
    final lyrics = track?.lyrics;
    return Container(
      height: 340,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(20),
      ),
      child: lyrics == null || lyrics.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  track == null
                      ? 'El karaoke arranca con la primera canción'
                      : 'Buscando la letra de "${track.title}"…',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            )
          : LyricsView(
              lyrics: lyrics,
              position: engine.position,
              large: true,
              onSeek: engine.isHost ? engine.seek : null,
            ),
    );
  }
}

/// Botones para reaccionar: el emoji aparece en la pantalla de todos.
class _ReactionBar extends StatelessWidget {
  const _ReactionBar({required this.engine});

  final PartySyncEngine engine;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 4,
      children: [
        for (final emoji in syncReactionEmojis)
          IconButton(
            tooltip: 'Reaccionar',
            onPressed: () => engine.sendReaction(emoji),
            icon: Text(emoji, style: const TextStyle(fontSize: 26)),
          ),
      ],
    );
  }
}

/// Capa sobre toda la pantalla donde suben (y se desvanecen) las
/// reacciones de todos, con el nombre de quién la mandó.
class _ReactionOverlay extends StatefulWidget {
  const _ReactionOverlay({super.key, required this.reactions});

  final Stream<SyncReaction> reactions;

  @override
  State<_ReactionOverlay> createState() => _ReactionOverlayState();
}

class _FloatingReaction {
  _FloatingReaction(this.reaction, this.x, this.id);
  final SyncReaction reaction;
  final double x;
  final int id;
}

class _ReactionOverlayState extends State<_ReactionOverlay> {
  final _active = <_FloatingReaction>[];
  final _random = math.Random();
  StreamSubscription<SyncReaction>? _sub;
  var _nextId = 0;

  static const _lifetime = Duration(milliseconds: 2600);

  @override
  void initState() {
    super.initState();
    _sub = widget.reactions.listen((reaction) {
      if (!mounted) return;
      final floating = _FloatingReaction(
          reaction, 0.15 + _random.nextDouble() * 0.7, _nextId++);
      setState(() {
        _active.add(floating);
        // Tope, para que un aluvión de reacciones no trabe la pantalla.
        if (_active.length > 24) _active.removeAt(0);
      });
      Future<void>.delayed(_lifetime, () {
        if (mounted) setState(() => _active.remove(floating));
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        children: [
          for (final floating in _active)
            TweenAnimationBuilder<double>(
              key: ValueKey(floating.id),
              tween: Tween(begin: 0, end: 1),
              duration: _lifetime,
              curve: Curves.easeOut,
              builder: (context, t, child) => Positioned(
                left: constraints.maxWidth * floating.x - 30,
                top: constraints.maxHeight * (0.85 - 0.6 * t),
                child: Opacity(
                  opacity: t < 0.7 ? 1 : (1 - t) / 0.3,
                  child: Transform.scale(
                      scale: 0.6 + 0.6 * math.min(1, t * 3), child: child),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(floating.reaction.emoji,
                      style: const TextStyle(fontSize: 44)),
                  if (floating.reaction.from.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        floating.reaction.from,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 11),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Invitado por Wi-Fi: los anfitriones que se anuncian en la red, o una
/// dirección escrita a mano.
class _WifiGuestSetup extends StatefulWidget {
  const _WifiGuestSetup({
    required this.deviceName,
    required this.onScanQr,
    required this.onJoin,
  });

  final String deviceName;
  final VoidCallback onScanQr;
  final ValueChanged<PairedBluetoothDevice> onJoin;

  @override
  State<_WifiGuestSetup> createState() => _WifiGuestSetupState();
}

class _WifiGuestSetupState extends State<_WifiGuestSetup> {
  late final Stream<List<WifiHost>> _hosts = WifiSyncService.discoverHosts();
  final _manual = TextEditingController();

  @override
  void dispose() {
    _manual.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        ScanQrButton(onPressed: widget.onScanQr),
        const SizedBox(height: 20),
        Text('O elegí uno de tu red', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text('Aparecen solos cuando alguien inicia una sesión por Wi-Fi.',
            style: muted),
        const SizedBox(height: 8),
        StreamBuilder<List<WifiHost>>(
          stream: _hosts,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Text(
                'No se pudo buscar en la red (${snapshot.error}). Escribí la '
                'dirección del anfitrión abajo.',
                style: TextStyle(color: theme.colorScheme.error),
              );
            }
            final hosts = snapshot.data ?? const [];
            if (hosts.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Row(
                  children: [
                    SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 12),
                    Expanded(child: Text('Buscando…')),
                  ],
                ),
              );
            }
            return Column(
              children: [
                for (final host in hosts)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.speaker_group),
                      title: Text(host.name),
                      subtitle: Text(host.address),
                      trailing: const Icon(Icons.login),
                      onTap: () => widget.onJoin(
                        PairedBluetoothDevice(
                            name: host.name, address: host.address),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 24),
        Text('O escribí la dirección', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _manual,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  hintText: '192.168.1.20',
                  helperText: 'La muestra el anfitrión en su pantalla',
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: () {
                final address = _manual.text.trim();
                if (address.isEmpty) return;
                widget.onJoin(
                    PairedBluetoothDevice(name: address, address: address));
              },
              child: const Text('Conectarme'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          'Sin router, un teléfono puede compartir datos (zona Wi-Fi) y los demás '
          'conectarse a esa red. En Windows, la primera vez puede aparecer un '
          'aviso del firewall: permití el acceso para que la sesión funcione.',
          style: muted,
        ),
      ],
    );
  }
}

/// "Sincronía": cuánto está desfasado este invitado y el ajuste fino del
/// retraso del parlante de este dispositivo (se escucha el efecto en el
/// momento).
class _SyncTuningPanel extends StatelessWidget {
  const _SyncTuningPanel({required this.engine});

  final PartySyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final drift = engine.driftMs;
    final rtt = engine.clockRttMs;
    final latency = engine.latencyMs;
    final quality = drift == null
        ? null
        : drift.abs() <= 20
            ? ('Muy bien', Colors.green)
            : drift.abs() <= 60
                ? ('Ajustando', Colors.amber)
                : ('Desfasado', Colors.redAccent);
    Widget step(String label, int delta) => SizedBox(
          width: 52,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            ),
            onPressed: () => engine.setLatency(latency + delta),
            child: Text(label),
          ),
        );
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.graphic_eq, size: 18),
                const SizedBox(width: 8),
                Text('Sincronía', style: theme.textTheme.titleSmall),
                const Spacer(),
                if (engine.isGuest && quality != null)
                  Tooltip(
                    message: 'Diferencia con el anfitrión, medida cada '
                        '0,3 s. Se corrige sola.'
                        '${rtt == null ? '' : ' Reloj medido con $rtt ms de ida y vuelta.'}',
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.circle, size: 10, color: quality.$2),
                        const SizedBox(width: 6),
                        Text(
                            '${quality.$1} · ${drift! > 0 ? '+' : ''}$drift ms',
                            style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Si este dispositivo suena atrasado respecto a los demás (por '
              'ejemplo con un parlante o auriculares Bluetooth), subí el '
              'retraso; si suena adelantado, bajalo. Se escucha el cambio en '
              'el momento y queda guardado.',
              style: muted,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                step('−50', -50),
                const SizedBox(width: 4),
                step('−10', -10),
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        '${latency > 0 ? '+' : ''}$latency ms',
                        style: theme.textTheme.titleMedium?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()]),
                      ),
                      Text('retraso de este dispositivo', style: muted),
                    ],
                  ),
                ),
                step('+10', 10),
                const SizedBox(width: 4),
                step('+50', 50),
              ],
            ),
            if (latency != 0)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => engine.setLatency(0),
                  child: const Text('Volver a 0'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
