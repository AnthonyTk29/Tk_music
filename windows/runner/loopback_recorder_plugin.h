#ifndef RUNNER_LOOPBACK_RECORDER_PLUGIN_H_
#define RUNNER_LOOPBACK_RECORDER_PLUGIN_H_

#include <flutter/plugin_registrar_windows.h>

// "Grabar mezcla" del Modo DJ, canal tk_music/loopback_recorder: graba lo
// que sale por la salida de audio predeterminada de Windows (captura
// "loopback" de WASAPI) a un WAV estéreo de 16 bits. Es exactamente lo que
// se escucha: deck A a la izquierda, deck B a la derecha, con crossfader,
// ecualizador y master aplicados.
//  - start({path, deviceId}) -> {sampleRate, channels} o error (sin
//    deviceId, la salida predeterminada).
//  - stop() -> {path, durationMs, bytes}.
//  - status() -> {recording, durationMs, peak, error}.
void RegisterLoopbackRecorderPlugin(flutter::PluginRegistrarWindows* registrar);

#endif  // RUNNER_LOOPBACK_RECORDER_PLUGIN_H_
