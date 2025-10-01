import 'package:flutter/material.dart';
import '../controllers/audio_controller.dart';

class PlayerControls extends StatelessWidget {
  const PlayerControls({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ElevatedButton(
          onPressed: () => AudioController.play(),
          child: const Text("▶ Play"),
        ),
        ElevatedButton(
          onPressed: () => AudioController.pause(),
          child: const Text("⏸ Pause"),
        ),
        ElevatedButton(
          onPressed: () => AudioController.stop(),
          child: const Text("⏹ Stop"),
        ),
      ],
    );
  }
}
