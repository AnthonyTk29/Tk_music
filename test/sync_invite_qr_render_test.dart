import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:tk_music/services/qr_image_decoder.dart';
import 'package:tk_music/services/sync_invite.dart';

void main() {
  testWidgets('el QR que dibuja la app se puede leer', (tester) async {
    final text = const SyncInvite(
      transport: InviteTransport.bluetooth,
      room: 'Fiesta en casa',
      bluetoothName: 'LAPTOP-ANA',
      bluetoothAddress: 'AA:BB:CC:DD:EE:FF',
    ).encode();
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: RepaintBoundary(
          key: key,
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.all(10),
            child: QrImageView(
              data: text,
              size: 200,
              padding: EdgeInsets.zero,
              backgroundColor: Colors.white,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
            ),
          ),
        ),
      ),
    ));

    final png = await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    });
    expect(img.decodePng(png!), isNotNull);
    expect(decodeQrImage(png), text);
  });
}
