import 'package:flutter_test/flutter_test.dart';
import 'package:tk_music/services/online_catalog.dart';

Map<String, dynamic> _track(
  String id, {
  String title = 'Tema',
  int duration = 200,
  bool downloadable = false,
  bool downloadGated = false,
  Map<String, dynamic>? access,
  bool streamGated = false,
  bool deleted = false,
}) =>
    {
      'id': id,
      'title': title,
      'duration': duration,
      'genre': 'Latin',
      'is_downloadable': downloadable,
      'is_download_gated': downloadGated,
      'is_stream_gated': streamGated,
      'is_delete': deleted,
      'access': access ?? {'stream': true, 'download': !downloadGated},
      'user': {'name': 'Grupo Tal'},
      'artwork': {
        '150x150': 'https://img/150.jpg',
        '480x480': 'https://img/480.jpg',
      },
    };

void main() {
  test('arma las canciones con carátula y enlace para escuchar', () {
    final tracks = parseOnlineTracks({
      'data': [_track('a1', title: ' Bailando ')]
    });
    expect(tracks, hasLength(1));
    final t = tracks.single;
    expect(t.title, 'Bailando');
    expect(t.artist, 'Grupo Tal');
    expect(t.duration, const Duration(seconds: 200));
    expect(t.artworkUrl, 'https://img/480.jpg');
    expect(t.streamUrl, contains('/v1/tracks/a1/stream'));
  });

  test('descarga solo si el artista la permite sin condiciones', () {
    final tracks = parseOnlineTracks({
      'data': [
        _track('libre', downloadable: true),
        _track('seguir', downloadable: true, downloadGated: true),
        _track('no'),
      ]
    });
    final byId = {for (final t in tracks) t.id: t.downloadable};
    expect(byId, {'libre': true, 'seguir': false, 'no': false});
  });

  test('descarta bloqueadas, borradas, fragmentos cortos y repetidas', () {
    final tracks = parseOnlineTracks({
      'data': [
        _track('ok'),
        _track('ok'),
        _track('corta', duration: 25),
        _track('bloqueada', streamGated: true),
        _track('sin-acceso', access: {'stream': false}),
        _track('borrada', deleted: true),
        {'title': 'sin id'},
      ]
    });
    expect(tracks.map((t) => t.id), ['ok']);
  });

  test('respuestas raras no rompen nada', () {
    expect(parseOnlineTracks(null), isEmpty);
    expect(parseOnlineTracks({'data': 'x'}), isEmpty);
    expect(parseOnlineTracks([1, 2]), isEmpty);
  });

  test('en el reproductor se reconoce como online, con su carátula', () {
    final item = parseOnlineTracks({
      'data': [_track('a1', downloadable: true)]
    }).single.toMediaItem();
    expect(isOnlineItem(item), isTrue);
    expect(artworkUrlOf(item), 'https://img/480.jpg');
    expect(item.extras?['songId'], isNull);
    expect(item.id, startsWith('https://'));
  });
}
