import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tk_music/services/active_profile.dart';
import 'package:tk_music/services/recent_songs_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ActiveProfile.instance.set('test-profile');
  });

  test('recuerda las últimas canciones, más reciente primero', () async {
    final store = RecentSongsStore();

    await store.recordPlayed(1);
    await store.recordPlayed(2);
    await store.recordPlayed(3);

    expect(await store.getRecentIds(), [3, 2, 1]);
  });

  test('no duplica: repetir una canción la vuelve a poner primera', () async {
    final store = RecentSongsStore();

    await store.recordPlayed(1);
    await store.recordPlayed(2);
    await store.recordPlayed(1);

    expect(await store.getRecentIds(), [1, 2]);
  });

  test('no mezcla el historial de perfiles distintos', () async {
    final store = RecentSongsStore();

    ActiveProfile.instance.set('profile-a');
    await store.recordPlayed(1);

    ActiveProfile.instance.set('profile-b');
    await store.recordPlayed(2);

    expect(await store.getRecentIds(), [2]);

    ActiveProfile.instance.set('profile-a');
    expect(await store.getRecentIds(), [1]);
  });
}
