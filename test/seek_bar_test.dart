import 'package:flutter_test/flutter_test.dart';
import 'package:tk_music/core/utils/formatters.dart';

void main() {
  test('formats short durations as minutes and seconds', () {
    expect(formatDuration(const Duration(seconds: 5)), '00:05');
    expect(formatDuration(const Duration(minutes: 3, seconds: 7)), '03:07');
  });

  test('formats durations longer than one hour', () {
    expect(formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '1:02:03');
  });
}
