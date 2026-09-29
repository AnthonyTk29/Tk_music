import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:tk_music/presentation/widgets/dj/dj_controls.dart';

/// Lo que puede hacer una tecla en el Modo DJ.
enum DjCommand {
  cue,
  play,
  sync,
  autoSync,
  keySync,
  keyReset,
  pad,
  padClear,
  padMode,
  pitchDown,
  pitchUp,
  pitchReset,
  pitchRange,
  keylock,
  semitoneDown,
  semitoneUp,
  load,
  testOutput,
  crossfaderLeft,
  crossfaderRight,
  crossfaderFullLeft,
  crossfaderFullRight,
  crossfaderCenter,
  masterDown,
  masterUp,
  autoMix,
  mixBeats,
  files,
  toggleMixer,
  record,
  help,
  equalizer,
  autoDj,
}

/// Una tecla (física: por su lugar en el teclado, así funciona igual con
/// teclado español o inglés) y lo que hace.
class DjKeyBinding {
  const DjKeyBinding(
    this.key,
    this.command, {
    this.deck,
    this.shift = false,
    this.alt = false,
    this.arg = 0,
    this.repeats = false,
  });

  final PhysicalKeyboardKey key;
  final DjCommand command;

  /// 0 = deck A, 1 = deck B, `null` = mezclador / general.
  final int? deck;
  final bool shift;
  final bool alt;

  /// Número de pad (0–7) o pulsos de la mezcla automática.
  final int arg;

  /// Si mantener apretada la tecla repite la acción (pitch, crossfader…).
  final bool repeats;
}

typedef _K = PhysicalKeyboardKey;

/// Las teclas de cada deck, con la misma forma para los dos: el deck A usa
/// la mitad izquierda del teclado y el deck B la derecha.
class _DeckKeys {
  const _DeckKeys({
    required this.pads,
    required this.padMode,
    required this.transport,
    required this.pitch,
    required this.bottom,
  });

  /// Pads 1–4 (con Shift, 5–8).
  final List<_K> pads;
  final _K padMode;

  /// CUE, PLAY, SYNC, AUTO, TONO.
  final List<_K> transport;

  /// Pitch −, pitch +, pitch 0, rango, FIJO.
  final List<_K> pitch;

  /// Semitono b, semitono #, CARGAR, probar salida.
  final List<_K> bottom;
}

const _deckKeys = [
  _DeckKeys(
    pads: [_K.digit1, _K.digit2, _K.digit3, _K.digit4],
    padMode: _K.digit5,
    transport: [_K.keyQ, _K.keyW, _K.keyE, _K.keyR, _K.keyT],
    pitch: [_K.keyA, _K.keyS, _K.keyD, _K.keyF, _K.keyG],
    bottom: [_K.keyZ, _K.keyX, _K.keyC, _K.keyV],
  ),
  _DeckKeys(
    pads: [_K.digit7, _K.digit8, _K.digit9, _K.digit0],
    padMode: _K.digit6,
    transport: [_K.keyY, _K.keyU, _K.keyI, _K.keyO, _K.keyP],
    // La tecla de la Ñ (en teclado inglés, el punto y coma).
    pitch: [_K.keyH, _K.keyJ, _K.keyK, _K.keyL, _K.semicolon],
    bottom: [_K.keyN, _K.keyM, _K.comma, _K.period],
  ),
];

List<DjKeyBinding> _buildBindings() {
  final out = <DjKeyBinding>[];
  for (var deck = 0; deck < 2; deck++) {
    final keys = _deckKeys[deck];
    for (var i = 0; i < 4; i++) {
      out
        ..add(DjKeyBinding(keys.pads[i], DjCommand.pad, deck: deck, arg: i))
        ..add(DjKeyBinding(keys.pads[i], DjCommand.pad,
            deck: deck, arg: i + 4, shift: true))
        ..add(DjKeyBinding(keys.pads[i], DjCommand.padClear,
            deck: deck, arg: i, alt: true))
        ..add(DjKeyBinding(keys.pads[i], DjCommand.padClear,
            deck: deck, arg: i + 4, alt: true, shift: true));
    }
    out.add(DjKeyBinding(keys.padMode, DjCommand.padMode, deck: deck));
    const transport = [
      DjCommand.cue,
      DjCommand.play,
      DjCommand.sync,
      DjCommand.autoSync,
      DjCommand.keySync,
    ];
    for (var i = 0; i < 5; i++) {
      out.add(DjKeyBinding(keys.transport[i], transport[i], deck: deck));
    }
    out.add(DjKeyBinding(keys.transport[4], DjCommand.keyReset,
        deck: deck, shift: true));
    out
      ..add(DjKeyBinding(keys.pitch[0], DjCommand.pitchDown,
          deck: deck, repeats: true))
      ..add(DjKeyBinding(keys.pitch[0], DjCommand.pitchDown,
          deck: deck, shift: true, arg: 1, repeats: true))
      ..add(DjKeyBinding(keys.pitch[1], DjCommand.pitchUp,
          deck: deck, repeats: true))
      ..add(DjKeyBinding(keys.pitch[1], DjCommand.pitchUp,
          deck: deck, shift: true, arg: 1, repeats: true))
      ..add(DjKeyBinding(keys.pitch[2], DjCommand.pitchReset, deck: deck))
      ..add(DjKeyBinding(keys.pitch[3], DjCommand.pitchRange, deck: deck))
      ..add(DjKeyBinding(keys.pitch[4], DjCommand.keylock, deck: deck))
      ..add(DjKeyBinding(keys.bottom[0], DjCommand.semitoneDown, deck: deck))
      ..add(DjKeyBinding(keys.bottom[1], DjCommand.semitoneUp, deck: deck))
      ..add(DjKeyBinding(keys.bottom[2], DjCommand.load, deck: deck))
      ..add(DjKeyBinding(keys.bottom[3], DjCommand.testOutput, deck: deck));
  }
  out
    ..add(const DjKeyBinding(_K.arrowLeft, DjCommand.crossfaderLeft,
        repeats: true))
    ..add(const DjKeyBinding(_K.arrowRight, DjCommand.crossfaderRight,
        repeats: true))
    ..add(const DjKeyBinding(_K.arrowLeft, DjCommand.crossfaderFullLeft,
        shift: true))
    ..add(const DjKeyBinding(_K.arrowRight, DjCommand.crossfaderFullRight,
        shift: true))
    ..add(const DjKeyBinding(_K.space, DjCommand.crossfaderCenter))
    ..add(const DjKeyBinding(_K.arrowDown, DjCommand.masterDown, repeats: true))
    ..add(const DjKeyBinding(_K.arrowUp, DjCommand.masterUp, repeats: true))
    ..add(const DjKeyBinding(_K.enter, DjCommand.autoMix))
    ..add(const DjKeyBinding(_K.numpadEnter, DjCommand.autoMix))
    ..add(const DjKeyBinding(_K.f5, DjCommand.mixBeats, arg: 8))
    ..add(const DjKeyBinding(_K.f6, DjCommand.mixBeats, arg: 16))
    ..add(const DjKeyBinding(_K.f7, DjCommand.mixBeats, arg: 32))
    ..add(const DjKeyBinding(_K.f1, DjCommand.help))
    ..add(const DjKeyBinding(_K.f2, DjCommand.files))
    ..add(const DjKeyBinding(_K.f3, DjCommand.toggleMixer))
    ..add(const DjKeyBinding(_K.f9, DjCommand.record))
    ..add(const DjKeyBinding(_K.f4, DjCommand.equalizer))
    ..add(const DjKeyBinding(_K.f8, DjCommand.autoDj));
  return out;
}

/// Todas las teclas del Modo DJ.
final List<DjKeyBinding> djKeyBindings = _buildBindings();

/// La acción de [event], o `null` si esa tecla no hace nada en el Modo DJ.
/// Ctrl, Win y AltGr quedan libres (atajos de Windows, caracteres).
DjKeyBinding? djBindingFor(
  KeyEvent event, {
  required bool shift,
  required bool alt,
  required bool control,
  required bool meta,
}) {
  if (control || meta) return null;
  if (event is KeyUpEvent) return null;
  for (final b in djKeyBindings) {
    if (b.key != event.physicalKey || b.shift != shift || b.alt != alt) {
      continue;
    }
    if (event is KeyRepeatEvent && !b.repeats) return null;
    return b;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Ayuda: qué hace cada tecla
// ---------------------------------------------------------------------------

/// Una fila de la ayuda: las teclas (por deck si corresponde), qué hacen y
/// para qué sirve.
class DjShortcutHelp {
  const DjShortcutHelp(this.keysA, this.keysB, this.action, this.purpose);

  /// Las teclas del deck A (o las generales, si [keysB] es `null`).
  final List<String> keysA;
  final List<String>? keysB;
  final String action;
  final String purpose;
}

const djDeckShortcutHelp = [
  DjShortcutHelp(
      ['1', '2', '3', '4'],
      ['7', '8', '9', '0'],
      'Pads 1 a 4',
      'Tocan los pads de abajo del deck según el modo elegido: en PUNTOS '
          'saltan al punto guardado (o lo marcan si está vacío), en BUCLE '
          'arman un bucle de 1, 2, 4 u 8 pulsos y en SALTO mueven la canción '
          '16, 8, 4 o 1 pulsos para atrás.'),
  DjShortcutHelp(
      ['Shift', '1…4'],
      ['Shift', '7…0'],
      'Pads 5 a 8',
      'La fila de abajo de los pads: puntos 5 a 8; bucle de 16, bucle '
          'automático, bucle a la mitad y al doble; o saltos de 1, 4, 8 y '
          '16 pulsos para adelante.'),
  DjShortcutHelp(
      ['Alt', '1…4'],
      ['Alt', '7…0'],
      'Borrar un punto',
      'Borra el punto guardado 1 a 4 (con Shift, del 5 al 8), en cualquier '
          'modo. Es lo mismo que el clic derecho sobre el pad en PUNTOS.'),
  DjShortcutHelp(
      ['5'],
      ['6'],
      'Cambiar el modo de los pads',
      'Pasa de PUNTOS a BUCLE, a SALTO y vuelve a empezar, para que los '
          'mismos números hagan otra cosa.'),
  DjShortcutHelp(
      ['Q'],
      ['Y'],
      'CUE',
      'Sonando: vuelve al punto de inicio y frena, para arrancar justo ahí. '
          'Frenado: marca ese punto en el pulso más cercano.'),
  DjShortcutHelp(['W'], ['U'], 'PLAY / pausa', 'Arranca o frena el deck.'),
  DjShortcutHelp(
      ['E'],
      ['I'],
      'SYNC',
      'Iguala el BPM con el otro deck y alinea los pulsos, para que las dos '
          'canciones vayan juntas.'),
  DjShortcutHelp(
      ['R'],
      ['O'],
      'AUTO (sincronía automática)',
      'Prende o apaga el seguimiento continuo: el deck sigue solo el tempo '
          'del otro y no se desfasa.'),
  DjShortcutHelp(
      ['T'],
      ['P'],
      'TONO (tonalidad)',
      'Sube o baja el tono para que combine con la tonalidad del otro deck '
          'y la mezcla no desafine.'),
  DjShortcutHelp(['Shift', 'T'], ['Shift', 'P'], 'Tonalidad original',
      'Deja la canción en su tono de siempre.'),
  DjShortcutHelp(
      ['A', 'S'],
      ['H', 'J'],
      'Pitch − / +',
      'Baja o sube la velocidad 0,1 % por toque (con Shift, 1 %). '
          'Manteniendo apretado sigue moviendo. Sirve para emparejar el tempo '
          'a oído.'),
  DjShortcutHelp(['D'], ['K'], 'Pitch a 0',
      'Vuelve a la velocidad original de la canción.'),
  DjShortcutHelp(
      ['F'],
      ['L'],
      'Rango del pitch',
      'Cambia el recorrido del pitch entre ±8, ±16 y ±32 %: chico para '
          'ajustes finos, grande para cambios de tempo fuertes.'),
  DjShortcutHelp(
      ['G'],
      ['Ñ'],
      'FIJO (mantener el tono)',
      'Con FIJO prendido, al cambiar el tempo la voz no se pone aguda ni '
          'grave.'),
  DjShortcutHelp(['Z', 'X'], ['N', 'M'], 'Semitono b / #',
      'Baja o sube el tono de a un semitono, a mano.'),
  DjShortcutHelp(['C'], [','], 'CARGAR',
      'Abre el gestor de archivos para elegir la canción de ese deck.'),
  DjShortcutHelp(
      ['V'],
      ['.'],
      'Probar la salida',
      'Suena un pitido solo por el lado de ese deck (A izquierda, B derecha) '
          'para comprobar las conexiones.'),
];

const djMixerShortcutHelp = [
  DjShortcutHelp(
      ['←', '→'],
      null,
      'Crossfader',
      'Lo mueve hacia el deck A o el B, de a poco (manteniendo apretado '
          'sigue). Si hay una mezcla automática en curso, la cancela.'),
  DjShortcutHelp(['Shift', '← →'], null, 'Crossfader al extremo',
      'Deja sonando solo el deck A o solo el B.'),
  DjShortcutHelp(['Espacio'], null, 'Crossfader al centro',
      'Los dos decks suenan igual de fuerte.'),
  DjShortcutHelp(['↑', '↓'], null, 'Volumen general',
      'Sube o baja el MASTER (hasta +6 dB para potenciar).'),
  DjShortcutHelp(
      ['Intro'],
      null,
      'MEZCLA AUTO',
      'Pasa al otro deck solo: lo sincroniza, lo arranca en el próximo '
          'compás y mueve el crossfader. Otra vez Intro la cancela.'),
  DjShortcutHelp(['F5', 'F6', 'F7'], null, 'Largo de la mezcla',
      'Elige si la mezcla automática dura 8, 16 o 32 pulsos.'),
  DjShortcutHelp(
      ['F9'],
      null,
      'Grabar la mezcla',
      'Empieza o termina de grabar lo que sale por los parlantes (el '
          'estéreo completo) a un WAV en Música\\TK Music\\Mezclas.'),
  DjShortcutHelp(['F2'], null, 'Archivos',
      'Abre el gestor de archivos para elegir canciones de cualquier disco.'),
  DjShortcutHelp(
      ['F4'],
      null,
      'Ecualizador',
      'Abre la ganancia y el ecualizador (agudos, medios, graves) de los dos '
          'decks.'),
  DjShortcutHelp(
      ['F8'],
      null,
      'Auto DJ',
      'Abre la lista del Auto DJ: canciones que suenan solas, mezclándose una '
          'con otra.'),
  DjShortcutHelp(['F3'], null, 'Plegar el mezclador',
      'Lo achica a una columna para dejarles más lugar a los decks.'),
  DjShortcutHelp(['F1'], null, 'Esta ayuda',
      'Muestra la lista de atajos (Esc la cierra).'),
];

/// La ventana de atajos: el teclado dibujado con cada zona pintada del
/// color de su deck, y abajo la lista de qué hace cada tecla y para qué
/// sirve.
class DjShortcutsDialog extends StatelessWidget {
  const DjShortcutsDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
        context: context,
        builder: (context) => const DjShortcutsDialog(),
      );

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
        width: size.width.clamp(0, 980).toDouble(),
        height: (size.height - 48).clamp(0, 820).toDouble(),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 6),
              child: Row(
                children: [
                  const Icon(Icons.keyboard, color: DjColors.text),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text('Atajos de teclado',
                        style: TextStyle(
                            color: DjColors.text,
                            fontSize: 18,
                            fontWeight: FontWeight.w800)),
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
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                children: [
                  const Text(
                    'Cada botón del Modo DJ tiene su tecla, para mezclar sin '
                    'el mouse. El deck A se maneja con la mitad izquierda del '
                    'teclado y el deck B con la derecha, con la misma forma: '
                    'lo que hace Q en el A lo hace Y en el B, W ↔ U, y así. '
                    'El mezclador va con las flechas, Espacio, Intro y las '
                    'teclas F. Pasando el mouse por cualquier botón, el '
                    'cartelito también dice su tecla.',
                    style: TextStyle(color: DjColors.muted, height: 1.4),
                  ),
                  const SizedBox(height: 14),
                  const DjKeyboardMap(),
                  const SizedBox(height: 18),
                  _Section(
                    title: 'Decks',
                    subtitle: 'Deck A a la izquierda · deck B a la derecha',
                    rows: djDeckShortcutHelp,
                  ),
                  const SizedBox(height: 18),
                  _Section(
                    title: 'Mezclador y general',
                    rows: djMixerShortcutHelp,
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Las teclas se reconocen por su lugar en el teclado: '
                    'funcionan igual con teclado en español o en inglés. '
                    'Mientras está abierta una ventana (como el gestor de '
                    'archivos) las teclas escriben ahí y no tocan los decks.',
                    style: TextStyle(color: DjColors.muted, fontSize: 12),
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

class _Section extends StatelessWidget {
  const _Section({required this.title, this.subtitle, required this.rows});

  final String title;
  final String? subtitle;
  final List<DjShortcutHelp> rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title.toUpperCase(),
            style: const TextStyle(
                color: DjColors.text,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5)),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(subtitle!,
                style: const TextStyle(color: DjColors.muted, fontSize: 12)),
          ),
        const SizedBox(height: 8),
        for (final row in rows)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: DjColors.border)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: row.keysB == null ? 190 : 280,
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final k in row.keysA)
                        DjKeyCap(k,
                            color: row.keysB == null
                                ? DjColors.cue
                                : DjColors.deckA),
                      if (row.keysB != null) ...[
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 2),
                          child: Text('·',
                              style: TextStyle(color: DjColors.muted)),
                        ),
                        for (final k in row.keysB!)
                          DjKeyCap(k, color: DjColors.deckB),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(row.action,
                          style: const TextStyle(
                              color: DjColors.text,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(row.purpose,
                          style: const TextStyle(
                              color: DjColors.muted,
                              fontSize: 12.5,
                              height: 1.35)),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Una tecla dibujada.
class DjKeyCap extends StatelessWidget {
  const DjKeyCap(this.label, {super.key, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 24),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.7)),
      ),
      child: Text(label,
          textAlign: TextAlign.center,
          style: TextStyle(
              color: color, fontSize: 12, fontWeight: FontWeight.w800)),
    );
  }
}

/// El teclado con cada tecla del Modo DJ pintada: celeste = deck A,
/// naranja = deck B, amarillo = mezclador. Cada tecla dice en chiquito qué
/// hace.
class DjKeyboardMap extends StatelessWidget {
  const DjKeyboardMap({super.key});

  // (tecla, qué hace, zona: 0 = A, 1 = B, 2 = mezclador, null = libre)
  static const _rows = <List<(String, String, int?)>>[
    [
      ('F1', 'ayuda', 2),
      ('F2', 'archivos', 2),
      ('F3', 'mezclador', 2),
      ('F4', 'ecualizador', 2),
      ('F5', 'mezcla 8', 2),
      ('F6', 'mezcla 16', 2),
      ('F7', 'mezcla 32', 2),
      ('F8', 'auto DJ', 2),
      ('F9', 'grabar', 2),
    ],
    [
      ('1', 'pad 1', 0),
      ('2', 'pad 2', 0),
      ('3', 'pad 3', 0),
      ('4', 'pad 4', 0),
      ('5', 'modo', 0),
      ('6', 'modo', 1),
      ('7', 'pad 1', 1),
      ('8', 'pad 2', 1),
      ('9', 'pad 3', 1),
      ('0', 'pad 4', 1),
    ],
    [
      ('Q', 'CUE', 0),
      ('W', 'PLAY', 0),
      ('E', 'SYNC', 0),
      ('R', 'AUTO', 0),
      ('T', 'TONO', 0),
      ('Y', 'CUE', 1),
      ('U', 'PLAY', 1),
      ('I', 'SYNC', 1),
      ('O', 'AUTO', 1),
      ('P', 'TONO', 1),
    ],
    [
      ('A', 'pitch −', 0),
      ('S', 'pitch +', 0),
      ('D', 'pitch 0', 0),
      ('F', 'rango', 0),
      ('G', 'FIJO', 0),
      ('H', 'pitch −', 1),
      ('J', 'pitch +', 1),
      ('K', 'pitch 0', 1),
      ('L', 'rango', 1),
      ('Ñ', 'FIJO', 1),
    ],
    [
      ('Z', 'b', 0),
      ('X', '#', 0),
      ('C', 'cargar', 0),
      ('V', 'probar', 0),
      ('B', '', null),
      ('N', 'b', 1),
      ('M', '#', 1),
      (',', 'cargar', 1),
      ('.', 'probar', 1),
    ],
  ];

  static const _indent = [0.0, 0.0, 18.0, 28.0, 44.0];

  static Color _color(int? zone) => switch (zone) {
        0 => DjColors.deckA,
        1 => DjColors.deckB,
        2 => DjColors.cue,
        _ => DjColors.border,
      };

  Widget _key(String label, String hint, int? zone, {double width = 58}) {
    final color = _color(zone);
    return Container(
      width: width,
      height: 46,
      margin: const EdgeInsets.all(2),
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
      decoration: BoxDecoration(
        color:
            zone == null ? DjColors.background : color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
            color:
                zone == null ? DjColors.border : color.withValues(alpha: 0.8)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(label,
              style: TextStyle(
                  color: zone == null ? DjColors.muted : DjColors.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w800)),
          if (hint.isNotEmpty)
            Text(hint,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: TextStyle(color: color, fontSize: 9.5)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final keyboard = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var r = 0; r < _rows.length; r++)
          Padding(
            padding: EdgeInsets.only(left: _indent[r], bottom: r == 0 ? 8 : 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (label, hint, zone) in _rows[r])
                  _key(label, hint, zone),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _key('Espacio', 'crossfader al centro', 2, width: 240),
            const SizedBox(width: 16),
            _key('←', 'crossfader A', 2),
            _key('→', 'crossfader B', 2),
            _key('↑', 'master +', 2),
            _key('↓', 'master −', 2),
            const SizedBox(width: 16),
            _key('Intro', 'mezcla auto', 2, width: 80),
          ],
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: keyboard,
        ),
        const SizedBox(height: 8),
        const Wrap(
          spacing: 14,
          runSpacing: 4,
          children: [
            _Legend(DjColors.deckA, 'Deck A'),
            _Legend(DjColors.deckB, 'Deck B'),
            _Legend(DjColors.cue, 'Mezclador y general'),
            Text('Shift: pads 5–8 y pitch de a 1 %  ·  Alt: borrar punto',
                style: TextStyle(color: DjColors.muted, fontSize: 12)),
          ],
        ),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend(this.color, this.text);

  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.3),
              border: Border.all(color: color),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 5),
          Text(text,
              style: const TextStyle(color: DjColors.muted, fontSize: 12)),
        ],
      );
}

/// El texto de la tecla de [command] en [deck] para sumarlo a un cartelito:
/// " · Tecla: Q".
String djShortcutHint(DjCommand command, {int? deck, int arg = 0}) {
  for (final b in djKeyBindings) {
    if (b.command == command && b.deck == deck && b.arg == arg) {
      return ' · Tecla: ${djKeyLabel(b)}';
    }
  }
  return '';
}

/// Nombre visible de una tecla ("Shift+1", "Ñ", "Espacio").
String djKeyLabel(DjKeyBinding b) {
  final name = _keyNames[b.key] ?? '?';
  return [if (b.alt) 'Alt', if (b.shift) 'Shift', name].join('+');
}

final _keyNames = <PhysicalKeyboardKey, String>{
  for (var i = 0; i < 10; i++)
    [
      _K.digit0,
      _K.digit1,
      _K.digit2,
      _K.digit3,
      _K.digit4,
      _K.digit5,
      _K.digit6,
      _K.digit7,
      _K.digit8,
      _K.digit9,
    ][i]: '$i',
  _K.keyQ: 'Q',
  _K.keyW: 'W',
  _K.keyE: 'E',
  _K.keyR: 'R',
  _K.keyT: 'T',
  _K.keyY: 'Y',
  _K.keyU: 'U',
  _K.keyI: 'I',
  _K.keyO: 'O',
  _K.keyP: 'P',
  _K.keyA: 'A',
  _K.keyS: 'S',
  _K.keyD: 'D',
  _K.keyF: 'F',
  _K.keyG: 'G',
  _K.keyH: 'H',
  _K.keyJ: 'J',
  _K.keyK: 'K',
  _K.keyL: 'L',
  _K.semicolon: 'Ñ',
  _K.keyZ: 'Z',
  _K.keyX: 'X',
  _K.keyC: 'C',
  _K.keyV: 'V',
  _K.keyN: 'N',
  _K.keyM: 'M',
  _K.comma: ',',
  _K.period: '.',
  _K.arrowLeft: '←',
  _K.arrowRight: '→',
  _K.arrowUp: '↑',
  _K.arrowDown: '↓',
  _K.space: 'Espacio',
  _K.enter: 'Intro',
  _K.numpadEnter: 'Intro',
  _K.f1: 'F1',
  _K.f2: 'F2',
  _K.f3: 'F3',
  _K.f5: 'F5',
  _K.f6: 'F6',
  _K.f7: 'F7',
  _K.f4: 'F4',
  _K.f8: 'F8',
  _K.f9: 'F9',
};
