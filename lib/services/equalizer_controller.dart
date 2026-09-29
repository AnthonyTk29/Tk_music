import 'package:just_audio/just_audio.dart';
import 'package:media_kit/media_kit.dart';

import 'equalizer_store.dart';

class EqualizerBandInfo {
  const EqualizerBandInfo({
    required this.index,
    required this.centerFrequency,
    required this.gain,
  });

  final int index;

  /// En Hz.
  final double centerFrequency;

  /// En dB.
  final double gain;
}

class EqualizerParameters {
  const EqualizerParameters({
    required this.minDecibels,
    required this.maxDecibels,
    required this.bands,
  });

  final double minDecibels;
  final double maxDecibels;
  final List<EqualizerBandInfo> bands;
}

/// Ecualizador del reproductor principal, igual para las dos plataformas —
/// la pantalla del Ecualizador habla con esto y no sabe si abajo está el
/// efecto nativo de Android o el filtro de mpv de desktop.
abstract class EqualizerController {
  bool get enabled;
  Future<void> setEnabled(bool enabled);
  Future<EqualizerParameters> get parameters;
  Future<void> setBandGain(int index, double gain);
}

/// Android: el efecto Equalizer nativo que trae just_audio.
class AndroidEqualizerController implements EqualizerController {
  AndroidEqualizerController(this._equalizer);

  final AndroidEqualizer _equalizer;

  @override
  bool get enabled => _equalizer.enabled;

  @override
  Future<void> setEnabled(bool enabled) => _equalizer.setEnabled(enabled);

  @override
  Future<EqualizerParameters> get parameters async {
    final params = await _equalizer.parameters;
    return EqualizerParameters(
      minDecibels: params.minDecibels,
      maxDecibels: params.maxDecibels,
      bands: [
        for (final band in params.bands)
          EqualizerBandInfo(
            index: band.index,
            centerFrequency: band.centerFrequency,
            gain: band.gain,
          ),
      ],
    );
  }

  @override
  Future<void> setBandGain(int index, double gain) async {
    final params = await _equalizer.parameters;
    for (final band in params.bands) {
      if (band.index == index) await band.setGain(gain);
    }
  }
}

/// Desktop: un filtro `equalizer` de FFmpeg por banda, aplicado sobre el
/// audio de media_kit (mpv) — las mismas 5 bandas que suele traer el
/// efecto de Android, así los presets se ven y suenan parecido.
class MpvEqualizerController implements EqualizerController {
  MpvEqualizerController(this._player);

  final Player _player;
  final _store = EqualizerStore();

  static const _frequencies = [60.0, 230.0, 910.0, 3600.0, 14000.0];
  static const _minDb = -15.0;
  static const _maxDb = 15.0;

  bool _enabled = false;
  final List<double> _gains = List.filled(_frequencies.length, 0.0);

  /// Restaura lo guardado la última vez (como hace MyAudioHandler con el
  /// efecto de Android al arrancar).
  Future<void> restore() async {
    _enabled = await _store.getEnabled();
    final saved = await _store.getGains();
    for (final entry in saved.entries) {
      if (entry.key >= 0 && entry.key < _gains.length) {
        _gains[entry.key] = entry.value.clamp(_minDb, _maxDb).toDouble();
      }
    }
    await _apply();
  }

  @override
  bool get enabled => _enabled;

  @override
  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    await _apply();
  }

  @override
  Future<EqualizerParameters> get parameters async => EqualizerParameters(
        minDecibels: _minDb,
        maxDecibels: _maxDb,
        bands: [
          for (var i = 0; i < _frequencies.length; i++)
            EqualizerBandInfo(
              index: i,
              centerFrequency: _frequencies[i],
              gain: _gains[i],
            ),
        ],
      );

  @override
  Future<void> setBandGain(int index, double gain) async {
    if (index < 0 || index >= _gains.length) return;
    _gains[index] = gain.clamp(_minDb, _maxDb).toDouble();
    await _apply();
  }

  Future<void> _apply() async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    final active = _enabled && _gains.any((g) => g.abs() >= 0.05);
    final filter = active
        ? 'lavfi=[${[
            for (var i = 0; i < _frequencies.length; i++)
              'equalizer=f=${_frequencies[i].round()}:t=o:w=1.4:g=${_gains[i].toStringAsFixed(1)}',
          ].join(',')}]'
        : '';
    await platform.setProperty('af', filter);
  }
}
