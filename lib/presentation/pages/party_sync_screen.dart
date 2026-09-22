import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/presentation/widgets/app_providers.dart';
import 'package:tk_music/services/bluetooth_sync_bridge.dart';
import 'package:tk_music/services/party_sync_engine.dart';

enum _Step { chooseRole, hostSetup, guestSetup }

/// Sincroniza la reproducción de una canción entre este teléfono y otro ya
/// emparejado por Bluetooth: el anfitrión manda el archivo y controla
/// play/pause; el invitado solo escucha en espejo. Sesión aparte y en
/// primer plano (pausa el reproductor principal al entrar), igual que el
/// Mezclador automático.
class PartySyncScreen extends StatefulWidget {
  const PartySyncScreen({super.key});

  @override
  State<PartySyncScreen> createState() => _PartySyncScreenState();
}

class _PartySyncScreenState extends State<PartySyncScreen> {
  final _engine = PartySyncEngine();
  _Step _step = _Step.chooseRole;
  List<PairedBluetoothDevice>? _devices;
  SyncCapacity? _capacity;
  final Set<String> _activeAddresses = {};
  StreamSubscription<BluetoothSyncEvent>? _aclSub;
  final List<PairedBluetoothDevice> _selectedGuestDevices = [];
  PairedBluetoothDevice? _selectedHostDevice;
  Song? _selectedSong;
  String? _permissionError;

  @override
  void initState() {
    super.initState();
    if (isAudioAvailable) sl<AudioHandler>().pause();
  }

  @override
  void dispose() {
    _aclSub?.cancel();
    _engine.dispose();
    super.dispose();
  }

  Future<void> _loadDevices() async {
    final status = await Permission.bluetoothConnect.request();
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
      appBar: AppBar(title: const Text('Sincronizar con otro teléfono')),
      body: AnimatedBuilder(
        animation: _engine,
        builder: (context, _) {
          if (_engine.status != PartySyncStatus.idle) {
            return _SessionView(engine: _engine, onExit: _exitSession);
          }
          return switch (_step) {
            _Step.chooseRole => _RoleChoice(
                onHost: () {
                  setState(() => _step = _Step.hostSetup);
                  _loadDevices();
                },
                onGuest: () {
                  setState(() => _step = _Step.guestSetup);
                  _loadDevices();
                },
              ),
            _Step.hostSetup => _HostSetup(
                devices: _devices,
                capacity: _capacity,
                activeAddresses: _activeAddresses,
                permissionError: _permissionError,
                selectedDevices: _selectedGuestDevices,
                selectedSong: _selectedSong,
                onDevicesChanged: (d) => setState(() {
                  _selectedGuestDevices
                    ..clear()
                    ..addAll(d);
                }),
                onPickSong: _pickSong,
                onStart: _startHost,
              ),
            _Step.guestSetup => _GuestSetup(
                devices: _devices,
                capacity: _capacity,
                activeAddresses: _activeAddresses,
                permissionError: _permissionError,
                selectedDevice: _selectedHostDevice,
                onDeviceChanged: (d) => setState(() => _selectedHostDevice = d),
                onJoin: _joinAsGuest,
              ),
          };
        },
      ),
    );
  }

  Future<void> _pickSong() async {
    final songs = AppProviders.songOf(context).songs;
    final picked = await Navigator.of(context).push<Song>(
      MaterialPageRoute(builder: (_) => _SongPickerScreen(songs: songs)),
    );
    if (picked != null) setState(() => _selectedSong = picked);
  }

  Future<void> _startHost() async {
    final devices = _selectedGuestDevices;
    final song = _selectedSong;
    if (devices.isEmpty || song == null) return;
    await _engine.startAsHost(devices, song);
  }

  Future<void> _joinAsGuest() async {
    final device = _selectedHostDevice;
    if (device == null) return;
    await _engine.joinAsGuest(device);
  }

  Future<void> _exitSession() async {
    await _engine.stop();
    setState(() {
      _step = _Step.chooseRole;
      _selectedGuestDevices.clear();
      _selectedHostDevice = null;
      _selectedSong = null;
    });
  }
}

class _RoleChoice extends StatelessWidget {
  const _RoleChoice({required this.onHost, required this.onGuest});

  final VoidCallback onHost;
  final VoidCallback onGuest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.bluetooth_audio, size: 48, color: theme.colorScheme.primary),
          const SizedBox(height: 12),
          Text(
            'Elegí un rol para sincronizar la música con otro teléfono ya '
            'emparejado por Bluetooth.',
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
        ],
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
    required this.devices,
    required this.capacity,
    required this.activeAddresses,
    required this.permissionError,
    required this.selectedDevices,
    required this.selectedSong,
    required this.onDevicesChanged,
    required this.onPickSong,
    required this.onStart,
  });

  final List<PairedBluetoothDevice>? devices;
  final SyncCapacity? capacity;
  final Set<String> activeAddresses;
  final String? permissionError;
  final List<PairedBluetoothDevice> selectedDevices;
  final Song? selectedSong;
  final ValueChanged<List<PairedBluetoothDevice>> onDevicesChanged;
  final VoidCallback onPickSong;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CapacityNotice(capacity: capacity, guestMode: false),
          const SizedBox(height: 12),
          Text(
            '1. Elegí hasta ${PartySyncEngine.maxGuests} invitados',
            style: theme.textTheme.titleMedium,
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
          Text('2. Elegí la canción', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.music_note),
            title: Text(selectedSong?.title ?? 'Ninguna canción elegida'),
            trailing: TextButton(onPressed: onPickSong, child: const Text('Elegir')),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: selectedDevices.isEmpty || selectedSong == null
                ? null
                : onStart,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Iniciar sincronización'),
          ),
          const SizedBox(height: 12),
          Text(
            'Cada invitado tiene que tener esta misma app abierta en "Unirme '
            'a una sesión" antes de iniciar. La sincronización arranca sola '
            'apenas se conectan todos los que elegiste, o podés arrancarla '
            'con los que ya están conectados desde la pantalla siguiente.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
    required this.devices,
    required this.capacity,
    required this.activeAddresses,
    required this.permissionError,
    required this.selectedDevice,
    required this.onDeviceChanged,
    required this.onJoin,
  });

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
          Text('Elegí el teléfono anfitrión',
              style: theme.textTheme.titleMedium),
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

class _SessionView extends StatelessWidget {
  const _SessionView({required this.engine, required this.onExit});

  final PartySyncEngine engine;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = engine.status;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              status == PartySyncStatus.playing
                  ? Icons.graphic_eq
                  : Icons.bluetooth_searching,
              size: 48,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            if (engine.currentTitle != null) ...[
              Text(engine.currentTitle!,
                  textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
              if (engine.currentArtist != null)
                Text(engine.currentArtist!,
                    textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 16),
            ],
            Text(
              engine.statusMessage ?? _labelFor(status),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            if (status == PartySyncStatus.transferringFile) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: engine.transferProgress),
            ],
            if (engine.isHost && engine.guests.isNotEmpty) ...[
              const SizedBox(height: 16),
              _GuestsList(guests: engine.guests),
            ],
            if (engine.isHost && status == PartySyncStatus.waitingConnection) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: engine.guests.isEmpty
                    ? null
                    : engine.startWithConnectedGuestsNow,
                icon: const Icon(Icons.fast_forward),
                label: const Text('Empezar con los que ya están'),
              ),
            ],
            const SizedBox(height: 24),
            if (status == PartySyncStatus.playing ||
                status == PartySyncStatus.paused)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (engine.isHost) ...[
                    IconButton.filled(
                      iconSize: 40,
                      onPressed: engine.togglePlayPause,
                      icon: Icon(status == PartySyncStatus.playing
                          ? Icons.pause
                          : Icons.play_arrow),
                    ),
                    const SizedBox(width: 20),
                  ],
                  IconButton.filledTonal(
                    iconSize: 32,
                    onPressed: onExit,
                    icon: const Icon(Icons.stop),
                  ),
                ],
              )
            else
              OutlinedButton.icon(
                onPressed: onExit,
                icon: const Icon(Icons.close),
                label: const Text('Cancelar'),
              ),
          ],
        ),
      ),
    );
  }

  String _labelFor(PartySyncStatus status) => switch (status) {
        PartySyncStatus.idle => '',
        PartySyncStatus.waitingConnection => 'Conectando...',
        PartySyncStatus.connected => 'Conectado',
        PartySyncStatus.transferringFile => 'Transfiriendo la canción...',
        PartySyncStatus.syncingClock => 'Sincronizando reloj...',
        PartySyncStatus.waitingStart => 'Por arrancar...',
        PartySyncStatus.playing => 'Sonando en todos los teléfonos',
        PartySyncStatus.paused => 'Pausado',
        PartySyncStatus.finished => 'Terminado',
        PartySyncStatus.error => 'Hubo un problema',
      };
}

class _GuestsList extends StatelessWidget {
  const _GuestsList({required this.guests});

  final List<GuestInfo> guests;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        for (final guest in guests)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  guest.ready ? Icons.check_circle : Icons.bluetooth_connected,
                  size: 18,
                  color: guest.ready
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  guest.name,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SongPickerScreen extends StatefulWidget {
  const _SongPickerScreen({required this.songs});

  final List<Song> songs;

  @override
  State<_SongPickerScreen> createState() => _SongPickerScreenState();
}

class _SongPickerScreenState extends State<_SongPickerScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final results = _query.isEmpty
        ? widget.songs
        : widget.songs.where((s) {
            final text = '${s.title} ${s.artist ?? ''}'.toLowerCase();
            return text.contains(_query.toLowerCase());
          }).toList();

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Buscar canción',
            border: InputBorder.none,
          ),
          onChanged: (v) => setState(() => _query = v),
        ),
      ),
      body: ListView.builder(
        itemCount: results.length,
        itemBuilder: (context, index) {
          final song = results[index];
          return ListTile(
            leading: const Icon(Icons.music_note),
            title: Text(song.title),
            subtitle: song.artist != null ? Text(song.artist!) : null,
            onTap: () => Navigator.of(context).pop(song),
          );
        },
      ),
    );
  }
}
