import 'package:flutter/material.dart';

import 'package:tk_music/presentation/widgets/dj/dj_controls.dart';
import 'package:tk_music/services/dj/dj_controller.dart';

/// Dónde están conectados los parlantes.
enum DjSpeakers { computer, controller }

/// Lo que se eligió en "Nuevo dispositivo detectado".
typedef DjControllerChoice = ({DjSpeakers speakers, bool dontShowAgain});

const _dialogBg = Color(0xFF3A3D42);
const _titleBg = Color(0xFF26282C);
const _selected = Color(0xFF5B7FAE);

/// La ventana que aparece al enchufar un controlador conocido, como la de
/// VirtualDJ: el equipo detectado y dónde están los parlantes.
class DjControllerDetectedDialog extends StatefulWidget {
  const DjControllerDetectedDialog({
    super.key,
    required this.profile,
    required this.controllerAudioFound,
    this.initial = DjSpeakers.computer,
  });

  final DjControllerProfile profile;

  /// Windows ve la placa de sonido del controlador.
  final bool controllerAudioFound;
  final DjSpeakers initial;

  static Future<DjControllerChoice?> show(
    BuildContext context, {
    required DjControllerProfile profile,
    required bool controllerAudioFound,
    DjSpeakers initial = DjSpeakers.computer,
  }) =>
      showDialog<DjControllerChoice>(
        context: context,
        builder: (_) => DjControllerDetectedDialog(
          profile: profile,
          controllerAudioFound: controllerAudioFound,
          initial: initial,
        ),
      );

  @override
  State<DjControllerDetectedDialog> createState() =>
      _DjControllerDetectedDialogState();
}

class _DjControllerDetectedDialogState
    extends State<DjControllerDetectedDialog> {
  late DjSpeakers _speakers = widget.initial;
  bool _dontShow = false;

  bool get _canUseController =>
      widget.profile.hasSoundCard && widget.controllerAudioFound;

  @override
  void initState() {
    super.initState();
    if (!_canUseController) _speakers = DjSpeakers.computer;
  }

  void _close() => Navigator.of(context)
      .pop((speakers: _speakers, dontShowAgain: _dontShow));

  Widget _choice(DjSpeakers value, String label, {String? disabledHint}) {
    final enabled = disabledHint == null;
    final selected = _speakers == value;
    final button = InkWell(
      onTap: enabled ? () => setState(() => _speakers = value) : null,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? _selected : const Color(0xFF2F3236),
          border:
              Border.all(color: selected ? _selected : const Color(0xFF5A5E64)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.volume_up,
                size: 18, color: enabled ? Colors.white70 : Colors.white24),
            const SizedBox(width: 10),
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: enabled ? Colors.white : Colors.white30,
                      fontSize: 16)),
            ),
          ],
        ),
      ),
    );
    return Expanded(
      child: disabledHint == null
          ? button
          : Tooltip(message: disabledHint, child: button),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    return Dialog(
      backgroundColor: _dialogBg,
      shape: const RoundedRectangleBorder(),
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: _titleBg,
              height: 40,
              padding: const EdgeInsets.only(left: 16),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('NUEVO DISPOSITIVO DETECTADO',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5)),
                  ),
                  IconButton(
                    tooltip: 'Cerrar',
                    onPressed: _close,
                    icon: const Icon(Icons.close,
                        color: Colors.white70, size: 20),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const Center(
              child: SizedBox(
                width: 220,
                height: 96,
                child: CustomPaint(painter: DjControllerPainter()),
              ),
            ),
            const SizedBox(height: 22),
            const Text('EQUIPO DETECTADO',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 15)),
            const SizedBox(height: 2),
            Text(profile.displayName,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5)),
            const SizedBox(height: 32),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text('Seleccioná dónde están conectados tus altavoces',
                  style: TextStyle(color: Colors.white, fontSize: 16)),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  _choice(DjSpeakers.computer, 'Computador'),
                  const SizedBox(width: 40),
                  _choice(
                    DjSpeakers.controller,
                    profile.shortName,
                    disabledHint: !profile.hasSoundCard
                        ? 'Este controlador no tiene placa de sonido: los '
                            'altavoces van a la computadora.'
                        : !widget.controllerAudioFound
                            ? 'Windows no muestra la placa de sonido del '
                                '${profile.shortName}. Probá desenchufarlo y '
                                'volver a enchufarlo.'
                            : null,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 40),
            Padding(
              padding: const EdgeInsets.fromLTRB(170, 0, 8, 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 100,
                    height: 34,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        backgroundColor: const Color(0xFF55595F),
                        foregroundColor: Colors.white,
                        shape: const RoundedRectangleBorder(),
                      ),
                      onPressed: _close,
                      child: const Text('OK', style: TextStyle(fontSize: 16)),
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: InkWell(
                      onTap: () => setState(() => _dontShow = !_dontShow),
                      child: Row(
                        children: [
                          Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              color: const Color(0xFF26282C),
                              border: Border.all(color: Colors.white38),
                            ),
                            child: _dontShow
                                ? const Icon(Icons.check,
                                    size: 16, color: Colors.white)
                                : null,
                          ),
                          const SizedBox(width: 8),
                          const Flexible(
                            child: Text('No mostrar de nuevo',
                                style: TextStyle(
                                    color: Colors.white, fontSize: 15)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Un controlador DJ dibujado (dos platos, pads y el mezclador al medio).
class DjControllerPainter extends CustomPainter {
  const DjControllerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    // Cuerpo en perspectiva leve.
    final body = Path()
      ..moveTo(w * 0.04, h * 0.18)
      ..lineTo(w * 0.96, h * 0.18)
      ..lineTo(w, h * 0.9)
      ..lineTo(0, h * 0.9)
      ..close();
    canvas.drawPath(
        body.shift(const Offset(0, 4)),
        Paint()
          ..color = Colors.black54
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    canvas.drawPath(
        body,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF55585E), Color(0xFF2A2C30)],
          ).createShader(Offset.zero & size));
    canvas.drawRect(Rect.fromLTWH(0, h * 0.9, w, h * 0.06),
        Paint()..color = const Color(0xFF1B1C1F));

    void jog(double cx) {
      final c = Offset(cx, h * 0.44);
      final r = h * 0.24;
      canvas.drawOval(
          Rect.fromCenter(center: c, width: r * 2.3, height: r * 1.5),
          Paint()..color = const Color(0xFFB9BDC3));
      canvas.drawOval(
          Rect.fromCenter(center: c, width: r * 1.9, height: r * 1.2),
          Paint()..color = const Color(0xFF1E1F22));
      canvas.drawOval(
          Rect.fromCenter(center: c, width: r * 0.7, height: r * 0.45),
          Paint()..color = const Color(0xFF9EA3AA));
    }

    jog(w * 0.2);
    jog(w * 0.8);

    // Pads.
    void pads(double left, Color color) {
      for (var row = 0; row < 2; row++) {
        for (var i = 0; i < 4; i++) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
                Rect.fromLTWH(left + i * w * 0.058, h * (0.7 + row * 0.08),
                    w * 0.048, h * 0.06),
                const Radius.circular(1.5)),
            Paint()..color = color.withValues(alpha: row == 0 ? 1 : 0.8),
          );
        }
      }
    }

    pads(w * 0.06, const Color(0xFFD9443B));
    pads(w * 0.71, const Color(0xFFD9443B));

    // Mezclador: perillas y faders.
    final knob = Paint()..color = const Color(0xFF15161A);
    for (var row = 0; row < 3; row++) {
      for (final x in [0.43, 0.5, 0.57]) {
        canvas.drawCircle(
            Offset(w * x, h * (0.28 + row * 0.1)), h * 0.035, knob);
      }
    }
    final slot = Paint()..color = const Color(0xFF111214);
    for (final x in [0.44, 0.56]) {
      canvas.drawRect(Rect.fromLTWH(w * x - 1, h * 0.56, 2, h * 0.2), slot);
      canvas.drawRect(Rect.fromLTWH(w * x - 4, h * 0.64, 8, h * 0.05),
          Paint()..color = const Color(0xFFDADDE1));
    }
    canvas.drawRect(Rect.fromLTWH(w * 0.44, h * 0.83, w * 0.12, 2), slot);
    canvas.drawRect(Rect.fromLTWH(w * 0.49, h * 0.8, w * 0.02, h * 0.07),
        Paint()..color = const Color(0xFFDADDE1));
    // Pitch.
    for (final x in [0.35, 0.65]) {
      canvas.drawRect(Rect.fromLTWH(w * x - 1, h * 0.3, 2, h * 0.36), slot);
    }
  }

  @override
  bool shouldRepaint(DjControllerPainter oldDelegate) => false;
}

/// Estado del controlador conectado: parlantes, pitch, qué hace cada
/// control y un monitor de lo que va llegando.
class DjControllerPanel extends StatelessWidget {
  const DjControllerPanel({
    super.key,
    required this.hub,
    required this.speakers,
    required this.controllerAudioFound,
    required this.onSpeakers,
  });

  final DjControllerHub hub;
  final DjSpeakers speakers;
  final bool controllerAudioFound;
  final ValueChanged<DjSpeakers> onSpeakers;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: DjColors.panel,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: DjColors.border),
      ),
      child: SizedBox(
        width: size.width.clamp(0, 920).toDouble(),
        height: (size.height - 48).clamp(0, 760).toDouble(),
        child: ListenableBuilder(
          listenable:
              Listenable.merge([hub, if (hub.mapping != null) hub.mapping!]),
          builder: (context, _) {
            final profile = hub.profile;
            final mapping = hub.mapping;
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 8, 6),
                  child: Row(
                    children: [
                      const Icon(Icons.settings_input_component,
                          color: DjColors.text),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          profile == null
                              ? 'Controlador desconectado'
                              : profile.shortName,
                          style: const TextStyle(
                              color: DjColors.text,
                              fontSize: 18,
                              fontWeight: FontWeight.w800),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Cerrar',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close, color: DjColors.muted),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        flex: 3,
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(20, 0, 12, 20),
                          children: [
                            if (profile != null) ...[
                              Text(
                                hub.lights
                                    ? 'Conectado, con luces.'
                                    : 'Conectado (sin luces: Windows no dio '
                                        'la salida MIDI del controlador).',
                                style: const TextStyle(color: DjColors.muted),
                              ),
                              const SizedBox(height: 14),
                              const _Label('ALTAVOCES'),
                              const SizedBox(height: 6),
                              SegmentedButton<DjSpeakers>(
                                segments: [
                                  const ButtonSegment(
                                    value: DjSpeakers.computer,
                                    icon: Icon(Icons.computer),
                                    label: Text('Computador'),
                                  ),
                                  ButtonSegment(
                                    value: DjSpeakers.controller,
                                    icon: const Icon(Icons.volume_up),
                                    label: Text(profile.shortName),
                                    enabled: profile.hasSoundCard &&
                                        controllerAudioFound,
                                  ),
                                ],
                                selected: {speakers},
                                onSelectionChanged: (s) {
                                  onSpeakers(s.first);
                                  Navigator.of(context).pop();
                                },
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                'Con los altavoces en el controlador, el sonido '
                                'sale por su salida MASTER (parlantes). La de '
                                'auriculares todavía no se usa. "Grabar mezcla" '
                                'graba la salida elegida.',
                                style: TextStyle(
                                    color: DjColors.muted, fontSize: 12),
                              ),
                              const SizedBox(height: 10),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                value: hub.invertPitch,
                                onChanged: hub.setInvertPitch,
                                title: const Text('Invertir el fader de pitch',
                                    style: TextStyle(color: DjColors.text)),
                                subtitle: const Text(
                                    'Si al subir el fader la canción se apura '
                                    'en vez de frenarse.',
                                    style: TextStyle(
                                        color: DjColors.muted, fontSize: 12)),
                              ),
                            ],
                            const SizedBox(height: 8),
                            const _Label('QUÉ HACE CADA CONTROL'),
                            const SizedBox(height: 4),
                            for (final (control, what) in mixtrackControlHelp)
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 5),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SizedBox(
                                      width: 170,
                                      child: Text(control,
                                          style: const TextStyle(
                                              color: DjColors.cue,
                                              fontWeight: FontWeight.w700)),
                                    ),
                                    Expanded(
                                      child: Text(what,
                                          style: const TextStyle(
                                              color: DjColors.text,
                                              fontSize: 13)),
                                    ),
                                  ],
                                ),
                              ),
                            const SizedBox(height: 8),
                            const Text(
                              'Los faders y perillas no mandan hasta que su '
                              'posición alcanza la de la pantalla (así el '
                              'volumen no pega saltos al conectar).',
                              style: TextStyle(
                                  color: DjColors.muted, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      Container(width: 1, color: DjColors.border),
                      Expanded(
                        flex: 2,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 0, 16, 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const _Label('MONITOR'),
                              const SizedBox(height: 4),
                              const Text(
                                'Tocá cualquier control del controlador: acá '
                                'aparece qué llegó y qué hizo.',
                                style: TextStyle(
                                    color: DjColors.muted, fontSize: 12),
                              ),
                              const SizedBox(height: 8),
                              Expanded(
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: DjColors.background,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: mapping == null || mapping.log.isEmpty
                                      ? const Center(
                                          child: Text('Esperando…',
                                              style: TextStyle(
                                                  color: DjColors.muted)))
                                      : ListView(
                                          padding: const EdgeInsets.all(8),
                                          children: [
                                            for (final e in mapping.log)
                                              Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        vertical: 2),
                                                child: Row(
                                                  children: [
                                                    SizedBox(
                                                      width: 76,
                                                      child: Text(e.raw,
                                                          style: const TextStyle(
                                                              color: DjColors
                                                                  .muted,
                                                              fontFamily:
                                                                  'Consolas',
                                                              fontSize: 12)),
                                                    ),
                                                    Expanded(
                                                      child: Text(e.action,
                                                          style:
                                                              const TextStyle(
                                                                  color:
                                                                      DjColors
                                                                          .text,
                                                                  fontSize:
                                                                      12.5)),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                          ],
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(
          color: DjColors.text,
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.5));
}
