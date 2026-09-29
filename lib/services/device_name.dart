import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

/// Cómo se llama este equipo para los demás (lista de anfitriones,
/// reacciones): el modelo del teléfono o el nombre de la PC. `null` si no
/// se puede saber.
Future<String?> localDeviceName() async {
  try {
    final info = DeviceInfoPlugin();
    final name = Platform.isAndroid
        ? (await info.androidInfo).model
        : Platform.isWindows
            ? (await info.windowsInfo).computerName
            : Platform.localHostname;
    return name.isEmpty ? null : name;
  } catch (_) {
    return null;
  }
}
