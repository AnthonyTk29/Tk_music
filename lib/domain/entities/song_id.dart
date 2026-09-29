/// Id numérico estable para una canción que no tiene id de MediaStore (en
/// desktop, o un archivo abierto por su ruta/uri). Favoritos, playlists y
/// recientes guardan este número en disco, así que tiene que dar lo mismo
/// en cada ejecución — `String.hashCode` de Dart no garantiza eso entre
/// versiones. FNV-1a de 32 bits sobre la ruta en minúsculas (en Windows las
/// rutas no distinguen mayúsculas), recortado a 31 bits para que siempre
/// sea positivo.
int stableSongId(String path) {
  var hash = 0x811c9dc5;
  for (final unit in path.toLowerCase().codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash & 0x7FFFFFFF;
}
