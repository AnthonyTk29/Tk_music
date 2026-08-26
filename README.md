# Tk_music

Reproductor de música para Android con reproducción en segundo plano
(notificación, controles desde pantalla bloqueada y botones de auriculares).

## Requisitos

- Flutter 3.27 o superior (probado con 3.32.0)
- JDK 17 o 21
- Android SDK con `compileSdk` 35
- `minSdk` 24 (lo exige `audio_session` 0.2.x)

## Rutas con espacios

Flutter 3.32 tiene un error al validar rutas con espacios en Windows. El proyecto
incluye una corrección local para ese parser, por lo que puede compilarse desde
esta ubicación. Si se cambia de versión de Flutter, conviene volver a comprobar
el build.

## Compilar

```bash
flutter pub get
flutter build apk --debug
```

## Firma de release

Las credenciales del keystore **no se versionan**. Para generar un release firmado,
copia `android/key.properties.example` a `android/key.properties` y completa los
valores; `android/key.properties` está en `.gitignore`.

Sin ese archivo el build de release funciona igual, pero genera un APK sin firmar.

## Nota sobre `on_audio_query_forked`

El paquete `on_audio_query` original está descontinuado en 2.9.0 y su módulo Android
no declara `namespace`, por lo que no compila con AGP 8.

Se usa `on_audio_query_forked`, cuyo módulo Android (`on_audio_query_android_v1_8`)
sí declara `namespace` y alinea Java/Kotlin en la misma versión. Ese wrapper tiene un
bug: declara `default_package: on_audio_query_android` pero depende de
`on_audio_query_android_v1_8`, así que la implementación Android no se registra sola.
Por eso `on_audio_query_android_v1_8` está listado explícitamente en `pubspec.yaml`.

Si el paquete se corrige o aparece un reemplazo mantenido, esa dependencia extra
se puede quitar.

## Estructura

```
lib/
├── main.dart                              # init de AudioService + chequeo de permisos
├── pages/
│   ├── music_player_android_screen.dart   # lista de canciones + mini reproductor
│   ├── now_playing_screen.dart            # pantalla completa de reproducción
│   └── request_permission.dart            # pantalla de permiso denegado
├── services/
│   ├── audio_handler.dart                 # AudioHandler (cola, play/pause, seek, skip)
│   └── artwork_cache.dart                 # carátulas a disco para la notificación
└── widgets/
    ├── mini_player.dart                   # barra inferior persistente
    ├── seek_bar.dart                      # slider de progreso + tiempos
    └── song_artwork.dart                  # carátula con placeholder
```
