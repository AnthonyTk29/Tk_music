import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tk_music/presentation/navigation/breadcrumbs.dart';
import 'package:tk_music/presentation/widgets/app_header.dart';

Widget _screen(String? section,
        {String? crumb,
        List<String> parents = const [],
        Widget Function(BuildContext)? next}) =>
    Scaffold(
      appBar: AppBar(
        title: AppHeaderTitle(section: section, crumb: crumb, parents: parents),
      ),
      body: next == null
          ? const SizedBox()
          : Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: next)),
                child: const Text('abrir'),
              ),
            ),
    );

void main() {
  testWidgets('cada pantalla muestra el camino y se vuelve tocando una miga',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [breadcrumbs],
      home: _screen(
        null,
        crumb: 'Inicio',
        next: (_) => _screen(
          'Almacenamiento',
          next: (_) => _screen(
            'Bad Bunny',
            parents: const ['Biblioteca', 'Artistas'],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // En el inicio no hay migas.
    expect(find.text('Inicio'), findsNothing);

    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    expect(find.text('Inicio'), findsOneWidget);
    expect(find.text('Almacenamiento'), findsOneWidget);

    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    for (final crumb in [
      'Inicio',
      'Almacenamiento',
      'Biblioteca',
      'Artistas',
      'Bad Bunny',
    ]) {
      expect(find.text(crumb), findsOneWidget, reason: crumb);
    }
    expect(find.byIcon(Icons.chevron_right), findsNWidgets(4));

    // Una miga intermedia vuelve a la pantalla donde está.
    await tester.tap(find.text('Artistas'));
    await tester.pumpAndSettle();
    expect(find.text('Bad Bunny'), findsNothing);
    expect(find.text('Almacenamiento'), findsOneWidget);

    // "Inicio" vuelve hasta el principio.
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Inicio'));
    await tester.pumpAndSettle();
    expect(find.text('Almacenamiento'), findsNothing);
    expect(breadcrumbs.routes, hasLength(1));
  });

  testWidgets('sin el observador (o en la primera pantalla) solo el nombre',
      (tester) async {
    await tester
        .pumpWidget(MaterialApp(home: _screen('Ajustes', crumb: 'Ajustes')));
    await tester.pumpAndSettle();
    expect(find.text('Ajustes'), findsOneWidget);
    expect(find.byType(BreadcrumbTrail), findsNothing);
  });
}
