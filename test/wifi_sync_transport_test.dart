import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tk_music/services/bluetooth_sync_bridge.dart';
import 'package:tk_music/services/wifi_sync_transport.dart';

void main() {
  late Directory dir;
  late WifiSyncService host;
  late WifiSyncService guest;
  late List<BluetoothSyncEvent> hostEvents;
  late List<BluetoothSyncEvent> guestEvents;
  late String guestAddressOnHost;

  Future<T> waitFor<T extends BluetoothSyncEvent>(
      List<BluetoothSyncEvent> events,
      {bool Function(T)? where}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      for (final e in events) {
        if (e is T && (where == null || where(e))) return e;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw TimeoutException('No llegó $T');
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('wifi_sync_test');
    host = WifiSyncService(
      deviceName: 'PC anfitrión',
      receiveDir: () async => Directory('${dir.path}/host'),
      bindAddress: InternetAddress.loopbackIPv4,
      announce: false,
    );
    guest = WifiSyncService(
      deviceName: 'Teléfono invitado',
      receiveDir: () async => Directory('${dir.path}/guest'),
    );
    hostEvents = [];
    guestEvents = [];
    host.events.listen(hostEvents.add);
    guest.events.listen(guestEvents.add);
    await host.startHosting();
    await guest.connectToDevice('127.0.0.1:${host.hostingPort}');
    final connected = await waitFor<ConnectedEvent>(hostEvents);
    expect(connected.deviceName, 'Teléfono invitado');
    guestAddressOnHost = connected.address;
    final hostSeen = await waitFor<ConnectedEvent>(guestEvents);
    expect(hostSeen.deviceName, 'PC anfitrión');
  });

  tearDown(() async {
    await guest.disconnect();
    await host.disconnect();
    await dir.delete(recursive: true);
  });

  test('mensajes de control en los dos sentidos', () async {
    await guest.sendControl({'type': 'hello', 'have': []});
    final atHost = await waitFor<MessageEvent>(hostEvents);
    expect(atHost.payload['type'], 'hello');

    await host
        .sendControlTo(guestAddressOnHost, {'type': 'prepare', 'trackId': '7'});
    final atGuest = await waitFor<MessageEvent>(guestEvents);
    expect(atGuest.payload['trackId'], '7');
  });

  test('manda un archivo entero, con progreso, y llega idéntico', () async {
    final source = File('${dir.path}/tema.mp3');
    final content =
        Uint8List.fromList(List.generate(1500 * 1024, (i) => (i * 31) % 256));
    await source.writeAsBytes(content);

    await host.sendSongFileTo(
      address: guestAddressOnHost,
      path: source.path,
      title: 'Tema',
      artist: 'Artista',
      durationMs: 1000,
      transferId: '42',
      extra: {'trackId': '42'},
    );
    final started = await waitFor<FileStartedEvent>(guestEvents);
    expect(started.meta['extra'], {'trackId': '42'});
    final received = await waitFor<FileReceivedEvent>(guestEvents);
    expect(received.title, 'Tema');
    expect(received.artist, 'Artista');
    expect(await File(received.path).readAsBytes(), content);
    expect(guestEvents.whereType<FileProgressEvent>(), isNotEmpty);
    expect(hostEvents.whereType<SendProgressEvent>().last.sent, content.length);
  });

  test('los mensajes pasan mientras viaja un archivo', () async {
    final source = File('${dir.path}/grande.mp3');
    await source.writeAsBytes(Uint8List(6 * 1024 * 1024));
    final sending = host.sendSongFileTo(
      address: guestAddressOnHost,
      path: source.path,
      title: 'Grande',
      transferId: 'big',
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await host.sendControlTo(guestAddressOnHost, {'type': 'pause'});
    await waitFor<MessageEvent>(guestEvents,
        where: (e) => e.payload['type'] == 'pause');
    await sending;
    await waitFor<FileReceivedEvent>(guestEvents);
  });

  test('cancelar un envío avisa al otro lado y descarta el archivo', () async {
    final source = File('${dir.path}/cancelar.mp3');
    await source.writeAsBytes(Uint8List(20 * 1024 * 1024));
    final sending = host.sendSongFileTo(
      address: guestAddressOnHost,
      path: source.path,
      title: 'X',
      transferId: 'cut',
    );
    await waitFor<FileStartedEvent>(guestEvents);
    await host.cancelTransfer(guestAddressOnHost);
    await expectLater(
        sending,
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'CANCELLED')));
    final aborted = await waitFor<FileAbortedEvent>(guestEvents);
    expect(aborted.transferId, 'cut');
  });

  test('si el invitado se va, el anfitrión se entera', () async {
    await guest.disconnect();
    final gone = await waitFor<DisconnectedEvent>(hostEvents);
    expect(gone.address, guestAddressOnHost);
  });

  group('conexión del invitado', () {
    test('prueba cada dirección del QR hasta dar con el anfitrión', () async {
      final other = WifiSyncService(
        deviceName: 'Otro invitado',
        receiveDir: () async => Directory('${dir.path}/other'),
      );
      addTearDown(other.disconnect);
      // La primera no responde (puerto cerrado); la segunda es el anfitrión.
      await other.connectToDevice('127.0.0.1:1,127.0.0.1:${host.hostingPort}');
      final seen = await waitFor<ConnectedEvent>(hostEvents,
          where: (e) => e.deviceName == 'Otro invitado');
      expect(seen.address, isNot(guestAddressOnHost));
    });

    test(
        'si el anfitrión rechaza la conexión (sala llena) avisa, no se '
        'queda colgado', () async {
      final full = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(full.close);
      full.listen((socket) => socket.destroy());
      final other = WifiSyncService(
        deviceName: 'Otro invitado',
        receiveDir: () async => Directory('${dir.path}/other'),
      );
      addTearDown(other.disconnect);
      await expectLater(
        other.connectToDevice('127.0.0.1:${full.port}'),
        throwsA(isA<PlatformException>()
            .having((e) => e.message, 'message', contains('sala esté llena'))),
      );
    });

    test('si del otro lado no hay un anfitrión que salude, se corta', () async {
      final mute = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(mute.close);
      final sockets = <Socket>[];
      mute.listen(sockets.add);
      addTearDown(() {
        for (final s in sockets) {
          s.destroy();
        }
      });
      final other = WifiSyncService(
        deviceName: 'Otro invitado',
        receiveDir: () async => Directory('${dir.path}/other'),
        helloTimeout: const Duration(milliseconds: 300),
      );
      addTearDown(other.disconnect);
      await expectLater(
        other.connectToDevice('127.0.0.1:${mute.port}'),
        throwsA(isA<PlatformException>()
            .having((e) => e.message, 'message', contains('no respondió'))),
      );
    });
  });
}
