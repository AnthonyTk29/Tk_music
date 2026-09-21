import 'package:flutter/material.dart';

/// Guía rápida de las secciones de la app, para no tener que ir
/// descubriendo a los tumbos qué hace cada cosa del menú lateral.
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Guía de uso')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: const [
          _HelpSection(
            icon: Icons.home_outlined,
            title: 'Principal, Buscar y Biblioteca',
            body: 'Tocá cualquier canción para reproducirla: arma la cola '
                'con todo lo que se ve en esa pantalla, en ese orden. En '
                'Biblioteca podés cambiar entre ver canciones, álbumes o '
                'artistas, y ordenar o filtrar por género con los chips de '
                'arriba. En listas largas aparece un índice A-Z al costado '
                'para saltar rápido.',
          ),
          _HelpSection(
            icon: Icons.thumb_up_outlined,
            title: 'Favoritos',
            body: 'Marcá una canción con el botón de "me gusta" desde la '
                'notificación o desde "Reproduciendo" para que aparezca acá.',
          ),
          _HelpSection(
            icon: Icons.queue_music_outlined,
            title: 'Playlists y "A continuación"',
            body: 'Creá playlists desde el menú lateral (☰) y sumá '
                'canciones desde el menú (⋮) de cualquier tema. "A '
                'continuación" (el ícono al lado de "Reproduciendo") '
                'muestra lo que sigue y se puede reordenar arrastrando.',
          ),
          _HelpSection(
            icon: Icons.usb,
            title: 'Almacenamiento externo',
            body: 'Conectá un pendrive por USB-OTG y elegí la carpeta desde '
                'el menú lateral para reproducir música directo desde ahí, '
                'sin sumarla a tu biblioteca.',
          ),
          _HelpSection(
            icon: Icons.chat_outlined,
            title: 'Importar de WhatsApp',
            body: 'Los audios recibidos por WhatsApp no aparecen en tu '
                'biblioteca por defecto. Desde acá podés escucharlos antes '
                'de decidir y copiar los que quieras a Download para que '
                'pasen a estar disponibles como una canción más.',
          ),
          _HelpSection(
            icon: Icons.graphic_eq,
            title: 'Mezclador automático',
            body: 'Elegí una playlist y arranca a mezclar sola, cruzando de '
                'una canción a otra y ajustando el volumen para que ningún '
                'cruce se sienta más fuerte o más flojo que el anterior. '
                'Sigue sonando aunque salgas de su pantalla: el botón "A" '
                'flotante que parpadea te avisa y te lleva de vuelta.',
          ),
          _HelpSection(
            icon: Icons.bluetooth_audio,
            title: 'Sincronizar con otro teléfono',
            body: 'Reproducí la misma canción al mismo tiempo en dos '
                'teléfonos ya emparejados por Bluetooth: uno es el '
                'anfitrión (elige la canción y controla la reproducción) y '
                'el otro se une como invitado.',
          ),
          _HelpSection(
            icon: Icons.equalizer,
            title: 'Ecualizador',
            body: 'Ajustá graves, medios y agudos de lo que está sonando en '
                'el reproductor principal. Se guarda solo y se mantiene '
                'activado la próxima vez que abras la app.',
          ),
          _HelpSection(
            icon: Icons.person_outline,
            title: 'Perfiles',
            body: 'Cada perfil tiene sus propios favoritos, playlists y '
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
