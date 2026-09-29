import 'package:flutter_test/flutter_test.dart';
import 'package:tk_music/data/datasources/song_local_datasource.dart';
import 'package:tk_music/services/whatsapp_import_service.dart';

void main() {
  test('nombres legibles para los audios de WhatsApp', () {
    expect(friendlyWhatsAppTitle('PTT-20260927-WA0003'),
        'Nota de voz 27-09-2026 (3)');
    expect(friendlyWhatsAppTitle('AUD-20260127-WA0014'),
        'Audio de WhatsApp 27-01-2026 (14)');
    // Si tiene un nombre de verdad, queda ese.
    expect(friendlyWhatsAppTitle('La droga AUD-20260127-WA0014'), 'La droga');
    expect(friendlyWhatsAppTitle('Mi canción'), 'Mi canción');
    expect(isWhatsAppVoiceNote('PTT-20260927-WA0003.opus'), isTrue);
    expect(isWhatsAppVoiceNote('AUD-20260927-WA0003.opus'), isFalse);
    expect(whatsAppDate('PTT-20260927-WA0003.opus'), DateTime(2026, 9, 27));
  });

  test('el archivo copiado no lleva el código ni caracteres inválidos', () {
    final name =
        WhatsAppImportService.cleanFileName('PTT-20260927-WA0003', 'opus');
    expect(name, 'Nota de voz 27-09-2026 (3).opus');
    expect(WhatsAppImportService.cleanFileName('a/b:c?', 'mp3'), 'a_b_c_.mp3');
  });

  test('lo importado no lo vuelve a esconder la biblioteca', () {
    // Los originales de WhatsApp sí se esconden…
    expect(
        isWhatsAppAudioPath('/storage/emulated/0/Android/media/com.whatsapp/'
            'WhatsApp/Media/WhatsApp Audio/AUD-20260127-WA0014.opus'),
        isTrue);
    expect(
        isWhatsAppAudioPath(
            '/storage/emulated/0/Download/PTT-20260927-WA0003.opus'),
        isTrue);
    // …pero la copia importada, con nombre limpio y en su carpeta, no.
    final copy = '/storage/emulated/0/Music/TK Music/Audios de WhatsApp/'
        '${WhatsAppImportService.cleanFileName('AUD-20260127-WA0014', 'opus')}';
    expect(isWhatsAppAudioPath(copy), isFalse);
    // Antes se copiaba a una carpeta "WhatsApp": se escondía de nuevo.
    expect(isWhatsAppAudioPath('/storage/emulated/0/Music/WhatsApp/x.mp3'),
        isTrue);
  });
}
