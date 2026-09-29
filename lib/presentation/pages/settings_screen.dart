import 'package:flutter/material.dart';

import 'package:tk_music/core/platform.dart';
import 'package:tk_music/presentation/widgets/app_header.dart';
import 'package:tk_music/services/playback_settings.dart';

/// Ajustes de cómo suena y se ve la reproducción.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = PlaybackSettings.instance;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(title: const AppHeaderTitle(section: 'Ajustes')),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                const _Header('Reproducción'),
                SwitchListTile(
                  secondary: const Icon(Icons.volume_up_outlined),
                  title: const Text('Volumen parejo'),
                  subtitle: const Text(
                      'Todas las canciones suenan igual de fuerte, sin tener '
                      'que tocar el volumen entre una y otra'),
                  value: settings.normalizeVolume,
                  onChanged: settings.setNormalizeVolume,
                ),
                ListTile(
                  leading: const Icon(Icons.compare_arrows),
                  title: const Text('Fundido entre canciones'),
                  subtitle: Text(settings.crossfadeSeconds == 0
                      ? 'Apagado: una canción sigue a la otra sin pausa'
                      : '${settings.crossfadeSeconds} segundos de cruce'),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Slider(
                    value: settings.crossfadeSeconds.toDouble(),
                    min: 0,
                    max: 12,
                    divisions: 12,
                    label: settings.crossfadeSeconds == 0
                        ? 'Apagado'
                        : '${settings.crossfadeSeconds} s',
                    onChanged: (v) => settings.setCrossfadeSeconds(v.round()),
                  ),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.speed),
                  title: const Text('Cruzar sobre el pulso'),
                  subtitle: Text(hasNativeAudioAnalysis
                      ? 'Analiza el ritmo de cada canción para que el cruce '
                          'caiga en el golpe y con los tempos emparejados, como '
                          'un DJ'
                      : 'Necesita el análisis de audio (Android o Windows)'),
                  value: settings.beatMatching && hasNativeAudioAnalysis,
                  onChanged:
                      hasNativeAudioAnalysis && settings.crossfadeSeconds > 0
                          ? settings.setBeatMatching
                          : null,
                ),
                const _Header('Pantalla'),
                SwitchListTile(
                  secondary: const Icon(Icons.image_search),
                  title: const Text('Buscar carátulas en internet'),
                  subtitle: const Text(
                      'Para las canciones que no traen imagen en el archivo '
                      '(gratis; solo se envía artista y álbum o título)'),
                  value: settings.onlineArtwork,
                  onChanged: settings.setOnlineArtwork,
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.palette_outlined),
                  title: const Text('Colores según la carátula'),
                  subtitle: const Text(
                      '"Reproduciendo" toma el color del disco que suena'),
                  value: settings.artworkColors,
                  onChanged: settings.setArtworkColors,
                ),
                const _Header('Letras'),
                SwitchListTile(
                  secondary: const Icon(Icons.lyrics_outlined),
                  title: const Text('Buscar letras en internet'),
                  subtitle: const Text(
                      'Si la canción no trae la letra, la busca en LRCLIB '
                      '(gratis; solo se envía título, artista, álbum y '
                      'duración)'),
                  value: settings.onlineLyrics,
                  onChanged: settings.setOnlineLyrics,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Text(
                    'También se usan las letras guardadas dentro del MP3 y los '
                    'archivos .lrc con el mismo nombre que la canción, en la '
                    'misma carpeta.',
                    style: muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge
            ?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }
}
