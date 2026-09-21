import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/domain/entities/equalizer_preset.dart';
import 'package:tk_music/presentation/widgets/scrolling_waveform_view.dart';
import 'package:tk_music/presentation/widgets/spectrum_visualizer.dart';
import 'package:tk_music/services/audio_handler.dart';
import 'package:tk_music/services/equalizer_store.dart';
import 'package:tk_music/services/spectrogram_store.dart';
import 'package:tk_music/services/waveform_loader.dart';

/// Ecualizador gráfico: sube o baja la ganancia por banda de frecuencia
/// (graves a agudos) de la reproducción principal, usando el efecto nativo
/// Equalizer de Android que ya trae just_audio. No cubre al Mezclador
/// automático (usa sus propios reproductores aparte).
class EqualizerScreen extends StatefulWidget {
  const EqualizerScreen({super.key});

  @override
  State<EqualizerScreen> createState() => _EqualizerScreenState();
}

class _EqualizerScreenState extends State<EqualizerScreen> {
  final _store = EqualizerStore();
  final _spectrogramStore = SpectrogramStore();
  AndroidEqualizerParameters? _params;
  final Map<int, double> _gains = {};
  bool _enabled = false;
  bool _unavailable = false;
  EqualizerPreset _preset = EqualizerPreset.custom;
  SpectrogramData? _spectrogram;
  int? _loadedSpectrogramSongId;
  bool _spectrumFailed = false;
  StreamSubscription<MediaItem?>? _mediaItemSub;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _mediaItemSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (!isAudioAvailable) {
      setState(() => _unavailable = true);
      return;
    }
    final handler = sl<AudioHandler>() as MyAudioHandler;
    try {
      final params = await handler.equalizer.parameters;
      final enabled = handler.equalizer.enabled;
      final savedPreset = await _store.getPreset();
      if (!mounted) return;
      setState(() {
        _params = params;
        _enabled = enabled;
        _preset = EqualizerPreset.values.firstWhere(
          (p) => p.name == savedPreset,
          orElse: () => EqualizerPreset.custom,
        );
        for (final band in params.bands) {
          _gains[band.index] = band.gain;
        }
      });
      // handler.mediaItem reproduce el último valor apenas alguien se
      // suscribe, así que este listen ya cubre la canción actual (si hay
      // una sonando) sin necesitar un fetch aparte.
      _mediaItemSub = handler.mediaItem.listen((item) {
        final songId = item?.extras?['songId'] as int?;
        if (item != null && songId != null) {
          unawaited(_maybeLoadSpectrogram(item, songId));
        }
      });
    } catch (_) {
      if (mounted) setState(() => _unavailable = true);
    }
  }

  Future<void> _maybeLoadSpectrogram(MediaItem item, int songId) async {
    if (songId == _loadedSpectrogramSongId) return;
    _loadedSpectrogramSongId = songId;
    if (mounted) setState(() => _spectrogram = null);

    var position = Duration.zero;
    try {
      position = await AudioService.position.first
          .timeout(const Duration(milliseconds: 300));
    } catch (_) {}
    final total = item.duration ?? Duration.zero;
    final fraction = total.inMilliseconds == 0
        ? 0.0
        : (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);

    final data = await _spectrogramStore.spectrogramFor(
      mediaStoreId: songId,
      filePath: item.id,
      positionFraction: fraction,
      onProgress: (partial) {
        if (!mounted || _loadedSpectrogramSongId != songId) return;
        setState(() {
          _spectrogram = partial;
          _spectrumFailed = false;
        });
      },
    );
    if (!mounted || _loadedSpectrogramSongId != songId) return;
    setState(() {
      if (data != null) _spectrogram = data;
      _spectrumFailed = data == null && _spectrogram == null;
    });
  }

  Future<void> _toggleEnabled(bool value) async {
    final handler = sl<AudioHandler>() as MyAudioHandler;
    setState(() => _enabled = value);
    await handler.equalizer.setEnabled(value);
    await _store.setEnabled(value);
  }

  void _setGain(AndroidEqualizerBand band, double gain) {
    // Tocar una banda a mano deja de ser "Pop"/"Rock"/etc — pasa a ser tu
    // propia mezcla.
    setState(() {
      _gains[band.index] = gain;
      _preset = EqualizerPreset.custom;
    });
    unawaited(band.setGain(gain));
    unawaited(_store.saveGain(band.index, gain));
    unawaited(_store.setPreset(EqualizerPreset.custom.name));
  }

  Future<void> _applyPreset(EqualizerPreset preset) async {
    final params = _params;
    if (params == null) return;

    if (preset != EqualizerPreset.custom) {
      final gains = gainsForPreset(
        preset,
        bandCount: params.bands.length,
        minDb: params.minDecibels,
        maxDb: params.maxDecibels,
      );
      for (var i = 0; i < params.bands.length; i++) {
        final band = params.bands[i];
        await band.setGain(gains[i]);
        await _store.saveGain(band.index, gains[i]);
        _gains[band.index] = gains[i];
      }
    }
    await _store.setPreset(preset.name);
    if (!mounted) return;
    setState(() => _preset = preset);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: const Text('Ecualizador'),
        actions: [
          IconButton(
            tooltip: 'Restablecer a Normal',
            icon: const Icon(Icons.refresh),
            onPressed: _params == null
                ? null
                : () => _applyPreset(EqualizerPreset.normal),
          ),
        ],
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_unavailable) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Este dispositivo no soporta el ecualizador de audio.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      );
    }
    final params = _params;
    if (params == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        const _NowPlayingWaveformCard(),
        const SizedBox(height: 12),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Espectro en vivo', style: theme.textTheme.labelLarge),
              const SizedBox(height: 10),
              StreamBuilder<Duration>(
                stream: AudioService.position,
                builder: (context, posSnapshot) {
                  final position = posSnapshot.data ?? Duration.zero;
                  return SpectrumVisualizer(bands: _spectrogram?.bandsAt(position));
                },
              ),
              if (_spectrumFailed) ...[
                const SizedBox(height: 6),
                Text(
                  'No se pudo activar el espectro en este dispositivo.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Activar ecualizador'),
          value: _enabled,
          onChanged: _toggleEnabled,
        ),
        const Divider(height: 1),
        DropdownButtonHideUnderline(
          child: DropdownButtonFormField<EqualizerPreset>(
            value: _preset,
            decoration: const InputDecoration(
              labelText: 'Preset',
              border: InputBorder.none,
            ),
            items: [
              for (final preset in EqualizerPreset.values)
                DropdownMenuItem(
                  value: preset,
                  child: Text(preset.label),
                ),
            ],
            onChanged: _enabled
                ? (preset) {
                    if (preset != null) _applyPreset(preset);
                  }
                : null,
          ),
        ),
        const Divider(height: 1),
        SizedBox(
          height: 260,
          child: Padding(
            padding: const EdgeInsets.only(top: 20, bottom: 12),
            child: Row(
              children: [
                _DbRuler(minDb: params.minDecibels, maxDb: params.maxDecibels),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      for (final band in params.bands)
                        Expanded(
                          child: _BandSlider(
                            band: band,
                            gain: _gains[band.index] ?? 0.0,
                            minDb: params.minDecibels,
                            maxDb: params.maxDecibels,
                            enabled: _enabled,
                            onChanged: (v) => _setGain(band, v),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Regla de dB pegada al costado de las bandas, alineada con el recorrido
/// del slider rotado (máximo arriba, mínimo abajo).
class _DbRuler extends StatelessWidget {
  const _DbRuler({required this.minDb, required this.maxDb});

  final double minDb;
  final double maxDb;

  static const _steps = 5;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 30,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(_steps, (i) {
          final value = maxDb - (maxDb - minDb) * (i / (_steps - 1));
          final isZero = value.abs() < (maxDb - minDb) / (_steps - 1) / 2;
          return Text(
            '${value.round()}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: isZero
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
              fontWeight: isZero ? FontWeight.w700 : FontWeight.w400,
            ),
          );
        }),
      ),
    );
  }
}

/// Onda de lo que está sonando ahora, igual que en "Reproduciendo" — para
/// tener una referencia visual mientras se ajustan las bandas, no solo
/// números. Se oculta sola si no hay nada sonando.
class _NowPlayingWaveformCard extends StatefulWidget {
  const _NowPlayingWaveformCard();

  @override
  State<_NowPlayingWaveformCard> createState() =>
      _NowPlayingWaveformCardState();
}

class _NowPlayingWaveformCardState extends State<_NowPlayingWaveformCard> {
  MediaItem? _item;
  StreamSubscription<MediaItem?>? _mediaItemSub;

  @override
  void initState() {
    super.initState();
    if (!isAudioAvailable) return;
    final handler = sl<AudioHandler>() as MyAudioHandler;
    _mediaItemSub = handler.mediaItem.listen((item) {
      if (mounted) setState(() => _item = item);
    });
  }

  @override
  void dispose() {
    _mediaItemSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!isAudioAvailable) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final item = _item;
    final songId = item?.extras?['songId'] as int?;

    if (item == null || songId == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            'Reproducí algo para ver la onda y el espectro acá',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall,
          ),
          if (item.artist != null)
            Text(
              item.artist!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          const SizedBox(height: 8),
          AnimatedBuilder(
            animation: WaveformLoader.instance,
            builder: (context, _) {
              return StreamBuilder<Duration>(
                stream: AudioService.position,
                builder: (context, posSnapshot) {
                  final position = posSnapshot.data ?? Duration.zero;
                  final total = item.duration ?? Duration.zero;
                  final progress = total.inMilliseconds == 0
                      ? 0.0
                      : position.inMilliseconds / total.inMilliseconds;
                  return ScrollingWaveformView(
                    peaks: WaveformLoader.instance.peaks,
                    progress: progress,
                    height: 56,
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

class _BandSlider extends StatelessWidget {
  const _BandSlider({
    required this.band,
    required this.gain,
    required this.minDb,
    required this.maxDb,
    required this.enabled,
    required this.onChanged,
  });

  final AndroidEqualizerBand band;
  final double gain;
  final double minDb;
  final double maxDb;
  final bool enabled;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final boosted = gain > 0.3;
    final cut = gain < -0.3;
    final accent = boosted
        ? theme.colorScheme.primary
        : cut
            ? theme.colorScheme.tertiary
            : theme.colorScheme.onSurfaceVariant;

    return Column(
      children: [
        Expanded(
          child: RotatedBox(
            quarterTurns: 3,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: accent,
                inactiveTrackColor:
                    theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 8),
                thumbColor: accent,
                overlayColor: accent.withValues(alpha: 0.15),
              ),
              child: Slider(
                value: gain.clamp(minDb, maxDb),
                min: minDb,
                max: maxDb,
                onChanged: enabled ? onChanged : null,
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(_frequencyLabel(band.centerFrequency),
            style: theme.textTheme.bodySmall),
        Text(
          '${gain > 0 ? '+' : ''}${gain.toStringAsFixed(0)}',
          style: theme.textTheme.labelSmall?.copyWith(
            color: accent,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  String _frequencyLabel(double centerFrequency) {
    if (centerFrequency >= 1000) {
      final khz = centerFrequency / 1000;
      return '${khz % 1 == 0 ? khz.toStringAsFixed(0) : khz.toStringAsFixed(1)}k';
    }
    return centerFrequency.round().toString();
  }
}
