import 'package:flutter/material.dart';

import 'package:tk_music/core/utils/formatters.dart';

class SeekBar extends StatefulWidget {
  const SeekBar({
    super.key,
    required this.duration,
    required this.position,
    this.onChangeEnd,
  });

  final Duration duration;
  final Duration position;
  final ValueChanged<Duration>? onChangeEnd;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final totalMs = widget.duration.inMilliseconds.toDouble();
    final positionMs = widget.position.inMilliseconds
        .toDouble()
        .clamp(0.0, totalMs > 0 ? totalMs : 0.0);
    final value = _dragValue ?? positionMs;
    final shown = Duration(milliseconds: value.round());

    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 2,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            min: 0,
            max: totalMs > 0 ? totalMs : 1,
            value: totalMs > 0 ? value.clamp(0.0, totalMs) : 0,
            onChanged:
                totalMs > 0 ? (v) => setState(() => _dragValue = v) : null,
            onChangeEnd: totalMs > 0
                ? (v) {
                    widget.onChangeEnd?.call(Duration(milliseconds: v.round()));
                    setState(() => _dragValue = null);
                  }
                : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(formatDuration(shown),
                  style: Theme.of(context).textTheme.bodySmall),
              Text(formatDuration(widget.duration),
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}
