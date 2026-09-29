#ifndef RUNNER_MIDI_PLUGIN_H_
#define RUNNER_MIDI_PLUGIN_H_

#include <flutter/plugin_registrar_windows.h>

// Controladores DJ por MIDI (Modo DJ), con la API MIDI de Windows (WinMM):
// canal tk_music/midi.
//  - devices() -> {inputs: [nombre], outputs: [nombre]}.
//  - open({input, output}) abre por nombre (los números cambian al
//    enchufar/desenchufar). Los mensajes que llegan salen por el canal de
//    eventos tk_music/midi/events como listas [status, data1, data2, ...]
//    (de a varios mensajes juntos: los platos mandan cientos por segundo).
//  - send({bytes}) manda mensajes cortos (luces del controlador).
//  - close().
void RegisterMidiPlugin(flutter::PluginRegistrarWindows* registrar);

#endif  // RUNNER_MIDI_PLUGIN_H_
