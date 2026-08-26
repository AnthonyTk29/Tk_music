import 'package:flutter/foundation.dart';

import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/domain/usecases/request_permission.dart';

class PermissionProvider extends ChangeNotifier {
  PermissionProvider() {
    checkPermission();
  }

  bool? _granted;
  bool? get granted => _granted;

  Future<void> checkPermission() async {
    final (result, _) = await sl<RequestPermission>()();
    _granted = result;
    notifyListeners();
  }
}
