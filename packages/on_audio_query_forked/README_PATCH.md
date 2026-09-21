# Copia local parchada

Este es `on_audio_query_forked` 2.9.1 (de pub.dev), con un solo cambio: en
`pubspec.yaml`, la plataforma `android` declaraba

```yaml
platforms:
  android:
    default_package: on_audio_query_android
```

pero el paquete real del que depende (y que efectivamente registra la
implementación Android) es `on_audio_query_android_v1_8`, no
`on_audio_query_android`. Ese último ni siquiera aparece en sus
`dependencies:`. El resultado es un falso positivo de Flutter en **cada**
comando (`analyze`, `pub get`, `run`, `build`, etc.):

```
Package on_audio_query_forked:android references on_audio_query_android:android
as the default plugin, but the package does not exist, or is not a plugin package.
```

Es inofensivo (la implementación real igual se registra por depender
directamente de `on_audio_query_android_v1_8`), pero es ruido en cada build.
Se corrigió esa línea a:

```yaml
platforms:
  android:
    default_package: on_audio_query_android_v1_8
```

El proyecto usa esta copia vía `dependency_overrides` en el `pubspec.yaml`
raíz, en vez de la versión de pub.dev.

## Si se actualiza esta copia

Si en algún momento se sube de versión (`on_audio_query_forked` publica un
2.9.2, etc.), hay que repetir el mismo cambio en la nueva copia. El diff
exacto queda guardado en
[`patches/on_audio_query_forked-default_package.patch`](../../patches/on_audio_query_forked-default_package.patch).
Si el paquete corrige esto río arriba, se puede volver a la versión de
pub.dev normal y borrar esta carpeta + el `dependency_overrides`.
