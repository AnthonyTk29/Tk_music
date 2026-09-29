import 'package:flutter_test/flutter_test.dart';
import 'package:tk_music/services/song_identity.dart';

void main() {
  test('con etiquetas usa las etiquetas', () {
    final id = songIdentity(
        title: 'El trovador', artist: 'The Latin Brothers', album: 'Éxitos')!;
    expect(id.artist, 'The Latin Brothers');
    expect(id.title, 'El trovador');
    expect(id.album, 'Éxitos');
  });

  test('sin artista lo saca del nombre del archivo', () {
    final id = songIdentity(title: 'the latin brothers - el trovador xx')!;
    expect(id.artist, 'the latin brothers');
    expect(id.title, 'el trovador xx');
  });

  test('las etiquetas de relleno no cuentan', () {
    final id = songIdentity(title: 'Rebelión (HQ)', artist: 'artist')!;
    expect(id.artist, isNull);
    expect(id.title, 'Rebelión');
  });

  test('el artista de un resultado tiene que estar escrito en el nombre', () {
    expect(artistNamedIn('Rubén Blades', 'GANAS RUBEN BLADES BIEN BAILADA'),
        greaterThan(0));
    expect(artistNamedIn('Rubén Fuentes', 'GANAS RUBEN BLADES'), 0);
    expect(artistNamedIn('', 'cualquier cosa'), 0);
  });
}
