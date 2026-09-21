import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/presentation/pages/favorites_tab.dart';
import 'package:tk_music/presentation/pages/home_tab.dart';
import 'package:tk_music/presentation/pages/library_tab.dart';
import 'package:tk_music/presentation/pages/search_tab.dart';
import 'package:tk_music/presentation/widgets/app_drawer.dart';
import 'package:tk_music/presentation/widgets/app_header.dart';
import 'package:tk_music/presentation/widgets/automix_status_button.dart';
import 'package:tk_music/presentation/widgets/mini_player.dart';

class MusicPlayerScreen extends StatefulWidget {
  const MusicPlayerScreen({super.key});

  @override
  State<MusicPlayerScreen> createState() => _MusicPlayerScreenState();
}

class _MusicPlayerScreenState extends State<MusicPlayerScreen> {
  int _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: const AppDrawer(),
      appBar: AppBar(
        title: const AppHeaderTitle(),
        actions: [
          if (isAudioAvailable)
            StreamBuilder<PlaybackState>(
              stream: sl<AudioHandler>().playbackState,
              builder: (context, snapshot) {
                final shuffle = snapshot.data?.shuffleMode ==
                    AudioServiceShuffleMode.all;
                return IconButton(
                  tooltip: 'Shuffle',
                  onPressed: () => sl<AudioHandler>().setShuffleMode(shuffle
                      ? AudioServiceShuffleMode.none
                      : AudioServiceShuffleMode.all),
                  icon: Icon(Icons.shuffle,
                      color: shuffle
                          ? Theme.of(context).colorScheme.primary
                          : null),
                );
              },
            ),
          const ProfileAvatarButton(),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              if (!isAudioAvailable) const _AudioUnavailableBanner(),
              Expanded(
                // IndexedStack conserva el estado (scroll, texto de
                // búsqueda) de cada pestaña al cambiar entre ellas, en vez
                // de reconstruirlas.
                child: IndexedStack(
                  index: _tabIndex,
                  children: const [
                    HomeTab(),
                    SearchTab(),
                    LibraryTab(),
                    FavoritesTab(),
                  ],
                ),
              ),
              const MiniPlayer(),
            ],
          ),
          // El Mezclador automático puede seguir sonando aunque se haya
          // salido de su pantalla (ver AutomixEngine.instance) — este botón
          // avisa que sigue activo y deja volver a esa pantalla.
          const Positioned(
            right: 16,
            bottom: 84,
            child: AutomixStatusButton(),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (index) => setState(() => _tabIndex = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Principal',
          ),
          NavigationDestination(
            icon: Icon(Icons.search),
            label: 'Buscar',
          ),
          NavigationDestination(
            icon: Icon(Icons.library_music_outlined),
            selectedIcon: Icon(Icons.library_music),
            label: 'Biblioteca',
          ),
          NavigationDestination(
            icon: Icon(Icons.thumb_up_outlined),
            selectedIcon: Icon(Icons.thumb_up),
            label: 'Favoritos',
          ),
        ],
      ),
    );
  }
}

/// Se muestra cuando `AudioService.init()` falló o se colgó al arrancar
/// (ver main.dart). Sin esto, tocar una canción no hace nada y no hay forma
/// de saber por qué: la app deshabilita toda la reproducción a propósito
/// para no crashear, pero eso quedaba invisible para quien la usa.
class _AudioUnavailableBanner extends StatelessWidget {
  const _AudioUnavailableBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'No se pudo iniciar el reproductor de audio. Cierra la app '
              'por completo y vuelve a abrirla.',
              style: TextStyle(color: theme.colorScheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}
