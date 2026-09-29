import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Un frame de una etiqueta ID3v2 (TIT2 = título, TPE1 = artista, TALB =
/// álbum, TCON = género, APIC = carátula, USLT = letra…).
class Id3Frame {
  Id3Frame(this.id, this.data, [this.flags = const [0, 0]]);

  final String id;
  final Uint8List data;
  final List<int> flags;
}

/// Lectura y escritura mínima de etiquetas ID3v2.3/2.4 de MP3, en Dart puro:
/// lo que hace falta para editar título/artista/álbum/género/carátula y
/// leer la letra embebida. No toca el audio.
class Id3Tag {
  Id3Tag._(this.version, this.frames, this.audioOffset);

  /// 3 o 4 (ID3v2.3 / v2.4). 0 = el archivo no tenía etiqueta.
  final int version;
  final List<Id3Frame> frames;

  /// Dónde empieza el audio (después de la etiqueta).
  final int audioOffset;

  /// Lee la etiqueta del comienzo de [bytes]. Devuelve `null` si tiene
  /// algo que esta implementación no maneja (etiquetas viejas v2.2,
  /// "unsynchronisation" o cabecera extendida): en ese caso no se escribe
  /// el archivo, para no arriesgar romperlo.
  static Id3Tag? parse(Uint8List bytes) {
    if (bytes.length < 10 ||
        ascii.decode(bytes.sublist(0, 3), allowInvalid: true) != 'ID3') {
      return Id3Tag._(0, [], 0);
    }
    final version = bytes[3];
    final flags = bytes[5];
    if (version != 3 && version != 4) return null;
    if (flags & 0x80 != 0 || flags & 0x40 != 0) return null;
    final size = _syncsafe(bytes, 6);
    final footer = version == 4 && flags & 0x10 != 0 ? 10 : 0;
    final end = 10 + size;
    if (end > bytes.length) return null;

    final frames = <Id3Frame>[];
    var pos = 10;
    while (pos + 10 <= end) {
      if (bytes[pos] == 0) break; // relleno
      final id = ascii.decode(bytes.sublist(pos, pos + 4), allowInvalid: true);
      final frameSize =
          version == 4 ? _syncsafe(bytes, pos + 4) : _uint32(bytes, pos + 4);
      final frameFlags = [bytes[pos + 8], bytes[pos + 9]];
      final start = pos + 10;
      if (frameSize < 0 || start + frameSize > end) break;
      frames.add(Id3Frame(
          id,
          Uint8List.fromList(bytes.sublist(start, start + frameSize)),
          frameFlags));
      pos = start + frameSize;
    }
    return Id3Tag._(version, frames, end + footer);
  }

  static Future<Id3Tag?> readFile(String path) async {
    final file = File(path);
    final raf = await file.open();
    try {
      final header = await raf.read(10);
      if (header.length < 10 ||
          ascii.decode(header.sublist(0, 3), allowInvalid: true) != 'ID3') {
        return Id3Tag._(0, [], 0);
      }
      final total = 10 + _syncsafe(header, 6);
      await raf.setPosition(0);
      return parse(await raf.read(total));
    } finally {
      await raf.close();
    }
  }

  Id3Frame? frame(String id) {
    for (final f in frames) {
      if (f.id == id) return f;
    }
    return null;
  }

  /// Texto de un frame T*** (TIT2, TPE1…).
  String? text(String id) {
    final f = frame(id);
    if (f == null || f.data.isEmpty) return null;
    return _decodeText(f.data[0], f.data.sublist(1))
        .replaceAll('\u0000', '/')
        .trim();
  }

  /// Letra sin sincronizar (USLT): [encoding][idioma x3][descripción\0][texto].
  String? get lyrics {
    final f = frame('USLT');
    if (f == null || f.data.length < 5) return null;
    final encoding = f.data[0];
    final rest = f.data.sublist(4);
    final split = _terminatorEnd(rest, encoding);
    return _decodeText(encoding, rest.sublist(split)).trim();
  }

  /// Carátula embebida (APIC): [encoding][mime\0][tipo][descripción\0][imagen].
  /// Si hay varias, la frontal (tipo 3); si no, la primera.
  Uint8List? get picture {
    Uint8List? first;
    for (final f in frames) {
      if (f.id != 'APIC' || f.data.length < 4) continue;
      final data = f.data;
      final encoding = data[0];
      var pos = 1;
      while (pos < data.length && data[pos] != 0) {
        pos++;
      }
      pos++; // fin del mime
      if (pos >= data.length) continue;
      final type = data[pos];
      pos++;
      pos += _terminatorEnd(data.sublist(pos), encoding);
      if (pos >= data.length) continue;
      final image = Uint8List.sublistView(data, pos);
      if (type == 3) return image;
      first ??= image;
    }
    return first;
  }

  /// Arma el archivo nuevo: esta etiqueta con los cambios + el audio
  /// original sin tocar. [texts] reemplaza (o con `''`, borra) frames de
  /// texto; [cover] reemplaza la carátula (con `removeCover`, se borra).
  Uint8List rebuild(
    Uint8List original, {
    Map<String, String> texts = const {},
    Uint8List? cover,
    bool removeCover = false,
  }) {
    final version = this.version == 0 ? 3 : this.version;
    final kept = frames.where((f) {
      if (texts.containsKey(f.id)) return false;
      if (f.id == 'APIC' && (cover != null || removeCover)) return false;
      return true;
    }).toList();
    for (final entry in texts.entries) {
      if (entry.value.isEmpty) continue;
      // Codificación 1 = UTF-16 con BOM, válida en v2.3 y v2.4.
      final text =
          Uint8List.fromList([1, 0xFF, 0xFE, ..._utf16le(entry.value)]);
      kept.add(Id3Frame(entry.key, text));
    }
    if (cover != null) {
      kept.add(Id3Frame(
          'APIC',
          Uint8List.fromList([
            0, ...ascii.encode('image/jpeg'), 0,
            3, // carátula frontal
            0, // descripción vacía
            ...cover,
          ])));
    }

    final body = BytesBuilder();
    for (final f in kept) {
      body.add(ascii.encode(f.id));
      body.add(
          version == 4 ? _toSyncsafe(f.data.length) : _toUint32(f.data.length));
      body.add(f.flags);
      body.add(f.data);
    }
    const padding = 1024;
    body.add(Uint8List(padding));
    final bodyBytes = body.takeBytes();

    final out = BytesBuilder();
    out.add(ascii.encode('ID3'));
    out.add([version, 0, 0]);
    out.add(_toSyncsafe(bodyBytes.length));
    out.add(bodyBytes);
    out.add(Uint8List.sublistView(original, audioOffset));
    return out.takeBytes();
  }
}

/// Escribe tags en un MP3 sin tocar el audio. Escribe a un archivo aparte y
/// recién al final reemplaza el original (si algo falla, el original queda
/// intacto). Devuelve `false` si el archivo tiene algo que no se maneja.
Future<bool> writeMp3Tags(
  String path, {
  String? title,
  String? artist,
  String? album,
  String? genre,
  Uint8List? cover,
  bool removeCover = false,
}) async {
  if (!path.toLowerCase().endsWith('.mp3')) return false;
  final file = File(path);
  final original = await file.readAsBytes();
  final tag = Id3Tag.parse(original);
  if (tag == null) return false;
  final updated = tag.rebuild(
    original,
    texts: {
      if (title != null) 'TIT2': title,
      if (artist != null) 'TPE1': artist,
      if (album != null) 'TALB': album,
      if (genre != null) 'TCON': genre,
    },
    cover: cover,
    removeCover: removeCover,
  );
  // Verificación: la etiqueta nueva se vuelve a leer y el audio es el mismo.
  final check = Id3Tag.parse(updated);
  if (check == null ||
      updated.length - check.audioOffset != original.length - tag.audioOffset) {
    return false;
  }
  final temp = File('$path.tkmusic.tmp');
  await temp.writeAsBytes(updated, flush: true);
  await temp.rename(path);
  return true;
}

// ---------------------------------------------------------------------------

int _syncsafe(List<int> b, int o) =>
    (b[o] & 0x7F) << 21 |
    (b[o + 1] & 0x7F) << 14 |
    (b[o + 2] & 0x7F) << 7 |
    (b[o + 3] & 0x7F);

int _uint32(List<int> b, int o) =>
    b[o] << 24 | b[o + 1] << 16 | b[o + 2] << 8 | b[o + 3];

List<int> _toSyncsafe(int v) =>
    [(v >> 21) & 0x7F, (v >> 14) & 0x7F, (v >> 7) & 0x7F, v & 0x7F];

List<int> _toUint32(int v) =>
    [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

List<int> _utf16le(String text) {
  final out = <int>[];
  for (final unit in text.codeUnits) {
    out
      ..add(unit & 0xFF)
      ..add(unit >> 8);
  }
  return out;
}

String _decodeText(int encoding, List<int> data) {
  switch (encoding) {
    case 0:
      return latin1.decode(_trimNulls(data, 1));
    case 1:
    case 2:
      var bytes = _trimNulls(data, 2);
      var littleEndian = encoding == 1;
      if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
        littleEndian = true;
        bytes = bytes.sublist(2);
      } else if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
        littleEndian = false;
        bytes = bytes.sublist(2);
      } else if (encoding == 2) {
        littleEndian = false;
      }
      final units = <int>[];
      for (var i = 0; i + 1 < bytes.length; i += 2) {
        units.add(littleEndian
            ? bytes[i] | bytes[i + 1] << 8
            : bytes[i] << 8 | bytes[i + 1]);
      }
      return String.fromCharCodes(units);
    default:
      return utf8.decode(_trimNulls(data, 1), allowMalformed: true);
  }
}

List<int> _trimNulls(List<int> data, int width) {
  var end = data.length;
  while (end >= width && data.sublist(end - width, end).every((b) => b == 0)) {
    end -= width;
  }
  return data.sublist(0, end);
}

/// Posición justo después del terminador de la descripción (1 byte 0 en
/// latin1/utf8, 2 bytes 0 alineados en utf16).
int _terminatorEnd(List<int> data, int encoding) {
  if (encoding == 1 || encoding == 2) {
    for (var i = 0; i + 1 < data.length; i += 2) {
      if (data[i] == 0 && data[i + 1] == 0) return i + 2;
    }
  } else {
    for (var i = 0; i < data.length; i++) {
      if (data[i] == 0) return i + 1;
    }
  }
  return data.length;
}
