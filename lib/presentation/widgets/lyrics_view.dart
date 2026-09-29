import 'package:flutter/material.dart';

import 'package:tk_music/services/lyrics.dart';

/// Letra que acompaña la canción: resalta el renglón que suena y se
/// desplaza sola para tenerlo a la vista. Tocar un renglón salta ahí
/// ([onSeek]). Se usa en "Reproduciendo" y en el modo karaoke de las
/// sesiones compartidas ([large]).
class LyricsView extends StatefulWidget {
  const LyricsView({
    super.key,
    required this.lyrics,
    required this.position,
    this.onSeek,
    this.large = false,
  });

  final Lyrics lyrics;
  final Duration position;
  final ValueChanged<Duration>? onSeek;
  final bool large;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  final _keys = <GlobalKey>[];
  int _active = -2;

  @override
  void didUpdateWidget(covariant LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lyrics != widget.lyrics) _active = -2;
  }

  void _ensureKeys() {
    while (_keys.length < widget.lyrics.lines.length) {
      _keys.add(GlobalKey());
    }
  }

  @override
  Widget build(BuildContext context) {
    _ensureKeys();
    final theme = Theme.of(context);
    final lyrics = widget.lyrics;
    final active = lyrics.indexAt(widget.position);
    if (active != _active) {
      _active = active;
      if (active >= 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final context = _keys[active].currentContext;
          if (context != null) {
            Scrollable.ensureVisible(
              context,
              alignment: 0.4,
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOut,
            );
          }
        });
      }
    }

    final baseStyle = (widget.large
            ? theme.textTheme.headlineSmall
            : theme.textTheme.titleLarge)!
        .copyWith(fontWeight: FontWeight.w700, height: 1.25);
    return ListView.builder(
      padding: EdgeInsets.symmetric(
          vertical: widget.large ? 120 : 80, horizontal: 8),
      itemCount: lyrics.lines.length + 1,
      itemBuilder: (context, index) {
        if (index == lyrics.lines.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 24),
            child: Text(
              'Letra: ${lyrics.source}',
              textAlign: widget.large ? TextAlign.center : TextAlign.start,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          );
        }
        final line = lyrics.lines[index];
        final isActive = index == active;
        final isPast = lyrics.synced && index < active;
        final color = !lyrics.synced
            ? theme.colorScheme.onSurface
            : isActive
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurface
                    .withValues(alpha: isPast ? 0.35 : 0.6);
        final text = AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 250),
          style: baseStyle.copyWith(
            color: color,
            fontSize: (baseStyle.fontSize ?? 22) * (isActive ? 1.08 : 1.0),
          ),
          textAlign: widget.large ? TextAlign.center : TextAlign.start,
          child: Text(line.text.isEmpty ? '♪' : line.text),
        );
        return Padding(
          key: _keys[index],
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: widget.onSeek != null && line.time != null
              ? InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => widget.onSeek!(line.time!),
                  child: text,
                )
              : text,
        );
      },
    );
  }
}
