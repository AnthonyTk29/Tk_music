import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tk_music/presentation/widgets/alphabet_index_bar.dart';

void main() {
  final labels = [
    for (final letter in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split(''))
      for (var i = 0; i < 5; i++) '$letter canción $i',
  ];

  Future<void> pumpBar(WidgetTester tester, double height) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topRight,
          child: SizedBox(
            height: height,
            child: AlphabetIndexBar(
                labels: labels, controller: ScrollController()),
          ),
        ),
      ),
    ));
  }

  testWidgets('en una ventana baja (338 px) no desborda', (tester) async {
    await pumpBar(tester, 338.4);
    expect(tester.takeException(), isNull);
    // Muestra menos letras, pero sigue ahí.
    expect(find.text('A'), findsOneWidget);
    expect(find.byType(Text).evaluate().length, lessThan(28));
  });

  testWidgets('con espacio muestra las 28 letras', (tester) async {
    await pumpBar(tester, 800);
    expect(tester.takeException(), isNull);
    expect(find.byType(Text).evaluate().length, 28);
  });

  testWidgets('muy bajo, se oculta', (tester) async {
    await pumpBar(tester, 40);
    expect(tester.takeException(), isNull);
    expect(find.byType(Text), findsNothing);
  });
}
