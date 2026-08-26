import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tk_music/pages/music_player_android_screen.dart';

class RequestPermissionScreen extends StatelessWidget {
  const RequestPermissionScreen({super.key});

  Future<void> _requestPermission(BuildContext context) async {
    try {
      PermissionStatus status;

      // Detectar versión de Android
      final version = (await DeviceInfoPlugin().androidInfo).version.sdkInt;

      if (version >= 13) {
        status = await Permission.audio.request();
        await Permission.notification.request();

        // Si no está concedido, no lances otro request de inmediato.
        if (!status.isGranted) {
          // En lugar de hacer otro request aquí, mejor consulta el estado
          status = await Permission.mediaLibrary.status;
        }
      } else {
        status = await Permission.storage.request();
      }

      // 🔄 Verificar estado final
      final isGranted = (await Permission.audio.status).isGranted ||
          (await Permission.mediaLibrary.status).isGranted ||
          (await Permission.storage.status).isGranted;

      if (isGranted) {
        if (context.mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => const MusicPlayerScreen()),
          );
        }
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Permiso denegado')),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al solicitar permiso: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF182848),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.lock, color: Colors.white, size: 80),
              const SizedBox(height: 24),
              const Text('Permiso requerido',
                  style: TextStyle(color: Colors.white, fontSize: 24)),
              const SizedBox(height: 12),
              const Text(
                'Para acceder a tu música, necesitamos permiso de almacenamiento o audio.',
                style: TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 30),
              ElevatedButton.icon(
                icon: const Icon(Icons.vpn_key),
                label: const Text('Solicitar permiso'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent),
                onPressed: () => _requestPermission(context),
              )
            ],
          ),
        ),
      ),
    );
  }
}
