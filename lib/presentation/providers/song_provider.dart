import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import 'package:tk_music/services/app_audio_handler.dart';
import 'package:tk_music/services/artwork_bytes.dart';
import 'package:tk_music/services/tag_overrides_store.dart';
import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/core/platform.dart';
import 'package:tk_music/services/desktop_library_scanner.dart';
import 'package:tk_music/domain/failures/failures.dart';
import 'package:tk_music/services/media_item_mapper.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/domain/entities/sort_option.dart';
import 'package:tk_music/domain/usecases/get_songs.dart';
import 'package:tk_music/services/queue_capable_handler.dart';

class SongProvider extends ChangeNotifier {
  SongProvider() {
    loadSongs();
    // Desktop: la biblioteca son todos los discos y se revisa sola en
    // segundo plano; si aparecen o desaparecen canciones, se actualiza sin
    // cortar lo que suena.
    if (isDesktopPlatform) {
      DesktopLibraryScanner.instance.revision.addListener(_reloadQuietly);
    }
  }

  @override
  void dispose() {
    if (isDesktopPlatform) {
      DesktopLibraryScanner.instance.revision.removeListener(_reloadQuietly);
    }
    super.dispose();
  }

  /// Recarga la lista sin spinner ni tocar la cola del reproductor (cada
  /// "reproducir" desde la biblioteca arma la cola de nuevo).
  Future<void> _reloadQuietly() async {
    if (_loadFuture != null) return;
    final (songs, _) = await sl<GetSongs>()();
    if (songs == null) return;
    _originals = songs;
    _songs = _originals.map(TagOverridesStore.instance.apply).toList();
    ArtworkBytes.registerSongs(_songs);
    notifyListeners();
  }

  List<Song> _songs = [];
  // Tal como vienen del sistema, sin las correcciones del editor de tags.
  List<Song> _originals = [];

  /// Datos originales (sin corregir) de una canción, para el editor.
  Song? originalOf(int songId) {
    for (final song in _originals) {
      if (song.mediaStoreId == songId) return song;
    }
    return null;
  }

  /// Vuelve a aplicar las correcciones de [songId] después de editarla, sin
  /// recargar toda la biblioteca (ni cortar lo que está sonando).
  void refreshSong(int songId) {
    final original = originalOf(songId);
    if (original == null) return;
    final updated = TagOverridesStore.instance.apply(original);
    ArtworkBytes.registerSongs([updated]);
    _songs = [
      for (final song in _songs) song.mediaStoreId == songId ? updated : song
    ];
    if (isAudioAvailable) {
      (sl<AudioHandler>() as AppAudioHandler)
          .refreshMediaItem(MediaItemMapper.fromSong(updated));
    }
    notifyListeners();
  }

  bool _loading = true;
  String _search = '';
  Failure? _failure;
  SortOption _sort = SortOption.titleAsc;
  String? _genreFilter;

  List<Song> get songs => _songs;
  bool get loading => _loading;
  String get search => _search;
  Failure? get failure => _failure;
  SortOption get sort => _sort;
  String? get genreFilter => _genreFilter;

  List<Song> get visibleSongs {
    if (_search.isEmpty) return _songs;
    final q = _search.toLowerCase();
    return _songs.where((s) {
      final text =
          '${s.title} ${s.artist ?? ''} ${s.album ?? ''}'.toLowerCase();
      return text.contains(q);
    }).toList();
  }

  /// Géneros reales presentes en la biblioteca (etiqueta ID3), de más a
  /// menos frecuente. Muchos archivos no traen género; si ninguno lo trae,
  /// queda vacío y no tiene sentido mostrar chips de filtro.
  List<String> get availableGenres {
    final counts = <String, int>{};
    for (final s in _songs) {
      final g = s.genre;
      if (g != null) counts[g] = (counts[g] ?? 0) + 1;
    }
    final genres = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    return genres;
  }

  /// Biblioteca completa ordenada según [sort] y filtrada por [genreFilter]
  /// si hay uno elegido. No se ve afectada por la búsqueda (esa vive en
  /// [visibleSongs], usada solo en la pestaña Buscar).
  List<Song> get sortedLibrary {
    var list = _genreFilter == null
        ? List<Song>.from(_songs)
        : _songs.where((s) => s.genre == _genreFilter).toList();

    switch (_sort) {
      case SortOption.titleAsc:
        list.sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      case SortOption.artistAsc:
        list.sort((a, b) => (a.artist ?? '')
            .toLowerCase()
            .compareTo((b.artist ?? '').toLowerCase()));
      case SortOption.dateAddedDesc:
        list.sort((a, b) =>
            (b.dateAdded ?? DateTime(0)).compareTo(a.dateAdded ?? DateTime(0)));
      case SortOption.durationDesc:
        list.sort((a, b) => (b.duration ?? Duration.zero)
            .compareTo(a.duration ?? Duration.zero));
    }
    return list;
  }

  void updateSearch(String value) {
    _search = value.trim();
    notifyListeners();
  }

  void updateSort(SortOption option) {
    _sort = option;
    notifyListeners();
  }

  void updateGenreFilter(String? genre) {
    _genreFilter = genre;
    notifyListeners();
  }

  Future<void>? _loadFuture;

  /// Coalesce llamadas concurrentes (p. ej. varios taps en "Reintentar") para
  /// que no compitan por armar la cola de audio al mismo tiempo.
  Future<void> loadSongs() {
    return _loadFuture ??= _loadSongs().whenComplete(() => _loadFuture = null);
  }

  Future<void> _loadSongs() async {
    _loading = true;
    _failure = null;
    notifyListeners();

    final (songs, failure) = await sl<GetSongs>()();
    _originals = songs ?? [];
    _songs = _originals.map(TagOverridesStore.instance.apply).toList();
    ArtworkBytes.registerSongs(_songs);
    _failure = failure;

    // La cola de audio se arma antes de soltar el spinner: si se notificara
    // primero, la lista quedaría tocable mientras setQueue() todavía está en
    // vuelo y un tap disparado en ese hueco llamaría a skipToQueueItem sobre
    // una cola vacía, sin efecto y sin ningún aviso para el usuario.
    if (_songs.isNotEmpty && isAudioAvailable) {
      try {
        final items = _songs.map(MediaItemMapper.fromSong).toList();
        await (sl<AudioHandler>() as QueueCapableHandler)
            .setQueue(items, resumeLastPosition: true);
      } catch (e) {
        debugPrint('setQueue failed: $e');
      }
    }

    _loading = false;
    notifyListeners();
  }
}
