/// Artista, título y álbum "de verdad" de una canción, para buscarla en
/// servicios de internet (carátulas, letras). Muchos MP3 no traen etiquetas
/// o traen relleno ("artist", "title"), y el nombre del archivo es
/// "007. Artista - Tema (HQ)": de ahí se saca lo que se pueda.
class SongIdentity {
  const SongIdentity({required this.title, this.artist, this.album});

  final String title;

  /// `null` si no se conoce: [title] puede traer el artista mezclado, y lo
  /// encontrado hay que validarlo con [artistNamedIn].
  final String? artist;
  final String? album;
}

final _leadingNumber = RegExp(r'^\s*\d{1,3}\s*[-._)]*\s*');

/// Etiquetas "de relleno" que traen algunos MP3 en vez de datos reales.
final _placeholder = RegExp(
  r'^(<unknown>|unknown|unknown artist|unknown album|desconocido|artist|'
  r'artista|title|titulo|título|album|álbum|track|pista|various artists|'
  r'varios artistas|va|n/a|-)$',
  caseSensitive: false,
);

/// Ruido típico de archivos bajados de internet: "(HQ)", "Letra",
/// "Video oficial", "_50k", ".wmv"…
final _noise = RegExp(
  r'[\(\[][^\)\]]*[\)\]]|\b(letra|lyrics?|video oficial|official video|'
  r'audio oficial|official audio|hq|hd|con letra)\b|_\d+k\b|\.(wmv|mp4|avi|flv|mkv)',
  caseSensitive: false,
);

SongIdentity? songIdentity(
    {required String title, String? artist, String? album}) {
  String? clean(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty || _placeholder.hasMatch(trimmed)) {
      return null;
    }
    return trimmed;
  }

  var songArtist = clean(artist);
  var songTitle = clean(title)
      ?.replaceFirst(_leadingNumber, '')
      .replaceAll(_noise, ' ')
      .replaceAll(RegExp(r'[_!]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (songTitle == null || songTitle.isEmpty) return null;
  if (songArtist == null) {
    // "Artista - Tema" o "ARTISTA-TEMA-autor".
    final separator = songTitle.contains(' - ')
        ? ' - '
        : (RegExp(r'\S-\S').hasMatch(songTitle) ? '-' : null);
    if (separator != null) {
      final parts = songTitle.split(separator).map((p) => p.trim()).toList();
      if (parts.length >= 2 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
        songArtist = parts[0];
        songTitle = parts[1];
      }
    }
  }
  return SongIdentity(
      title: songTitle, artist: songArtist, album: clean(album));
}

/// Palabras de un texto sin tildes ni signos ("Rubén" = "ruben").
Set<String> searchWords(String text) {
  const from = 'áàäâéèëêíìïîóòöôúùüûñç';
  const to = 'aaaaeeeeiiiioooouuuunc';
  final lower = text.toLowerCase();
  final buffer = StringBuffer();
  for (final char in lower.split('')) {
    final i = from.indexOf(char);
    buffer.write(i >= 0 ? to[i] : char);
  }
  return buffer
      .toString()
      .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
      .split(' ')
      .where((w) => w.length > 2)
      .toSet();
}

/// Cuántas palabras del artista de un resultado aparecen en [text], o 0 si
/// no alcanza: sin artista conocido tienen que estar todas sus palabras (o
/// al menos dos), no una coincidencia suelta.
int artistNamedIn(String resultArtist, String text) {
  final artistWords = searchWords(resultArtist);
  final score = artistWords.intersection(searchWords(text)).length;
  final needed = artistWords.length < 2 ? artistWords.length : 2;
  return score >= needed ? score : 0;
}
