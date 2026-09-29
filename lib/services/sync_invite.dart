import 'bluetooth_sync_bridge.dart';

/// Por dónde se une el invitado.
enum InviteTransport { wifi, bluetooth }

/// Lo que va adentro del QR de "Unirse con QR": cómo encontrar al anfitrión
/// y el nombre de la sala. Por Wi-Fi, sus direcciones en la red; por
/// Bluetooth, el nombre (y en Windows la dirección) de su Bluetooth, para
/// ubicarlo entre los emparejados del invitado.
///
/// Se codifica como `tkmusic://join?...`: si lo escanea otra app de QR no
/// abre nada raro, y TK Music ignora cualquier QR que no sea suyo.
class SyncInvite {
  const SyncInvite({
    required this.transport,
    required this.room,
    this.addresses = const [],
    this.port,
    this.bluetoothName,
    this.bluetoothAddress,
    this.bluetoothChannel,
  });

  final InviteTransport transport;
  final String room;

  /// Wi-Fi: IPv4 del anfitrión (puede tener varias: Wi-Fi, hotspot…).
  final List<String> addresses;
  final int? port;

  /// Bluetooth: nombre del adaptador del anfitrión. La dirección solo la
  /// conoce Windows (Android no deja a las apps leer la propia).
  final String? bluetoothName;
  final String? bluetoothAddress;

  /// Bluetooth: canal RFCOMM del anfitrión (solo Windows lo sabe). El
  /// invitado lo prueba directo si no encuentra el servicio por SDP.
  final int? bluetoothChannel;

  static const _scheme = 'tkmusic';

  String encode() => Uri(
        scheme: _scheme,
        host: 'join',
        queryParameters: {
          'v': '1',
          't': transport == InviteTransport.wifi ? 'wifi' : 'bt',
          'n': room,
          if (addresses.isNotEmpty) 'h': addresses.join(','),
          if (port != null) 'p': '$port',
          if (bluetoothName != null) 'b': bluetoothName!,
          if (bluetoothAddress != null) 'a': bluetoothAddress!,
          if (bluetoothChannel != null) 'c': '$bluetoothChannel',
        },
      ).toString();

  /// `null` si [text] no es una invitación de TK Music válida.
  static SyncInvite? parse(String? text) {
    final uri = Uri.tryParse(text?.trim() ?? '');
    if (uri == null || uri.scheme != _scheme || uri.host != 'join') {
      return null;
    }
    final q = uri.queryParameters;
    final room = (q['n'] ?? '').trim();
    switch (q['t']) {
      case 'wifi':
        final addresses = (q['h'] ?? '')
            .split(',')
            .map((a) => a.trim())
            .where(_isIpv4)
            .toList();
        if (addresses.isEmpty) return null;
        return SyncInvite(
          transport: InviteTransport.wifi,
          room: room,
          addresses: addresses,
          port: int.tryParse(q['p'] ?? ''),
        );
      case 'bt':
        final name = q['b']?.trim();
        final address = q['a']?.trim();
        if ((name == null || name.isEmpty) &&
            (address == null || address.isEmpty)) {
          return null;
        }
        return SyncInvite(
          transport: InviteTransport.bluetooth,
          room: room,
          bluetoothName: name == null || name.isEmpty ? null : name,
          bluetoothAddress: address == null || address.isEmpty ? null : address,
          bluetoothChannel: _channel(q['c']),
        );
      default:
        return null;
    }
  }

  static int? _channel(String? text) {
    final n = int.tryParse(text ?? '');
    return n != null && n >= 1 && n <= 30 ? n : null;
  }

  static bool _isIpv4(String text) {
    final parts = text.split('.');
    return parts.length == 4 &&
        parts.every((p) {
          final n = int.tryParse(p);
          return n != null && n >= 0 && n <= 255;
        });
  }
}

/// De las direcciones del anfitrión, la que está en la misma red que este
/// dispositivo (mismos tres primeros números); si ninguna coincide, la
/// primera.
String pickHostAddress(List<String> hostAddresses, List<String> ownAddresses) {
  String prefix(String ip) => ip.substring(0, ip.lastIndexOf('.'));
  final own = ownAddresses.where((a) => a.contains('.')).map(prefix).toSet();
  return hostAddresses.firstWhere((a) => own.contains(prefix(a)),
      orElse: () => hostAddresses.first);
}

/// El emparejado que corresponde al anfitrión de [invite]: por dirección si
/// vino, si no por nombre (primero exacto, después sin mayúsculas).
PairedBluetoothDevice? findInvitedHost(
    SyncInvite invite, List<PairedBluetoothDevice> paired) {
  final address = invite.bluetoothAddress?.toUpperCase();
  if (address != null) {
    for (final device in paired) {
      if (device.address.toUpperCase() == address) return device;
    }
  }
  final name = invite.bluetoothName;
  if (name == null) return null;
  for (final device in paired) {
    if (device.name == name) return device;
  }
  final lower = name.toLowerCase();
  for (final device in paired) {
    if (device.name.toLowerCase() == lower) return device;
  }
  return null;
}
