import 'package:flutter/material.dart';
import 'package:tk_music/core/platform.dart';
import 'package:tk_music/presentation/widgets/app_header.dart';

/// Guía rápida de las secciones de la app, para no tener que ir
/// descubriendo a los tumbos qué hace cada cosa del menú lateral.
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const AppHeaderTitle(section: 'Guía de uso')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          const _HelpSection(
            icon: Icons.alt_route,
            title: 'Migas de pan: dónde estás',
            body: 'Debajo del logo de cada pantalla se ve el camino hasta '
                'ahí, por ejemplo Inicio › Biblioteca › Artistas › Bad '
                'Bunny. Tocá cualquier parte del camino para volver directo '
                'ahí. En los gestores de carpetas pasa lo mismo con la ruta '
                'de carpetas, y la flecha hacia arriba sube una carpeta.',
          ),
          const _HelpSection(
            icon: Icons.home_outlined,
            title: 'Principal, Buscar y Biblioteca',
            body: 'Tocá cualquier canción para reproducirla: arma la cola '
                'con todo lo que se ve en esa pantalla, en ese orden. En '
                'Biblioteca podés cambiar entre ver canciones, álbumes o '
                'artistas, y ordenar o filtrar por género con los chips de '
                'arriba. En listas largas aparece un índice A-Z al costado '
                'para saltar rápido.',
          ),
          if (isDesktopPlatform)
            const _HelpSection(
              icon: Icons.folder_open,
              title: 'Biblioteca en la PC: todos los discos',
              body: 'La biblioteca son todas las canciones de todos los '
                  'discos de la PC: la app las busca sola (la primera vez '
                  'tarda un poco; después abre al instante y se actualiza '
                  'sola). En Biblioteca → Archivos está el gestor de '
                  'archivos: navegar discos y carpetas, ver las canciones '
                  'repetidas con la RECOMENDADA, la calidad y el volumen de '
                  'cada copia, escucharlas, marcar las que sobran y '
                  'mandarlas a la Papelera de reciclaje.',
            ),
          const _HelpSection(
            icon: Icons.thumb_up_outlined,
            title: 'Favoritos',
            body: 'Marcá una canción con el botón de "me gusta" desde la '
                'notificación o desde "Reproduciendo" para que aparezca acá.',
          ),
          const _HelpSection(
            icon: Icons.queue_music_outlined,
            title: 'Listas de reproducción y "A continuación"',
            body:
                'Creá listas de reproducción desde el menú lateral (el botón de '
                'arriba a la izquierda) y sumá canciones desde el menú de tres '
                'puntos de cualquier tema. "A '
                'continuación" (el ícono al lado de "Reproduciendo") '
                'muestra lo que sigue y se puede reordenar arrastrando.',
          ),
          const _HelpSection(
            icon: Icons.usb,
            title: 'Almacenamiento externo',
            body: 'Conectá un pendrive (por USB-OTG en el teléfono, o '
                'cualquier disco externo en la PC) y elegí la carpeta desde '
                'el menú lateral para reproducir música directo desde ahí, '
                'sin sumarla a tu biblioteca.',
          ),
          if (!isDesktopPlatform)
            const _HelpSection(
              icon: Icons.chat_outlined,
              title: 'Audios de WhatsApp',
              body: 'Un gestor de los audios recibidos por WhatsApp (que no '
                  'aparecen en tu biblioteca). La primera vez tocá "Habilitar '
                  'carpeta" y permití la carpeta de WhatsApp que se abre. '
                  'Después podés entrar por las carpetas (Carpetas) o ver '
                  'todos los audios juntos (Todos los audios), buscar y '
                  'escuchar cada uno. Marcá uno por uno, carpetas enteras o '
                  'todo con el botón de arriba, y elegí "A biblioteca" (se '
                  'copian a Música/TK Music/Audios de WhatsApp) o "Eliminar" '
                  '(pide confirmación y se borra para siempre). En los dos '
                  'casos se ve el avance y al final un resumen de lo que se '
                  'hizo y lo que no.',
            ),
          const _HelpSection(
            icon: Icons.cloud_outlined,
            title: 'En línea',
            body: 'En la pestaña En línea hay canciones completas para '
                'escuchar por internet: lo más escuchado por género y un '
                'buscador. Suenan con el reproductor de siempre. Las que '
                'tienen el botón de descarga se pueden guardar en tu '
                'biblioteca como MP3; las que muestran una nube solo se '
                'escuchan en línea, porque su artista no permite bajarlas.',
          ),
          const _HelpSection(
            icon: Icons.auto_mode,
            title: 'Mezclador automático',
            body: 'Elegí una lista y arranca a mezclar sola, cruzando de '
                'una canción a otra sobre el pulso y ajustando el volumen para '
                'que ningún cruce se sienta más fuerte o más flojo. Con "Orden '
                'inteligente" arma el set como un DJ, por ritmo, tonalidad y '
                'energía. '
                'Sigue sonando aunque salgas de su pantalla: el botón "A" '
                'flotante que parpadea te avisa y te lleva de vuelta.',
          ),
          if (isDesktopPlatform)
            const _HelpSection(
              icon: Icons.album_outlined,
              title: 'Modo DJ',
              body: 'Un controlador DJ al estilo VirtualDJ, en la PC: cargá '
                  'una canción en cada deck con CARGAR (o con el botón '
                  'Archivos de arriba): se puede elegir de la biblioteca o de '
                  'cualquier disco, solo MP3 y WAV, y las canciones repetidas '
                  'aparecen agrupadas: el gestor marca la RECOMENDADA y las de '
                  'BAJA CALIDAD, BAJO VOLUMEN, CORTADA o FORMATO FALSO, deja '
                  'escuchar cada copia y mandar las marcadas a la Papelera de '
                  'reciclaje (se pueden recuperar). '
                  'Cada deck tiene plato, pitch con tono FIJO, CUE (punto de '
                  'inicio), PLAY, 8 PUNTOS guardados (clic derecho borra), '
                  'BUCLES de 1 a 16 pulsos con bucle automático y SALTOS de '
                  'pulsos. SYNC iguala el BPM y alinea los pulsos; AUTO los '
                  'mantiene alineados solos; TONO hace combinar la tonalidad. '
                  'En el medio, volúmenes, crossfader y el botón '
                  'ECUALIZADOR, que abre la GANANCIA (potenciador de hasta '
                  '+12 dB) y los AGUDOS, MEDIOS y GRAVES de los dos decks; si '
                  'el vúmetro se pone rojo arriba, bajá la GANANCIA. MEZCLA '
                  'AUTO pasa de un deck al otro en 8, 16 o 32 pulsos, y el '
                  'Auto DJ hace sonar sola una lista entera, mezclando cada '
                  'canción con la siguiente. El deck A sale en mono por la izquierda y el B '
                  'por la derecha: el botón IZQ / DER hace sonar un pitido '
                  'por ese lado para comprobarlo. '
                  '"Grabar mezcla" graba solo lo que sale por los parlantes '
                  '(el estéreo completo) a un WAV en Música\\TK Music\\Mezclas. '
                  'Todo se maneja también con el teclado: el botón del '
                  'teclado (o F1) muestra qué tecla hace cada cosa. '
                  'Con un Numark Mixtrack Pro 3 enchufado, se detecta solo: '
                  'elegís si los altavoces están en la computadora o en el '
                  'controlador, y sus botones, platos, faders y luces manejan '
                  'los decks (cerrá VirtualDJ antes: el controlador lo usa un '
                  'programa a la vez).',
            ),
          const _HelpSection(
            icon: Icons.speaker_group,
            title: 'Sincronizar con otro dispositivo',
            body: 'Varios dispositivos (teléfonos o PC) escuchan la misma '
                'lista a la vez, por Wi-Fi (misma red o la zona Wi-Fi de un '
                'teléfono, hasta 15 invitados) o por Bluetooth (hasta 6). El '
                'anfitrión controla reproducir/pausa/siguiente y puede mezclar u '
                'ordenar la lista (también por ritmo y tonalidad); los '
                'invitados suman canciones de su biblioteca y todos pueden '
                'mandar reacciones con emojis. Con "Karaoke" la letra aparece '
                'grande y sincronizada en todos. Si alguno se desfasa o se '
                'desconecta, tiene "Resincronizar" y "Reconectar". Para '
                'unirse rápido, el anfitrión muestra un QR con el nombre de '
                'la sala y los invitados tocan "Unirse con QR" y lo escanean '
                '(por Bluetooth tienen que estar emparejados). Cada invitado '
                'se corrige solo varias veces por segundo; si un dispositivo '
                'igual suena atrasado (por ejemplo con un parlante '
                'Bluetooth), en "Sincronía" se sube su retraso hasta que '
                'suene junto con los demás.',
          ),
          const _HelpSection(
            icon: Icons.equalizer,
            title: 'Ecualizador',
            body: 'Ajustá graves, medios y agudos de lo que está sonando en '
                'el reproductor principal, con ajustes predefinidos o a mano, mirando el '
                'espectro en vivo. Se guarda solo y se mantiene activado la '
                'próxima vez que abras la app.',
          ),
          const _HelpSection(
            icon: Icons.lyrics_outlined,
            title: 'Letras',
            body: 'En "Reproduciendo", el botón de letra muestra la letra '
                'sincronizada: el renglón que suena resaltado, y tocando uno '
                'saltás ahí. Sale del MP3, de un archivo .lrc al lado de la '
                'canción o de internet (se puede apagar en Ajustes).',
          ),
          const _HelpSection(
            icon: Icons.edit_outlined,
            title: 'Editar información',
            body:
                'Desde el menú de tres puntos de cualquier canción podés corregir '
                'título, artista, álbum, género y carátula. También muestra '
                'su ritmo (BPM) y tonalidad.',
          ),
          const _HelpSection(
            icon: Icons.settings_outlined,
            title: 'Ajustes',
            body: 'Volumen parejo entre canciones, fundido (con cruce '
                'sobre el pulso), colores según la carátula y búsqueda de '
                'letras y carátulas en internet (para las canciones que no '
                'traen imagen).',
          ),
          const _HelpSection(
            icon: Icons.person_outline,
            title: 'Perfiles',
            body: 'Cada perfil tiene sus propios favoritos, listas y '
                'recientes, separados de los demás. Cambiá de perfil o '
                'cerrá sesión desde tu avatar, arriba a la derecha.',
          ),
        ],
      ),
    );
  }
}

class _HelpSection extends StatelessWidget {
  const _HelpSection({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      leading: Icon(icon),
      title: Text(title),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(body, style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}
