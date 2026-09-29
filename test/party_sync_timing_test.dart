import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/services/bluetooth_sync_bridge.dart';
import 'package:tk_music/services/party_sync_engine.dart';
import 'package:tk_music/services/wifi_sync_transport.dart';

/// Prueba de punta a punta de la sincronía: un anfitrión y un invitado de
/// verdad (reproductores mpv reales, conexión Wi-Fi por la red local de la
/// PC), con un audio en silencio (no suena nada). Mide cuánto se separan
/// las posiciones una vez que arrancó.
const _libmpv = r'build\windows\x64\runner\Debug\libmpv-2.dll';

/// WAV mono de 16 bits a 22 050 Hz en silencio.
File _silentWav(String path, int seconds) {
  const rate = 22050;
  final dataBytes = rate * 2 * seconds;
  final bytes = ByteData(44 + dataBytes);
  void text(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  bytes.setUint32(4, 36 + dataBytes, Endian.little);
  text(8, 'WAVEfmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, rate, Endian.little);
  bytes.setUint32(28, rate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  text(36, 'data');
  bytes.setUint32(40, dataBytes, Endian.little);
  return File(path)..writeAsBytesSync(bytes.buffer.asUint8List());
}

String Function()? _debug;

Future<void> _until(bool Function() condition, String what,
    {Duration timeout = const Duration(seconds: 20)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('No pasó: $what · ${_debug?.call() ?? ''}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  final hasMpv = Platform.isWindows && File(_libmpv).existsSync();

  test('el invitado queda alineado con el anfitrión a pocos ms', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    MediaKit.ensureInitialized(libmpv: File(_libmpv).absolute.path);
    final dir = await Directory.systemTemp.createTemp('sync_timing');
    addTearDown(() => dir.delete(recursive: true));
    // Carpetas de la app (letras, caché) dentro de la carpeta del test.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => dir.path);
    final wav =
        _silentWav('${dir.path}${Platform.pathSeparator}silencio.wav', 40);

    final hostTransport = WifiSyncService(
      deviceName: 'Anfitrión',
      bindAddress: InternetAddress.loopbackIPv4,
      announce: false,
      receiveDir: () async => Directory('${dir.path}/host'),
    );
    final guestTransport = WifiSyncService(
      deviceName: 'Invitado',
      receiveDir: () async => Directory('${dir.path}/guest'),
    );
    final host = PartySyncEngine(transport: hostTransport, localName: 'A');
    final guest = PartySyncEngine(transport: guestTransport, localName: 'B');
    addTearDown(() async {
      await guest.stop();
      await host.stop();
      guest.dispose();
      host.dispose();
    });

    _debug = () => 'anfitrión ${host.status} "${host.statusMessage}" invitados '
        '${host.guests.map((g) => '${g.name}:${g.preparedTrackId}')} · '
        'invitado ${guest.status} "${guest.statusMessage}"';
    await host.startAsHost([], [
      Song(
        mediaStoreId: 424242,
        title: 'Silencio',
        filePath: wav.path,
        duration: const Duration(seconds: 40),
      ),
    ]);
    await guest.joinAsGuest(PairedBluetoothDevice(
        name: 'Anfitrión', address: '127.0.0.1:${hostTransport.hostingPort}'));

    await _until(
        () =>
            host.guests.isNotEmpty &&
            guest.status == PartySyncStatus.waitingHost &&
            (guest.statusMessage ?? '').contains('Esperando'),
        'el invitado se conectó y midió el reloj');
    // Arranca: manda la canción, el invitado la prepara y suenan juntos.
    await host.togglePlayPause();
    await _until(
        () => guest.status == PartySyncStatus.playing, 'el invitado arrancó');

    // Unos segundos para que la corrección haga lo suyo.
    await Future<void>.delayed(const Duration(seconds: 4));
    final diffs = <int>[];
    for (var i = 0; i < 15; i++) {
      diffs.add(host.position.inMilliseconds - guest.position.inMilliseconds);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    diffs.sort();
    final median = diffs[diffs.length ~/ 2];
    // ignore: avoid_print
    print('Desfase anfitrión − invitado (ms): $diffs · mediana $median · '
        'el invitado mide ${guest.driftMs} ms · reloj ${guest.clockRttMs} ms');
    expect(median.abs(), lessThan(30));
    expect(diffs.last - diffs.first, lessThan(60));

    // Ajuste fino: este invitado "tiene un parlante 100 ms más lento", así
    // que su reproductor tiene que ir 100 ms adelante del anfitrión.
    await guest.setLatency(100);
    await Future<void>.delayed(const Duration(seconds: 5));
    final shifted = <int>[];
    for (var i = 0; i < 10; i++) {
      shifted.add(host.position.inMilliseconds - guest.position.inMilliseconds);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    shifted.sort();
    final shiftedMedian = shifted[shifted.length ~/ 2];
    // ignore: avoid_print
    print('Con +100 ms de retraso en el invitado: $shifted · mediana '
        '$shiftedMedian');
    expect((shiftedMedian + 100).abs(), lessThan(30));
  }, skip: !hasMpv, timeout: const Timeout(Duration(seconds: 90)));
}
