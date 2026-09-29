import 'package:flutter_test/flutter_test.dart';
import 'package:tk_music/presentation/widgets/quick_access_grid.dart';

double _tile(double width) {
  final layout = quickAccessLayout(width);
  return (width - 8 * (layout.columns - 1)) / layout.columns;
}

void main() {
  test('en un teléfono sigue siendo 3×3', () {
    final layout = quickAccessLayout(360);
    expect(layout.columns, 3);
    expect(layout.rows, 3);
  });

  test('en una ventana ancha entran más columnas y las carátulas no crecen',
      () {
    for (final width in [700.0, 1200.0, 1880.0, 2500.0]) {
      expect(_tile(width), lessThanOrEqualTo(180), reason: 'ancho $width');
      expect(_tile(width), greaterThan(140), reason: 'ancho $width');
    }
    final wide = quickAccessLayout(1880);
    expect(wide.columns, greaterThanOrEqualTo(10));
    expect(wide.rows, 2);
  });
}
