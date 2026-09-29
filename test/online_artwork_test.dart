import 'package:flutter_test/flutter_test.dart';
import 'package:tk_music/services/online_artwork.dart';

void main() {
  group('qué se busca', () {
    test('por álbum si hay etiquetas', () {
      final q = artworkQuery(
          title: 'Mujeres divinas', artist: 'Grupo Caneo', album: 'Salsa')!;
      expect(q.byAlbum, isTrue);
      expect(q.term, 'Grupo Caneo Salsa');
    });

    test('las etiquetas de relleno ("artist", "title") no cuentan', () {
      final q =
          artworkQuery(title: 'Rebelión', artist: 'artist', album: 'title')!;
      expect(q.artistInTerm, isTrue,
          reason: 'sin artista real: busca por nombre y valida');
      expect(q.term, 'Rebelión');
    });

    test('"Artista - Tema" en el nombre del archivo', () {
      final q = artworkQuery(title: 'LOS NICHES - EL GRAN CONQUISTADOR')!;
      expect(q.artist, 'LOS NICHES');
      expect(q.term, 'LOS NICHES EL GRAN CONQUISTADOR');
    });

    test('"060-ARTISTA-TEMA-autor" con guiones pegados', () {
      final q =
          artworkQuery(title: '060-ROBERTO TORRES-CABALLO VIEJO-R. TORRES')!;
      expect(q.artist, 'ROBERTO TORRES');
      expect(q.term, 'ROBERTO TORRES CABALLO VIEJO');
    });

    test('limpia el ruido de los archivos bajados', () {
      final q = artworkQuery(title: 'Siempre Alegre Raphy Leavitt Letra (HQ)')!;
      expect(q.term, 'Siempre Alegre Raphy Leavitt');
      final w = artworkQuery(title: 'POR TELEFONO NOOO!!.wmv_50k')!;
      expect(w.term, 'POR TELEFONO NOOO');
    });
  });

  group('qué resultado se acepta', () {
    final results = [
      {'artistName': 'Name of Artist', 'artworkUrl100': 'x'},
      {'artistName': 'Rubén Blades', 'artworkUrl100': 'rb'},
    ];

    test(
        'por nombre de archivo: el artista tiene que estar escrito (sin tildes)',
        () {
      final best = pickBestArtworkResult(results,
          term: 'GANAS RUBEN BLADES BIEN BAILADA', artistInTerm: true);
      expect(best?['artworkUrl100'], 'rb');
    });

    test('si el artista no aparece, no pone una carátula ajena', () {
      final best = pickBestArtworkResult(
        [
          {'artistName': 'Otro Grupo', 'artworkUrl100': 'x'}
        ],
        term: 'POR TELEFONO NOOO',
        artistInTerm: true,
      );
      expect(best, isNull);
    });

    test('con artista conocido elige el que coincide', () {
      final best = pickBestArtworkResult(results, artist: 'Ruben Blades');
      expect(best?['artworkUrl100'], 'rb');
    });
  });
}
