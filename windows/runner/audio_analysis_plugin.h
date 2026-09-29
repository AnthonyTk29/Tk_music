#ifndef RUNNER_AUDIO_ANALYSIS_PLUGIN_H_
#define RUNNER_AUDIO_ANALYSIS_PLUGIN_H_

#include <flutter/plugin_registrar_windows.h>

// Análisis de audio para Windows — espejo de lo que hace MainActivity.kt en
// Android, con los mismos canales, métodos y formato de respuesta, para que
// WaveformStore/SpectrogramStore/LoudnessStore no sepan en qué plataforma
// corren:
//  - tk_music/audio_analysis: analyzeLoudness, analyzeWaveform
//    (+ eventos en tk_music/audio_analysis/waveform_progress)
//  - tk_music/spectrum_analysis: analyzeSpectrogram
//    (+ eventos en tk_music/spectrum_analysis/progress)
// Decodifica el PCM con Media Foundation (el decodificador del sistema:
// MP3, AAC/M4A, WAV, FLAC, WMA) en hilos de fondo.
void RegisterAudioAnalysisPlugin(flutter::PluginRegistrarWindows* registrar);

#endif  // RUNNER_AUDIO_ANALYSIS_PLUGIN_H_
