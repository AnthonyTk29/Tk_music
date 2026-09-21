# Tk_music

Reproductor de música para Android con reproducción en segundo plano
(notificación, controles desde pantalla bloqueada y botones de auriculares).

## Requisitos

- Flutter 3.27 o superior (probado con 3.32.0)
- JDK 17 o 21
- Android SDK con `compileSdk` 35
- `minSdk` 24 (lo exige `audio_session` 0.2.x)

## ⚠️ Rutas con espacios (parche del SDK, no del proyecto)

El plugin de Gradle de Flutter 3.32 (`FlutterTaskHelper.kt`) desescapa mal las
rutas del archivo de dependencias `.d` en Windows: busca `\\ ` (doble backslash)
en vez de `\ ` (backslash simple), que es lo que realmente usa ese formato para
escapar un espacio. El resultado es que una ruta con espacios como
`...\USER A1\...` queda con un backslash suelto y el build falla con errores
del tipo *"ancestor ... is not a directory"*.

**Este bug está parcheado en el Flutter SDK instalado en esta máquina**
(`C:\Users\USER A1\Documents\flutter_3.32.0`), no en este repositorio — un
`flutter upgrade`, una reinstalación o compilar en otra máquina lo revierte.
El parche exacto está guardado en [`patches/flutter-sdk-space-path.patch`](patches/flutter-sdk-space-path.patch)
para poder reaplicarlo:

```bash
cd "C:\Users\USER A1\Documents\flutter_3.32.0"
git apply "C:\ruta\al\proyecto\tk_music\patches\flutter-sdk-space-path.patch"
```

La alternativa definitiva es mover el proyecto a una ruta sin espacios
(por ejemplo `C:\Proyectos\tk_music`), con lo que este parche deja de hacer falta.

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
bug propio en su `pubspec.yaml`: declara `default_package: on_audio_query_android`
(un paquete que ni siquiera es su dependencia) en vez de `on_audio_query_android_v1_8`
(el que realmente usa). Eso generaba un warning inofensivo pero repetido en cada
comando de Flutter.

Se corrigió con una copia local parchada en [`packages/on_audio_query_forked`](packages/on_audio_query_forked)
(una sola línea cambiada, ver [`README_PATCH.md`](packages/on_audio_query_forked/README_PATCH.md)
y el diff en [`patches/on_audio_query_forked-default_package.patch`](patches/on_audio_query_forked-default_package.patch)),
conectada vía `dependency_overrides` en `pubspec.yaml`.

Si el paquete se corrige río arriba o aparece un reemplazo mantenido, se puede volver
a la versión de pub.dev y borrar la copia local + el override.

## Arquitectura

Clean Architecture con inyección de dependencias vía `get_it` (`lib/core/di`):

```
lib/
├── main.dart                                    # boot: AudioService, DI, providers, shell
├── core/
│   ├── di/service_locator.dart                  # registro de dependencias (GetIt)
│   ├── errors/failures.dart                     # tipos de error del dominio
│   ├── theme/app_theme.dart                      # tema claro/oscuro
│   └── utils/formatters.dart                     # formatDuration()
├── domain/
│   ├── entities/song.dart                        # entidad Song (independiente del plugin)
│   ├── repositories/song_repository.dart         # contrato del repositorio
│   └── usecases/                                 # GetSongs, RequestPermission
├── data/
│   ├── datasources/song_local_datasource.dart    # on_audio_query + permission_handler
│   ├── models/song_mapper.dart                   # SongModel -> Song -> MediaItem
│   └── repositories/song_repository_impl.dart
├── presentation/
│   ├── providers/                                # SongProvider, PermissionProvider (ChangeNotifier)
│   ├── pages/                                     # music_player, now_playing, request_permission
│   └── widgets/                                   # app_providers, mini_player, seek_bar, song_tile, song_artwork
└── services/
    ├── audio_handler.dart                         # AudioHandler (cola, play/pause, seek, shuffle/repeat)
    └── artwork_cache.dart                         # carátulas a disco para la notificación
```

`AppProviders` (en `presentation/widgets/app_providers.dart`) es un `InheritedNotifier`
casero: no se usa el paquete `provider`, sino una implementación propia que combina
`SongProvider` y `PermissionProvider` en un solo `InheritedWidget`.
