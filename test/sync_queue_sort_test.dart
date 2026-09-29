import 'package:flutter_test/flutter_test.dart';
import 'package:tk_music/services/party_sync_engine.dart';

void main() {
  List<SyncTrack> tracks() {
    final list = [
      SyncTrack(
          id: 'a',
          title: 'Zeta',
          artist: 'Bravo',
          album: 'Uno',
          durationMs: 300),
      SyncTrack(
          id: 'b',
          title: 'alfa',
          artist: 'charlie',
          album: 'Dos',
          durationMs: 100),
      SyncTrack(
          id: 'c',
          title: 'Medio',
          artist: 'Bravo',
          album: 'uno',
          durationMs: 200),
      SyncTrack(id: 'd', title: 'Beta', durationMs: 100),
    ];
    for (var i = 0; i < list.length; i++) {
      list[i].arrival = i;
    }
    return list;
  }

  List<String> ids(List<SyncTrack> list) => [for (final t in list) t.id];

  test('ordena por título sin distinguir mayúsculas', () {
    final list = tracks();
    sortQueueFrom(list, from: 0, mode: QueueSortMode.title);
    expect(ids(list), ['b', 'd', 'c', 'a']);
  });

  test('por artista desempata por título; sin artista va primero', () {
    final list = tracks();
    sortQueueFrom(list, from: 0, mode: QueueSortMode.artist);
    expect(ids(list), ['d', 'c', 'a', 'b']);
  });

  test('por duración respeta el orden de llegada en los empates', () {
    final list = tracks();
    sortQueueFrom(list, from: 0, mode: QueueSortMode.duration);
    expect(ids(list), ['b', 'd', 'c', 'a']);
  });

  test('no toca lo que ya sonó ni la canción actual', () {
    final list = tracks();
    sortQueueFrom(list, from: 2, mode: QueueSortMode.title);
    expect(ids(list), ['a', 'b', 'd', 'c']);
  });

  test('"como se fueron agregando" vuelve al orden de llegada', () {
    final list = tracks();
    sortQueueFrom(list, from: 0, mode: QueueSortMode.title);
    sortQueueFrom(list, from: 0, mode: QueueSortMode.none);
    expect(ids(list), ['a', 'b', 'c', 'd']);
  });

  test('las canciones de invitados viajan con quién las agregó', () {
    final track = SyncTrack(id: 'g1-5', title: 'Tema')..addedBy = 'Redmi 9A';
    final copy = SyncTrack.fromJson(track.toJson());
    expect(copy.addedBy, 'Redmi 9A');
    expect(copy.id, 'g1-5');
  });
}
