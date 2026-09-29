import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tk_music/presentation/widgets/dj/dj_controller_dialogs.dart';
import 'package:tk_music/services/dj/dj_controller.dart';
import 'package:tk_music/services/dj/dj_deck.dart';
import 'package:tk_music/services/dj/dj_mixer.dart';
import 'package:tk_music/services/dj/midi_bridge.dart';

const _libmpv = r'build\windows\x64\runner\Debug\libmpv-2.dll';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final hasMpv = Platform.isWindows && File(_libmpv).existsSync();
  setUpAll(() {
    if (hasMpv) MediaKit.ensureInitialized(libmpv: File(_libmpv).absolute.path);
  });

  group('reconoce el controlador', () {
    test('por el nombre MIDI', () {
      expect(profileForMidiName('Mixtrack Pro 3'), mixtrackPro3);
      expect(profileForMidiName('2- MIXTRACK PRO 3'), mixtrackPro3);
      expect(profileForMidiName('Numark Mixtrack 3'), mixtrack3);
      expect(profileForMidiName('Launchpad Mini'), isNull);
      expect(profileForMidiName('Mixtrack Platinum'), isNull);
    });

    test('su placa de sonido', () {
      expect(mixtrackPro3.matchesAudio('Altavoces (Mixtrack Pro 3)'), isTrue);
      expect(mixtrackPro3.matchesAudio('Speakers (2- MixTrack Pro 3 Audio)'),
          isTrue);
      expect(
          mixtrackPro3.matchesAudio('Altavoces (Realtek(R) Audio)'), isFalse);
      expect(mixtrack3.hasSoundCard, isFalse);
    });

    test('las salidas de audio de mpv', () {
      final list = parseMpvAudioDevices('[{"name":"auto","description":'
          '"Autoselect device"},{"name":"wasapi/{0.0.0.00000000}.{abc}",'
          '"description":"Altavoces (Mixtrack Pro 3)"}]');
      expect(list, hasLength(1));
      expect(list.single.windowsId, '{0.0.0.00000000}.{abc}');
      expect(list.single.description, contains('Mixtrack'));
    });
  });

  group('perillas: el centro físico es 0 dB', () {
    const center = 64 / 127;
    test('ecualizador', () {
      expect(eqFromNorm(center), closeTo(0, 1e-9));
      expect(eqFromNorm(1), closeTo(6, 1e-9));
      expect(eqFromNorm(0), DjDeck.eqKill);
      for (final n in [0.0, 0.2, center, 0.8, 1.0]) {
        expect(eqToNorm(eqFromNorm(n)), closeTo(n, 1e-9));
      }
    });
    test('ganancia y general', () {
      expect(gainFromNorm(center), closeTo(0, 1e-9));
      expect(gainFromNorm(1), closeTo(12, 1e-9));
      expect(gainFromNorm(0), closeTo(-12, 1e-9));
      expect(masterFromNorm(center), closeTo(1, 1e-9));
      expect(masterFromNorm(1), closeTo(DjMixer.maxMaster, 1e-9));
      for (final n in [0.0, 0.3, center, 0.9]) {
        expect(gainToNorm(gainFromNorm(n)), closeTo(n, 1e-9));
        expect(masterToNorm(masterFromNorm(n)), closeTo(n, 1e-9));
      }
    });
  });

  group('Mixtrack Pro 3 manejando los decks', () {
    late DjMixer mixer;
    late List<int> sent;
    late List<String> events;
    late MixtrackMapping map;

    setUp(() async {
      mixer = DjMixer();
      // Que los reproductores terminen de configurarse.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      sent = [];
      events = [];
      map = MixtrackMapping(
        mixer: mixer,
        send: (bytes) async => sent.addAll(bytes),
        actions: DjControllerActions(
          onPadMode: (deck) => events.add('pad ${deck.label}'),
          onLoad: (deck) => events.add('load ${deck?.label ?? '-'}'),
          onMessage: (m) => events.add('msg $m'),
        ),
      );
    });

    tearDown(() async {
      await map.stop();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      map.dispose();
      mixer.dispose();
    });

    test('crossfader con toma suave', () async {
      // Físicamente a la izquierda y en pantalla al medio: no salta.
      map.handle(0xB0, 0x07, 0);
      expect(mixer.crossfader, 0);
      // Cuando pasa por el medio, lo toma.
      map.handle(0xB0, 0x07, 64);
      expect(mixer.crossfader, closeTo(0.0079, 0.001));
      map.handle(0xB0, 0x07, 0);
      expect(mixer.crossfader, -1);
      map.handle(0xB0, 0x07, 127);
      expect(mixer.crossfader, 1);
    }, skip: !hasMpv);

    test('volumen, ecualizador, ganancia y general', () async {
      final a = mixer.a;
      map.handle(0xB1, 0x05, 10); // lejos del 0,8 de la pantalla
      expect(a.volume, 0.8);
      map.handle(0xB1, 0x05, 102);
      expect(a.volume, closeTo(102 / 127, 1e-9));
      map.handle(0xB1, 0x05, 0);
      expect(a.volume, 0);

      map.handle(0xB1, 0x01, 64); // agudos al centro = 0 dB
      map.handle(0xB1, 0x01, 127);
      expect(a.eq[2], closeTo(6, 1e-9));
      map.handle(0xB1, 0x03, 64); // graves
      map.handle(0xB1, 0x03, 0);
      expect(a.eq[0], DjDeck.eqKill);

      map.handle(0xB2, 0x04, 64); // FILTER del B = ganancia
      map.handle(0xB2, 0x04, 127);
      expect(mixer.b.gainDb, closeTo(12, 1e-9));

      map.handle(0xB0, 0x0A, 64);
      map.handle(0xB0, 0x0A, 127);
      expect(mixer.master, closeTo(DjMixer.maxMaster, 1e-9));
    }, skip: !hasMpv);

    test('fader de pitch de 14 bits: arriba más lento', () async {
      final a = mixer.a;
      map.handle(0xB1, 0x18, 64);
      map.handle(0xB1, 0x38, 0); // centro exacto
      expect(a.pitch, closeTo(0, 0.0001));
      map.handle(0xB1, 0x18, 0);
      map.handle(0xB1, 0x38, 0);
      expect(a.pitch, closeTo(-a.range, 1e-9));
      map.invertPitch = true;
      map.handle(0xB1, 0x18, 0);
      map.handle(0xB1, 0x38, 1);
      // Invertido, la misma posición física toma de nuevo cuando cruza.
      map.handle(0xB1, 0x18, 127);
      map.handle(0xB1, 0x38, 127);
      expect(a.pitch, closeTo(-a.range, 1e-9));
    }, skip: !hasMpv);

    test('botones que abren cosas en la pantalla', () async {
      map.handle(0x91, 0x0D, 0x7F); // PAD MODE deck A
      map.handle(0x91, 0x0D, 0x00);
      map.handle(0x90, 0x11, 0x7F); // LOAD B
      map.handle(0x92, 0x01, 0x7F); // PLAY B sin canción
      map.handle(0x90, 0x12, 0x7F); // BROWSE
      expect(events, ['pad A', 'load B', 'load B', 'load -']);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(map.log.first.action, 'BROWSE');
      expect(map.log.map((e) => e.raw), contains('91 0D 7F'));
    }, skip: !hasMpv);

    test('SCRATCH y SHIFT', () async {
      map.handle(0x91, 0x06, 0x7F);
      expect(map.log.first.action, contains('SCRATCH prendido'));
      map.handle(0x91, 0x0B, 0x7F); // SHIFT A
      map.handle(0x91, 0x0B, 0x00);
      map.handle(0x80 | 0x01, 0x06, 0x00); // nota apagada: no hace nada
      expect(map.log.first.action, contains('SHIFT'));
    }, skip: !hasMpv);

    test(
        'luces: todas al conectar, después según el estado; al salir se '
        'apagan', () async {
      await map.start();
      expect(sent.take(3), [0x90, 0x75, 0x7F]);
      // Deck A: PLAY (0x01) apagado.
      final rest = sent.skip(3).toList();
      bool has(List<int> msg) {
        for (var i = 0; i + 2 < rest.length; i += 3) {
          if (rest[i] == msg[0] &&
              rest[i + 1] == msg[1] &&
              rest[i + 2] == msg[2]) {
            return true;
          }
        }
        return false;
      }

      expect(has([0x91, 0x01, 0x00]), isTrue);
      expect(has([0x92, 0x1B, 0x00]), isTrue);
      // El botón de SCRATCH prende su luz.
      sent.clear();
      map.handle(0x92, 0x06, 0x7F);
      expect(sent, [0x92, 0x06, 0x7F]);
      sent.clear();
      await map.stop();
      expect(sent.take(3), [0x90, 0x75, 0x00]);
    }, skip: !hasMpv);
  });

  group('conexión automática', () {
    const channel = MethodChannel('tk_music/midi');
    const events = EventChannel('tk_music/midi/events');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockStreamHandler(events, null);
    });

    test('al enchufar avisa, y los mensajes manejan los decks', () async {
      var plugged = true;
      final opened = <Object?>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'devices':
            return {
              'inputs': [if (plugged) 'MixTrack Pro 3'],
              'outputs': [if (plugged) 'MixTrack Pro 3'],
            };
          case 'open':
            opened.add(call.arguments);
            return {'lights': true};
        }
        return null;
      });
      messenger.setMockStreamHandler(
        events,
        MockStreamHandler.inline(onListen: (args, sink) {
          sink.success([0x91, 0x0D, 0x7F, 0x91, 0x0D, 0x00]);
        }),
      );
      final mixer = DjMixer();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final padModes = <String>[];
      final hub = DjControllerHub(
        mixer: mixer,
        bridge: MidiBridge(),
        actions: DjControllerActions(
          onPadMode: (deck) => padModes.add(deck.label),
          onLoad: (_) {},
          onMessage: (_) {},
        ),
      );
      DjControllerProfile? connected;
      DjControllerProfile? disconnected;
      hub.onConnected = (p) => connected = p;
      hub.onDisconnected = (p) => disconnected = p;
      hub.start();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(connected, mixtrackPro3);
      expect(opened.single,
          {'input': 'MixTrack Pro 3', 'output': 'MixTrack Pro 3'});
      expect(hub.lights, isTrue);
      expect(padModes, ['A']);

      plugged = false;
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      expect(disconnected, mixtrackPro3);
      expect(hub.connected, isFalse);
      hub.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      mixer.dispose();
    }, skip: !hasMpv);
  });

  testWidgets('la ventana de "nuevo dispositivo detectado"', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    DjControllerChoice? choice;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            choice = await DjControllerDetectedDialog.show(context,
                profile: mixtrackPro3, controllerAudioFound: true);
          },
          child: const Text('abrir'),
        ),
      ),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    expect(find.text('NUEVO DISPOSITIVO DETECTADO'), findsOneWidget);
    expect(find.text('NUMARK MIXTRACK PRO 3'), findsOneWidget);
    expect(find.text('Computador'), findsOneWidget);
    await tester.tap(find.text('MixTrack PRO 3'));
    await tester.tap(find.text('No mostrar de nuevo'));
    await tester.pump();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(choice?.speakers, DjSpeakers.controller);
    expect(choice?.dontShowAgain, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sin la placa del controlador, solo "Computador"',
      (tester) async {
    DjControllerChoice? choice;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            choice = await DjControllerDetectedDialog.show(context,
                profile: mixtrackPro3,
                controllerAudioFound: false,
                initial: DjSpeakers.controller);
          },
          child: const Text('abrir'),
        ),
      ),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('MixTrack PRO 3'), warnIfMissed: false);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(choice?.speakers, DjSpeakers.computer);
  });
}
