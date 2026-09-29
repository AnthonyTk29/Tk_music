import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:tk_music/presentation/widgets/app_header.dart';
import 'package:tk_music/core/platform.dart';
import 'package:tk_music/services/qr_image_decoder.dart';
import 'package:tk_music/services/sync_invite.dart';

/// Escanea el QR que muestra el anfitrión y devuelve la invitación leída
/// (o `null` si se volvió atrás). Solo acepta QR de TK Music: si ve otro,
/// avisa y sigue buscando.
///
/// En Android usa el lector en vivo de la cámara; en Windows (donde no
/// existe) saca fotos seguidas con la cámara y las decodifica. En los dos
/// se puede elegir una imagen del QR (p. ej. una captura que te mandaron).
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  bool _done = false;
  String? _hint;

  static bool get _liveScanner => hasLiveQrScanner;

  final MobileScannerController? _scanner = _liveScanner
      ? MobileScannerController(formats: const [BarcodeFormat.qrCode])
      : null;

  @override
  void dispose() {
    _scanner?.dispose();
    super.dispose();
  }

  void _onText(String? text) {
    if (_done || text == null || !mounted) return;
    final invite = SyncInvite.parse(text);
    if (invite == null) {
      setState(() => _hint = 'Ese QR no es de una sala de TK Music.');
      return;
    }
    _done = true;
    Navigator.of(context).pop(invite);
  }

  Future<void> _pickImage() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
      dialogTitle: 'Elegí la imagen del QR',
      withData: true,
    );
    final file = picked?.files.single;
    if (file == null || !mounted) return;
    final text = await decodeQrInBackground(bytes: file.bytes, path: file.path);
    if (!mounted) return;
    if (text == null) {
      setState(() => _hint = 'No se encontró un QR en esa imagen.');
      return;
    }
    _onText(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const AppHeaderTitle(section: 'Unirse con QR')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  'Apuntá la cámara al QR que muestra el anfitrión en '
                  '"Sincronizar con otro dispositivo".',
                  style: theme.textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: _scanner != null
                        ? MobileScanner(
                            controller: _scanner,
                            onDetect: (capture) {
                              for (final code in capture.barcodes) {
                                _onText(code.rawValue);
                                if (_done) return;
                              }
                            },
                            errorBuilder: (context, error) => _CameraMessage(
                              text: error.errorCode ==
                                      MobileScannerErrorCode.permissionDenied
                                  ? 'Hace falta el permiso de la cámara para '
                                      'leer el QR.'
                                  : 'No se pudo abrir la cámara.',
                            ),
                          )
                        : _DesktopCameraScanner(onText: _onText),
                  ),
                ),
                if (_hint != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _hint!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _pickImage,
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('Elegir una imagen del QR'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Cámara en Windows: vista previa y una foto cada poco, que se decodifica
/// aparte hasta encontrar el QR.
class _DesktopCameraScanner extends StatefulWidget {
  const _DesktopCameraScanner({required this.onText});

  final void Function(String? text) onText;

  @override
  State<_DesktopCameraScanner> createState() => _DesktopCameraScannerState();
}

class _DesktopCameraScannerState extends State<_DesktopCameraScanner> {
  int? _cameraId;
  double _aspect = 4 / 3;
  String? _error;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _disposed = true;
    final id = _cameraId;
    if (id != null) unawaited(CameraPlatform.instance.dispose(id));
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final cameras = await CameraPlatform.instance.availableCameras();
      if (cameras.isEmpty) {
        _fail('No se encontró una cámara. Podés elegir una imagen del QR.');
        return;
      }
      final camera = cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cameras.first);
      final id = await CameraPlatform.instance.createCameraWithSettings(
        camera,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );
      if (_disposed) {
        await CameraPlatform.instance.dispose(id);
        return;
      }
      _cameraId = id;
      final initialized = CameraPlatform.instance.onCameraInitialized(id).first;
      await CameraPlatform.instance.initializeCamera(id);
      final event = await initialized.timeout(const Duration(seconds: 5));
      if (!mounted) return;
      setState(() {
        if (event.previewWidth > 0 && event.previewHeight > 0) {
          _aspect = event.previewWidth / event.previewHeight;
        }
      });
      await _scanLoop(id);
    } catch (e) {
      _fail('No se pudo abrir la cámara. Revisá que Windows le permita a las '
          'apps usarla (Configuración → Privacidad → Cámara), o elegí una '
          'imagen del QR.');
    }
  }

  Future<void> _scanLoop(int id) async {
    while (!_disposed) {
      try {
        final shot = await CameraPlatform.instance.takePicture(id);
        final text = await decodeQrInBackground(
            bytes: await shot.readAsBytes(), path: shot.path, deleteFile: true);
        if (_disposed) return;
        if (text != null) widget.onText(text);
      } catch (_) {
        // Una foto que falló: se prueba con la siguiente.
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  void _fail(String message) {
    if (mounted) setState(() => _error = message);
  }

  @override
  Widget build(BuildContext context) {
    final id = _cameraId;
    if (_error != null) return _CameraMessage(text: _error!);
    if (id == null) return const Center(child: CircularProgressIndicator());
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: AspectRatio(
          aspectRatio: _aspect,
          child: CameraPlatform.instance.buildPreview(id),
        ),
      ),
    );
  }
}

class _CameraMessage extends StatelessWidget {
  const _CameraMessage({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.no_photography_outlined,
                  size: 40, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(text, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
