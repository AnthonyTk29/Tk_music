#ifndef RUNNER_MEDIA_CONTROLS_PLUGIN_H_
#define RUNNER_MEDIA_CONTROLS_PLUGIN_H_

#include <windows.h>

#include <flutter/plugin_registrar_windows.h>

// Controles multimedia del sistema en Windows (System Media Transport
// Controls): la tarjeta de "lo que está sonando" del panel de volumen/de la
// pantalla de bloqueo y las teclas multimedia del teclado — el equivalente
// a la notificación de reproducción de Android (audio_service).
//  - tk_music/media_controls: update({title, artist, album, playing,
//    positionMs, durationMs, canNext, canPrevious}), clear()
//  - tk_music/media_controls/events: {button: play|pause|next|previous|stop}
void RegisterMediaControlsPlugin(flutter::PluginRegistrarWindows* registrar, HWND window);

#endif  // RUNNER_MEDIA_CONTROLS_PLUGIN_H_
