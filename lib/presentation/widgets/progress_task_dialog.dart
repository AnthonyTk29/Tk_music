import 'package:flutter/material.dart';

/// Ventana de avance para tareas largas (mandar a la papelera, borrar,
/// importar): barra, "X de N", porcentaje y el elemento que se está
/// procesando. [progress] lleva (hechos, nombre del actual).
class ProgressTaskDialog extends StatelessWidget {
  const ProgressTaskDialog({
    super.key,
    required this.title,
    required this.progress,
    required this.total,
    this.icon,
  });

  final String title;
  final ValueNotifier<(int, String)> progress;
  final int total;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: icon == null ? null : Icon(icon, size: 36),
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: ValueListenableBuilder<(int, String)>(
          valueListenable: progress,
          builder: (context, value, _) {
            final (done, current) = value;
            final fraction = total == 0 ? 1.0 : (done / total).clamp(0.0, 1.0);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child:
                      LinearProgressIndicator(value: fraction, minHeight: 10),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text('$done de $total'),
                    const Spacer(),
                    Text('${(fraction * 100).round()} %',
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  current,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Abre la [ProgressTaskDialog] (sin poder cerrarla a mano) y corre [step]
/// para cada elemento de [items], uno por uno. Un error en uno no frena el
/// resto: se devuelve junto con el elemento. Al terminar se deja ver el
/// 100 % un momento y se cierra la ventana.
Future<List<(T, Object?)>> runWithProgressDialog<T>(
  BuildContext context, {
  required String title,
  required List<T> items,
  required String Function(T item) labelOf,
  required Future<void> Function(T item) step,
  IconData? icon,
}) async {
  final progress = ValueNotifier<(int, String)>((0, ''));
  final navigator = Navigator.of(context, rootNavigator: true);
  final results = <(T, Object?)>[];
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (_) => PopScope(
      canPop: false,
      child: ProgressTaskDialog(
        title: title,
        progress: progress,
        total: items.length,
        icon: icon,
      ),
    ),
  );
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    progress.value = (i, labelOf(item));
    try {
      await step(item);
      results.add((item, null));
    } catch (e) {
      results.add((item, e));
    }
    progress.value = (i + 1, labelOf(item));
  }
  await Future<void>.delayed(const Duration(milliseconds: 350));
  navigator.pop();
  progress.dispose();
  return results;
}
