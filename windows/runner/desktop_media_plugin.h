#ifndef RUNNER_DESKTOP_MEDIA_PLUGIN_H_
#define RUNNER_DESKTOP_MEDIA_PLUGIN_H_

#include <flutter/plugin_registrar_windows.h>

// Metadatos de archivos de audio en Windows, canal tk_music/desktop_media:
//  - readTags({paths}): título/artista/álbum/género/duración de cada archivo,
//    leídos del sistema de propiedades de Windows (lo mismo que muestra el
//    Explorador) — en Android esto lo da MediaStore.
//  - artwork({path, size}): carátula embebida como JPEG (o null), vía la
//    miniatura del Shell — en Android sale de MediaStore/on_audio_query.
//  - audioInfo({paths}): bitrate, frecuencia, canales, bits y duración de
//    cada archivo (calidad, para el gestor de archivos del Modo DJ).
//  - recycle({paths}): manda cada archivo a la Papelera de reciclaje;
//    devuelve true/false por archivo.
void RegisterDesktopMediaPlugin(flutter::PluginRegistrarWindows* registrar);

#endif  // RUNNER_DESKTOP_MEDIA_PLUGIN_H_
