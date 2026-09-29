import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

/// Lee un código QR de una imagen (JPEG/PNG…), en Dart puro: lo usa el
/// escáner de Windows, que saca fotos con la cámara porque ahí no hay un
/// lector en vivo. `null` si no se encontró ningún QR. Pensado para correr
/// en un isolate (`Isolate.run`).
String? decodeQrImage(Uint8List encoded) {
  var image = img.decodeImage(encoded);
  if (image == null) return null;
  // Más de ~1000 px no mejora la lectura y la hace mucho más lenta.
  if (image.width > 1000 || image.height > 1000) {
    image = image.width >= image.height
        ? img.copyResize(image, width: 1000)
        : img.copyResize(image, height: 1000);
  }
  final pixels = image
      .convert(numChannels: 4)
      .getBytes(order: img.ChannelOrder.abgr)
      .buffer
      .asInt32List();
  final source = RGBLuminanceSource(image.width, image.height, pixels);
  // Dos formas de separar blanco y negro: la global anda mejor con buena
  // luz, la híbrida con sombras o reflejos en la pantalla fotografiada.
  for (final bitmap in [
    BinaryBitmap(HybridBinarizer(source)),
    BinaryBitmap(GlobalHistogramBinarizer(source)),
  ]) {
    try {
      return QRCodeReader().decode(bitmap).text;
    } catch (_) {
      // No se encontró con este método: se prueba el siguiente.
    }
  }
  return null;
}

/// [decodeQrImage] en segundo plano, desde los bytes o desde el archivo en
/// [path]. [deleteFile]: borra el archivo después (fotos temporales de la
/// cámara). `null` si no hay imagen o no tiene un QR.
Future<String?> decodeQrInBackground({
  Uint8List? bytes,
  String? path,
  bool deleteFile = false,
}) async {
  Uint8List? data = bytes;
  if (data == null && path != null) {
    try {
      data = await File(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }
  if (deleteFile && path != null) {
    unawaited(File(path).delete().then((_) {}, onError: (_) {}));
  }
  if (data == null) return null;
  final encoded = data;
  return Isolate.run(() => decodeQrImage(encoded));
}
