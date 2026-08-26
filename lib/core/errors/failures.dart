sealed class Failure {
  const Failure(this.message);
  final String message;
}

class PermissionFailure extends Failure {
  const PermissionFailure([super.message = 'Permiso denegado']);
}

class SongQueryFailure extends Failure {
  const SongQueryFailure([super.message = 'Error al consultar canciones']);
}

class PlaybackFailure extends Failure {
  const PlaybackFailure([super.message = 'Error de reproducción']);
}
