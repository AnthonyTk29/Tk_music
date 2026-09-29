import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tk_music/presentation/widgets/app_header.dart';

void main() {
  testWidgets('logo y nombre en la barra, sin desbordar en un celular',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title:
              const AppHeaderTitle(section: 'Sincronizar con otro dispositivo'),
          actions: [
            IconButton(onPressed: () {}, icon: const Icon(Icons.lyrics)),
            IconButton(onPressed: () {}, icon: const Icon(Icons.timer)),
          ],
        ),
      ),
    ));

    expect(tester.takeException(), isNull);
    expect(find.text('Sincronizar con otro dispositivo'), findsOneWidget);
    expect(find.textContaining('Music', findRichText: true), findsOneWidget);
  });

  testWidgets('versión grande para las pantallas sin barra', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: AppHeaderTitle(large: true))),
    ));
    expect(tester.takeException(), isNull);
  });
}
