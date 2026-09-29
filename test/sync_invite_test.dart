import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:tk_music/services/bluetooth_sync_bridge.dart';
import 'package:tk_music/services/party_sync_engine.dart';
import 'package:tk_music/services/qr_image_decoder.dart';
import 'package:tk_music/services/sync_invite.dart';
import 'package:zxing2/qrcode.dart';

/// Un QR como lo mostraría la pantalla: negro sobre blanco, con margen y
/// opcionalmente con una imagen más grande alrededor (foto de la pantalla).
img.Image _qrImage(String text, {int scale = 6, int margin = 4}) {
  final matrix = Encoder.encode(text, ErrorCorrectionLevel.m).matrix!;
  final size = (matrix.width + margin * 2) * scale;
  final image = img.Image(width: size, height: size, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(255, 255, 255, 255));
  for (var x = 0; x < matrix.width; x++) {
    for (var y = 0; y < matrix.height; y++) {
      if (matrix.get(x, y) == 1) {
        img.fillRect(image,
            x1: (x + margin) * scale,
            y1: (y + margin) * scale,
            x2: (x + margin) * scale + scale - 1,
            y2: (y + margin) * scale + scale - 1,
            color: img.ColorRgba8(0, 0, 0, 255));
      }
    }
  }
  return image;
}

void main() {
  group('invitación', () {
    test('Wi-Fi: ida y vuelta con varias direcciones y nombre con espacios',
        () {
      const invite = SyncInvite(
        transport: InviteTransport.wifi,
        room: 'Fiesta de Ana',
        addresses: ['192.168.1.20', '10.0.0.5'],
        port: 47810,
      );
      final text = invite.encode();
      expect(text, startsWith('tkmusic://join?'));
      final read = SyncInvite.parse(text)!;
      expect(read.transport, InviteTransport.wifi);
      expect(read.room, 'Fiesta de Ana');
      expect(read.addresses, ['192.168.1.20', '10.0.0.5']);
      expect(read.port, 47810);
    });

    test('Bluetooth: nombre y dirección', () {
      const invite = SyncInvite(
        transport: InviteTransport.bluetooth,
        room: 'Fiesta',
        bluetoothName: 'Galaxy A54 de Ana',
        bluetoothAddress: 'AA:BB:CC:DD:EE:FF',
      );
      final read = SyncInvite.parse(invite.encode())!;
      expect(read.transport, InviteTransport.bluetooth);
      expect(read.bluetoothName, 'Galaxy A54 de Ana');
      expect(read.bluetoothAddress, 'AA:BB:CC:DD:EE:FF');
      expect(read.bluetoothChannel, isNull);
    });

    test('Bluetooth: el canal del anfitrión Windows viaja en el QR', () {
      const invite = SyncInvite(
        transport: InviteTransport.bluetooth,
        room: 'Fiesta',
        bluetoothName: 'DESKTOP-8SNTMTD',
        bluetoothAddress: '00:11:22:33:44:55',
        bluetoothChannel: 22,
      );
      expect(SyncInvite.parse(invite.encode())!.bluetoothChannel, 22);
      // Un canal fuera de 1–30 se ignora.
      expect(
          SyncInvite.parse('tkmusic://join?t=bt&b=PC&c=99')!.bluetoothChannel,
          isNull);
    });

    test('el aviso de error dice qué revisar y el motivo', () {
      final message = bluetoothConnectFailedMessage(
        'DESKTOP-8SNTMTD',
        PlatformException(
            code: 'CONNECT_FAILED',
            message: 'servicio: read failed | canal 22: Connection refused'),
      );
      expect(message, contains('anfitrión por Bluetooth'));
      expect(message, contains('vinculados'));
      expect(message, contains('Detalle: servicio: read failed'));
    });

    test('los avisos de Wi-Fi no hablan de Bluetooth', () {
      final connect = wifiConnectFailedMessage(
        'Sala de Ana',
        PlatformException(
            code: 'CONNECT_FAILED',
            message: '192.168.1.5:47810: Connection refused'),
      );
      expect(connect, contains('misma red Wi-Fi'));
      expect(connect, contains('firewall'));
      expect(connect, contains('Detalle: 192.168.1.5:47810'));
      expect(connect, isNot(contains('vinculados')));
      final host = wifiHostFailedMessage(const SocketException('sin red'));
      expect(host, contains('red Wi-Fi'));
      expect(host.toLowerCase(), isNot(contains('bluetooth')));
    });

    test('rechaza QR que no son de TK Music o vienen incompletos', () {
      expect(SyncInvite.parse('https://example.com'), isNull);
      expect(SyncInvite.parse('hola'), isNull);
      expect(SyncInvite.parse(null), isNull);
      expect(SyncInvite.parse('tkmusic://join?t=wifi&n=x'), isNull);
      expect(SyncInvite.parse('tkmusic://join?t=wifi&h=999.1.1.1'), isNull);
      expect(SyncInvite.parse('tkmusic://join?t=bt&n=x'), isNull);
      expect(SyncInvite.parse('tkmusic://join?t=otro&h=1.2.3.4'), isNull);
    });
  });

  test('elige la dirección del anfitrión que está en la misma red', () {
    expect(pickHostAddress(['10.0.0.5', '192.168.1.20'], ['192.168.1.33']),
        '192.168.1.20');
    expect(pickHostAddress(['10.0.0.5', '192.168.1.20'], ['172.16.0.2']),
        '10.0.0.5');
  });

  test('encuentra al anfitrión entre los emparejados', () {
    const paired = [
      PairedBluetoothDevice(name: 'Auriculares', address: '11:11:11:11:11:11'),
      PairedBluetoothDevice(name: 'Galaxy A54', address: 'AA:BB:CC:DD:EE:FF'),
    ];
    // Desde Windows: por dirección, aunque el nombre no coincida.
    expect(
        findInvitedHost(
                const SyncInvite(
                    transport: InviteTransport.bluetooth,
                    room: 'x',
                    bluetoothName: 'OTRO',
                    bluetoothAddress: 'aa:bb:cc:dd:ee:ff'),
                paired)
            ?.name,
        'Galaxy A54');
    // Desde Android: solo el nombre, sin importar mayúsculas.
    expect(
        findInvitedHost(
                const SyncInvite(
                    transport: InviteTransport.bluetooth,
                    room: 'x',
                    bluetoothName: 'galaxy a54'),
                paired)
            ?.address,
        'AA:BB:CC:DD:EE:FF');
    expect(
        findInvitedHost(
            const SyncInvite(
                transport: InviteTransport.bluetooth,
                room: 'x',
                bluetoothName: 'No emparejado'),
            paired),
        isNull);
  });

  group('leer el QR de una imagen (escáner de Windows)', () {
    final text = const SyncInvite(
      transport: InviteTransport.wifi,
      room: 'Fiesta',
      addresses: ['192.168.1.20'],
      port: 47810,
    ).encode();

    test('PNG limpio', () {
      final png = img.encodePng(_qrImage(text));
      expect(decodeQrImage(png), text);
    });

    test('foto JPEG más grande, con el QR en una parte', () {
      final qr = _qrImage(text, scale: 5);
      final photo = img.Image(width: 1600, height: 1200, numChannels: 4);
      img.fill(photo, color: img.ColorRgba8(60, 60, 70, 255));
      img.compositeImage(photo, qr, dstX: 500, dstY: 300);
      final jpg = img.encodeJpg(photo, quality: 80);
      expect(decodeQrImage(jpg), text);
    });

    test('imagen sin QR', () {
      final blank = img.Image(width: 200, height: 200);
      expect(decodeQrImage(img.encodePng(blank)), isNull);
    });
  });
}
