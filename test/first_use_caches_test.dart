import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tk_music/services/equalizer_store.dart';
import 'package:tk_music/services/loudness_store.dart';

/// Perfil recién creado, sin nada guardado: la primera vez que se guarda
/// algo en estos cachés tiraba "Cannot modify unmodifiable map".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('medir el volumen de una canción la primera vez', () async {
    // Sin análisis nativo en el test: usa el volumen neutro y lo guarda.
    final db = await LoudnessStore().dbForFile(1, 'no_existe.mp3');
    expect(db, LoudnessStore.neutralDb);
    // Segunda vez: sale del caché.
    expect(await LoudnessStore().dbForFile(1, 'no_existe.mp3'),
        LoudnessStore.neutralDb);
  });

  test('guardar una banda del ecualizador la primera vez', () async {
    final store = EqualizerStore();
    await store.saveGain(2, 4.5);
    expect(await store.getGains(), {2: 4.5});
  });
}
