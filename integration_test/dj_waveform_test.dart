import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/services/dj/dj_deck.dart';

/// Carga dos canciones reales en dos decks dentro de la app de Windows (con
/// el decodificador nativo) y mide cuándo llegan el BPM y la onda.
const _a = r'C:\Users\USER A1\Desktop\LA SALSA DE SIEMPRE\TORMENTA.mp3';
const _b = r'C:\Users\USER A1\Desktop\LA SALSA DE SIEMPRE\DECISIONES.mp3';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('los dos decks analizan y tienen onda', (tester) async {
    MediaKit.ensureInitialized();
    final watch = Stopwatch()..start();
    final log = <String>[];
    void note(String what) {
      final line = '${watch.elapsedMilliseconds} ms · $what';
      log.add(line);
      debugPrint('DJTEST $line');
    }

    await tester.runAsync(() async {
      final a = DjDeck('A');
      final b = DjDeck('B');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      for (final deck in [a, b]) {
        deck.addListener(() {
          note('deck ${deck.label}: analizando=${deck.analyzing} '
              'falló=${deck.analysisFailed} bpm=${deck.bpm?.toStringAsFixed(1)} '
              'cargandoOnda=${deck.loadingWaveform} '
              'bandas=${deck.bands?.length} picos=${deck.peaks?.length}');
        });
      }
      note('cargando');
      final loads = [
        a.load(Song(mediaStoreId: 1, title: 'A', filePath: _a)),
        b.load(Song(mediaStoreId: 2, title: 'B', filePath: _b)),
      ];
      await Future.wait(loads);
      note('load() terminó');
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (DateTime.now().isBefore(deadline) &&
          (a.bands == null || b.bands == null || a.analyzing || b.analyzing)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      note('FIN A bands=${a.bands?.length} bpm=${a.bpm} · '
          'B bands=${b.bands?.length} bpm=${b.bpm}');
      expect(a.bands, isNotNull);
      expect(b.bands, isNotNull);
      a.dispose();
      b.dispose();
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}
