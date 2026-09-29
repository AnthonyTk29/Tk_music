import 'package:tk_music/core/di/service_locator.dart';
import 'package:tk_music/domain/entities/song.dart';
import 'package:tk_music/domain/repositories/audio_import_repository.dart';

/// Nombre que WhatsApp les pone a los audios reenviados
/// (AUD-20260927-WA0014) y a las notas de voz (PTT-20260927-WA0003).
final whatsAppCodePattern =
    RegExp(r'(AUD|PTT)-(\d{4})(\d{2})(\d{2})-WA(\d+)', caseSensitive: false);

/// Si es una nota de voz (por el nombre del archivo).
bool isWhatsAppVoiceNote(String name) =>
    whatsAppCodePattern.firstMatch(name)?.group(1)?.toUpperCase() == 'PTT';

/// Un nombre legible para un audio de WhatsApp: "PTT-20260927-WA0003" pasa
/// a "Nota de voz 27-09-2026 (3)" y "AUD-…" a "Audio de WhatsApp …". Si el
/// nombre tiene algo más además del código, queda eso.
String friendlyWhatsAppTitle(String title) {
  final match = whatsAppCodePattern.firstMatch(title);
  if (match == null) return title;
  final rest = title
      .replaceAll(whatsAppCodePattern, '')
      .replaceAll(RegExp(r'^[\s\-_.]+|[\s\-_.]+$'), '');
  if (rest.isNotEmpty) return rest;
  final kind = match.group(1)!.toUpperCase() == 'PTT'
      ? 'Nota de voz'
      : 'Audio de WhatsApp';
  return '$kind ${match.group(4)}-${match.group(3)}-${match.group(2)} '
      '(${int.parse(match.group(5)!)})';
}

/// La fecha que viene en el nombre de WhatsApp (AUD-20260927-…), si tiene.
DateTime? whatsAppDate(String name) {
  final match = whatsAppCodePattern.firstMatch(name);
  if (match == null) return null;
  return DateTime.tryParse(
      '${match.group(2)}-${match.group(3)}-${match.group(4)}');
}

const _mimeByExtension = {
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'aac': 'audio/aac',
  'opus': 'audio/ogg',
  'ogg': 'audio/ogg',
  'wav': 'audio/wav',
  'flac': 'audio/flac',
};

/// Copia un audio recibido por WhatsApp (reenviado o nota de voz) a
/// Música/TK Music/Audios de WhatsApp para que la biblioteca lo tome como
/// una canción más. No mueve el original: WhatsApp podría necesitarlo.
class WhatsAppImportService {
  WhatsAppImportService({AudioImportRepository? repository})
      : _repository = repository ?? sl<AudioImportRepository>();

  final AudioImportRepository _repository;

  /// Dónde quedan los importados (para mostrarlo).
  static const destinationLabel = AudioImportRepository.whatsAppFolderLabel;

  Future<void> importToLibrary(Song song) async {
    final extension = _extensionOf(song.filePath);
    await _repository.importWhatsAppAudio(
      song,
      fileName: cleanFileName(song.title, extension),
      mimeType: _mimeByExtension[extension] ?? 'audio/*',
    );
  }

  String _extensionOf(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    final decoded = Uri.decodeComponent(name);
    final dot = decoded.lastIndexOf('.');
    return dot < 0 ? 'mp3' : decoded.substring(dot + 1).toLowerCase();
  }

  /// Nombre del archivo copiado: el nombre legible, sin caracteres que
  /// Windows/Android no aceptan. Sin el código de WhatsApp, así la
  /// biblioteca no lo vuelve a esconder.
  static String cleanFileName(String title, String extension) {
    var name = friendlyWhatsAppTitle(title)
        .replaceAll(RegExp(r'\.[A-Za-z0-9]{2,4}$'), '')
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .trim();
    if (name.isEmpty) {
      name = 'Audio importado ${DateTime.now().millisecondsSinceEpoch}';
    }
    return '$name.$extension';
  }
}
