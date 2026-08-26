import 'package:tk_music/core/errors/failures.dart';

import '../repositories/song_repository.dart';

class RequestPermission {
  const RequestPermission(this._repository);
  final SongRepository _repository;

  Future<(bool, Failure?)> call() async {
    try {
      final granted = await _repository.requestPermission();
      return (granted, null);
    } catch (e) {
      return (false, PermissionFailure(e.toString()));
    }
  }
}
