import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tk_music/presentation/widgets/dj/dj_shortcuts.dart';
import 'package:tk_music/services/dj/mix_recorder.dart';

KeyDownEvent _down(PhysicalKeyboardKey key) => KeyDownEvent(
      physicalKey: key,
      logicalKey: LogicalKeyboardKey.keyA,
      timeStamp: Duration.zero,
    );

DjKeyBinding? _find(KeyEvent event,
        {bool shift = false, bool alt = false, bool control = false}) =>
    djBindingFor(event, shift: shift, alt: alt, control: control, meta: false);

void main() {
  group('atajos del Modo DJ', () {
    test('ninguna combinación de teclas está repetida', () {
      final seen = <String>{};
      for (final b in djKeyBindings) {
        final id = '${b.key.usbHidUsage}/${b.shift}/${b.alt}';
        expect(seen.add(id), isTrue, reason: 'repetida: ${djKeyLabel(b)}');
      }
    });

    test('todas las teclas tienen nombre visible', () {
      for (final b in djKeyBindings) {
        expect(djKeyLabel(b), isNot(contains('?')));
      }
    });

    test('los dos decks tienen las mismas acciones', () {
      Set<String> of(int deck) => {
            for (final b in djKeyBindings.where((b) => b.deck == deck))
              '${b.command.name}/${b.arg}/${b.shift}/${b.alt}'
          };
      expect(of(0), of(1));
      // Todos los pads 1–8 y borrar punto 1–8.
      for (var i = 0; i < 8; i++) {
        expect(djShortcutHint(DjCommand.pad, deck: 0, arg: i), isNotEmpty);
        expect(djShortcutHint(DjCommand.pad, deck: 1, arg: i), isNotEmpty);
      }
    });

    test('mismo lugar en cada mitad: Q ↔ Y, W ↔ U…', () {
      expect(_find(_down(PhysicalKeyboardKey.keyQ))?.command, DjCommand.cue);
      expect(_find(_down(PhysicalKeyboardKey.keyQ))?.deck, 0);
      expect(_find(_down(PhysicalKeyboardKey.keyY))?.command, DjCommand.cue);
      expect(_find(_down(PhysicalKeyboardKey.keyY))?.deck, 1);
      expect(_find(_down(PhysicalKeyboardKey.keyU))?.command, DjCommand.play);
      // La Ñ (punto y coma en teclado inglés): tono fijo del deck B.
      expect(_find(_down(PhysicalKeyboardKey.semicolon))?.command,
          DjCommand.keylock);
      expect(_find(_down(PhysicalKeyboardKey.f9))?.command, DjCommand.record);
    });

    test('Shift y Alt cambian lo que hace la tecla', () {
      final pad = _find(_down(PhysicalKeyboardKey.digit2));
      expect((pad?.command, pad?.arg), (DjCommand.pad, 1));
      final shifted = _find(_down(PhysicalKeyboardKey.digit2), shift: true);
      expect((shifted?.command, shifted?.arg), (DjCommand.pad, 5));
      final clear = _find(_down(PhysicalKeyboardKey.digit2), alt: true);
      expect((clear?.command, clear?.arg), (DjCommand.padClear, 1));
    });

    test('Ctrl queda libre y solo algunas teclas repiten', () {
      expect(_find(_down(PhysicalKeyboardKey.keyW), control: true), isNull);
      const repeatPlay = KeyRepeatEvent(
        physicalKey: PhysicalKeyboardKey.keyW,
        logicalKey: LogicalKeyboardKey.keyW,
        timeStamp: Duration.zero,
      );
      expect(_find(repeatPlay), isNull, reason: 'PLAY no se repite');
      const repeatPitch = KeyRepeatEvent(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        timeStamp: Duration.zero,
      );
      expect(_find(repeatPitch)?.command, DjCommand.pitchDown);
      const up = KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        timeStamp: Duration.zero,
      );
      expect(_find(up), isNull);
    });

    test('la ayuda muestra cada comando de los decks', () {
      final actions = djDeckShortcutHelp.map((r) => r.action).join(' | ');
      for (final word in [
        'CUE',
        'PLAY',
        'SYNC',
        'AUTO',
        'TONO',
        'Pitch',
        'Rango',
        'FIJO',
        'Semitono',
        'CARGAR',
        'Probar',
        'Pads 1 a 4',
        'Pads 5 a 8',
        'Borrar',
        'modo',
      ]) {
        expect(actions, contains(word));
      }
      final mixer = djMixerShortcutHelp.map((r) => r.action).join(' | ');
      for (final word in ['Crossfader', 'Volumen', 'MEZCLA', 'Grabar']) {
        expect(mixer, contains(word));
      }
    });
  });

  group('MixRecorder', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('tk_music/loopback_recorder');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('graba, informa el tiempo y guarda', () async {
      var recording = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'start':
            return {'path': r'C:\Música\TK Music\Mezclas\m.wav'};
          case 'status':
            return {'recording': recording, 'durationMs': 65000, 'peak': 0.5};
          case 'stop':
            recording = false;
            return {
              'path': r'C:\Música\TK Music\Mezclas\m.wav',
              'durationMs': 66000,
            };
        }
        return null;
      });
      final recorder = MixRecorder();
      expect(await recorder.start(), isNull);
      expect(recorder.recording, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 260));
      expect(recorder.elapsed, const Duration(seconds: 65));
      expect(recorder.peak, 0.5);
      final message = await recorder.stop();
      expect(message, contains('01:06'));
      expect(message, contains('Mezclas'));
      expect(recorder.recording, isFalse);
      recorder.dispose();
    }, skip: !MixRecorder.supported);

    test('si se corta sola, avisa y cierra', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'start':
            return {'path': 'x.wav'};
          case 'status':
            return {
              'recording': false,
              'durationMs': 1000,
              'error': 'Se cambió o desconectó la salida de audio.',
            };
          case 'stop':
            return {'path': 'x.wav', 'durationMs': 1000};
        }
        return null;
      });
      final recorder = MixRecorder();
      String? warning;
      recorder.onInterrupted = (m) => warning = m;
      await recorder.start();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(recorder.recording, isFalse);
      expect(warning, contains('desconectó'));
      expect(warning, contains('x.wav'));
      recorder.dispose();
    }, skip: !MixRecorder.supported);

    test('un error al empezar se muestra', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
            code: 'start_failed',
            message: 'No hay una salida de audio activa en Windows.');
      });
      final recorder = MixRecorder();
      expect(await recorder.start(), contains('salida de audio'));
      expect(recorder.recording, isFalse);
      recorder.dispose();
    }, skip: !MixRecorder.supported);

    test('formato del tiempo', () {
      expect(formatRecordingTime(const Duration(seconds: 272)), '04:32');
      expect(formatRecordingTime(const Duration(seconds: 3909)), '1:05:09');
    });
  });
}
