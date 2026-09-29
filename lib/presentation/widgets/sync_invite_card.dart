import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:tk_music/presentation/widgets/app_header.dart';
import 'package:tk_music/services/bluetooth_sync_bridge.dart';
import 'package:tk_music/services/sync_invite.dart';
import 'package:tk_music/services/wifi_sync_transport.dart';

/// "Unirse con QR" para el invitado.
class ScanQrButton extends StatelessWidget {
  const ScanQrButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.tonalIcon(
        onPressed: onPressed,
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Escanear el QR del anfitrión'),
      ),
    );
  }
}

/// El QR de la sala en la pantalla del anfitrión, para que los invitados se
/// unan escaneándolo. Por Wi-Fi lleva las direcciones del anfitrión en la
/// red; por Bluetooth, el nombre (y en Windows la dirección) de su
/// Bluetooth.
class SyncInviteCard extends StatefulWidget {
  const SyncInviteCard(
      {super.key, required this.wifi, required this.room, this.port});

  final bool wifi;
  final String room;

  /// Wi-Fi: el puerto en el que escucha el anfitrión (otro si el habitual
  /// estaba ocupado).
  final int? port;

  @override
  State<SyncInviteCard> createState() => _SyncInviteCardState();
}

class _SyncInviteCardState extends State<SyncInviteCard> {
  late final Future<SyncInvite?> _invite = _build();
  List<String> _addresses = const [];

  Future<SyncInvite?> _build() async {
    if (widget.wifi) {
      final addresses = await WifiSyncService.localAddresses();
      _addresses = addresses;
      if (addresses.isEmpty) return null;
      return SyncInvite(
        transport: InviteTransport.wifi,
        room: widget.room,
        addresses: addresses,
        port: widget.port ?? WifiSyncService.serverPort,
      );
    }
    final local = await BluetoothSyncService().localAdapter();
    if (local.name == null && local.address == null) return null;
    return SyncInvite(
      transport: InviteTransport.bluetooth,
      room: widget.room,
      bluetoothName: local.name,
      bluetoothAddress: local.address,
      bluetoothChannel: local.channel,
    );
  }

  void _showLarge(SyncInvite invite) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _QrBox(data: invite.encode(), size: 300),
              const SizedBox(height: 16),
              _RoomLabel(room: invite.room, large: true),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cerrar'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return FutureBuilder<SyncInvite?>(
      future: _invite,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox.shrink();
        }
        final invite = snapshot.data;
        if (invite == null) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              widget.wifi
                  ? 'No se encontró la dirección de este dispositivo en la '
                      'red: revisá que esté conectado al Wi-Fi.'
                  : 'No se pudo leer el nombre del Bluetooth de este '
                      'dispositivo para armar el QR.',
              style: muted,
            ),
          );
        }
        final bluetooth = invite.transport == InviteTransport.bluetooth;
        final details = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _RoomLabel(room: invite.room),
            const SizedBox(height: 8),
            Text(
              'Los invitados tocan "Unirse con QR" en Sincronizar con otro '
              'dispositivo y escanean este código.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 6),
            Text(
              bluetooth
                  ? 'Por Bluetooth tienen que tener emparejado este '
                      'dispositivo '
                      '(${invite.bluetoothName ?? invite.bluetoothAddress}).'
                  : 'Si no pueden escanear, que escriban: '
                      '${_addresses.join('  ·  ')}',
              style: muted,
            ),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: () => _showLarge(invite),
              icon: const Icon(Icons.fullscreen),
              label: const Text('Ver QR en grande'),
            ),
          ],
        );
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final qr = _QrBox(data: invite.encode(), size: 150);
                if (constraints.maxWidth < 420) {
                  return Column(
                    children: [qr, const SizedBox(height: 12), details],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    qr,
                    const SizedBox(width: 16),
                    Expanded(child: details),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// QR sobre fondo blanco: los lectores lo necesitan con buen contraste,
/// aunque la app esté en tema oscuro.
class _QrBox extends StatelessWidget {
  const _QrBox({required this.data, required this.size});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: QrImageView(
        data: data,
        size: size,
        padding: EdgeInsets.zero,
        backgroundColor: Colors.white,
        errorCorrectionLevel: QrErrorCorrectLevel.M,
        eyeStyle:
            const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black),
        dataModuleStyle: const QrDataModuleStyle(
            dataModuleShape: QrDataModuleShape.square, color: Colors.black),
      ),
    );
  }
}

class _RoomLabel extends StatelessWidget {
  const _RoomLabel({required this.room, this.large = false});

  final String room;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment:
          large ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const AppHeaderTitle(),
        const SizedBox(height: 4),
        Text(
          'Sala: $room',
          style:
              (large ? theme.textTheme.titleLarge : theme.textTheme.titleMedium)
                  ?.copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}
