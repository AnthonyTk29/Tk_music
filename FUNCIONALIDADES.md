# TK Music — Funcionalidades

Reproductor de música para **Android** y **Windows** (con soporte parcial para Linux y macOS). Reproduce la música del dispositivo y también **música en línea** gratis y legal. Permite escuchar lo mismo a la vez en varios dispositivos por **Wi-Fi o Bluetooth**, con letras sincronizadas, karaoke, reacciones y mezcla automática estilo DJ.

---

## 1. Interfaz

- **Barra de abajo:** Principal, Buscar, Biblioteca, Favoritos y **En línea**.
- **Menú lateral:** Listas de reproducción, Almacenamiento externo, Audios de WhatsApp (solo Android), Mezclador automático, Modo DJ (solo desktop), Sincronizar con otro dispositivo, Ecualizador, Ajustes, Guía de uso y Acerca de.
- **Logo y nombre "TK Music" en todas las pantallas:** arriba el logo y el nombre, y debajo, en chico, el nombre de la pantalla ("Letra", "Ajustes"…). En elegir perfil y en el primer uso aparece en grande. Si el nombre de la pantalla no entra, se corta con "…".
- **Migas de pan (breadcrumbs) en todas las pantallas:** en cualquier pantalla abierta encima de otra, debajo del logo se ve el camino hasta ahí, por ejemplo **Inicio › Biblioteca › Artistas › Bad Bunny**, **Inicio › Almacenamiento externo › Pendrive › Música** o **Inicio › Reproduciendo › Letra**. Cada miga anterior se toca para volver directo a esa pantalla (sin ir de a una con Atrás); la actual queda resaltada. Si el camino no entra, se desliza y se ve siempre el final.
  - En los gestores de carpetas (Modo DJ y Biblioteca → Archivos en la PC, Audios de WhatsApp en Android) hay además una barra con la ruta de carpetas (disco › carpeta › subcarpeta), cada una tocable, y el botón **Subir una carpeta**.
- **Se adapta al tamaño:** en ventanas bajas o teléfonos chicos el contenido se desplaza en vez de desbordar; en pantallas anchas las cuadrículas agregan columnas en vez de agrandar las carátulas.
- En Windows, la ventana se llama **TK Music** y usa el ícono de la app.
- **Guía de uso** dentro de la app con todas las funciones.

## 2. Perfiles

- Varios perfiles por dispositivo ("¿Quién escucha?"), cada uno con sus propios **favoritos, listas de reproducción, recientes y ecualizador**.
- Opción **Recordarme** para no volver a elegir perfil al abrir la app.
- Cambio de perfil o cierre de sesión desde el avatar, arriba a la derecha.

## 3. Biblioteca

- **Android:** lee toda la música del teléfono (MediaStore), con título, artista, álbum, género, duración y carátula. Pide el permiso de audio al primer uso.
- **Windows: todas las canciones de todos los discos.** No hay que elegir ninguna carpeta: la app recorre todos los discos de la PC (MP3, M4A, AAC, WAV, FLAC, OGG, OPUS, WMA) y esa es la biblioteca de toda la app (Principal, Buscar, Favoritos, listas, Mezclador automático, Sincronizar…). El Modo DJ tiene su propio gestor.
  - La **primera vez** muestra el avance ("Buscando tus canciones en todos los discos… N archivos en M carpetas"). Después la lista queda guardada: la app **abre al instante** y vuelve a revisar los discos **en segundo plano** una vez por sesión; si aparecen o desaparecen canciones, la biblioteca se actualiza sola sin cortar lo que suena.
  - **Un disco que no se puede leer no frena nada:** una lectora de DVD vacía, un pendrive sacado o un disco que no responde se marca como **"No se pudo leer: E:\ (El dispositivo no está listo)"** y la búsqueda sigue con los demás. En el gestor de archivos aparece apagado, con "no se lee".
  - Se saltean las carpetas del sistema (Windows, Archivos de programa, AppData, Papelera…) y las de **juegos** (Steam, Epic, Riot, Xbox…), que tienen miles de efectos de sonido. Tampoco entran los audios de **menos de 15 segundos** (avisos, efectos).
  - **Carpetas fuera de la biblioteca:** si una carpeta tiene audios que no son música (sonidos de un programa o un juego, audiolibros…), en Biblioteca → Archivos se la saca con el ojo tachado (en la fila de la carpeta o estando adentro). Queda en **"Fuera de la biblioteca"**, al costado, para volver a incluirla; las revisiones siguientes ya no entran ahí.
  - Lo que agrega la app (descargas, importados) va a **Música\TK Music** y aparece enseguida, sin esperar la revisión.
  - Título, artista, álbum, género y duración salen de los **tags del archivo**, lo mismo que muestra el Explorador (con caché). Muestra la **carátula embebida** en el archivo (en MP3 se lee directo de la etiqueta).
- **Biblioteca → Archivos (solo desktop):** el **gestor de archivos del Modo DJ, en versión reproductor**. "Todas mis canciones" (la biblioteca completa), cada disco y las carpetas del usuario; todos los formatos (chips MP3, WAV y Otros). Las mismas herramientas: **repetidas** agrupadas con la **RECOMENDADA**, **calidad** y **volumen** de cada copia, BAJA CALIDAD / BAJO VOLUMEN / CORTADA / FORMATO FALSO, **pre-escucha** (pausa el reproductor), **marcar** (una, cada repetida o todas) y **mandar a la papelera** con confirmación. En vez de cargar en un deck, **PLAY** (o doble clic) reproduce con lo que se ve como cola. Arriba se ve cuándo se revisaron los discos y **"Buscar de nuevo en todos los discos"**.
- Vistas: **Canciones, Álbumes y Artistas**.
- Orden por **título, artista, más recientes o duración**, y filtro por **género** con chips.
- **Índice A–Z** al costado para saltar rápido en listas largas; se ajusta a cualquier tamaño de pantalla.
- **Buscar** por título, artista o álbum.

## 4. Editar información (editor de tags)

- Desde el menú **⋮** de cualquier canción → *Editar información*: **título, artista, álbum, género y carátula** (se elige una imagen y se guarda como JPEG de hasta 600 px).
- Los cambios se ven en **toda la app**: biblioteca, colas, "Reproduciendo", notificación y controles del sistema, y sesiones compartidas.
- Funciona con cualquier formato y en Android sin permisos extra: las correcciones se guardan en la app, encima de lo que trae el archivo.
- En Windows, los **MP3** se pueden guardar además **dentro del archivo** (etiqueta ID3), para que se vean igual en otros reproductores. El audio no se toca: el archivo se escribe aparte, se verifica y recién ahí reemplaza al original.
- **Restaurar original** vuelve a lo que trae el archivo.
- Muestra el **ritmo (BPM), la tonalidad (con código Camelot) y la energía** de la canción, y permite analizarlos.

## 5. Reproducción

- **Principal:** *Accesos directos* con lo último reproducido, en páginas que se deslizan. En el teléfono es una cuadrícula de 3×3; en pantallas anchas entran más columnas (carátulas de hasta unos 180 px) en 2 filas.
- **Mini reproductor** siempre visible abajo, con avance.
- **Reproduciendo:**
  - Carátula grande, título y artista, con **fondo y colores tomados de la carátula** (ver *Colores según la carátula*, más abajo).
  - **Forma de onda** estilo VirtualDJ que se desplaza mientras suena y permite tocar para saltar. Se analiza siempre en segundo plano, una sola vez por canción, empezando desde donde está sonando.
  - Barra de avance, anterior / play-pausa / siguiente, **aleatorio** y **repetir** (una o todas).
  - **Me gusta** (va a Favoritos).
  - **Letra** sincronizada (ver sección 6).
  - Menú **⋮**: reproducir, agregar a una lista, editar información, ver detalles.
  - **Temporizador de apagado**: pausa sola pasado el tiempo elegido.
- **A continuación:** la cola actual, reordenable arrastrando.
- **Colores según la carátula:** el fondo y los colores (botones, barras, onda, resaltados) toman el color del disco, con una transición suave al cambiar de canción. Se aplica en:
  - Reproduciendo, Letra y A continuación.
  - El **mini reproductor**, con la barra de avance del mismo color.
  - El Mezclador automático mientras suena.
  - La pantalla de cada **álbum o artista**.
  - La **sesión compartida**, en todos los dispositivos, con la carátula que manda el anfitrión.
  - Las canciones de la pestaña **En línea**, con su propia carátula.

  Si se cambia la carátula en el editor de tags, el color se actualiza al instante. Se apaga en Ajustes.
- **Carátulas de internet:** las canciones que no traen imagen en el archivo buscan la suya en el catálogo público de iTunes (gratis, sin cuenta; solo se envía artista y álbum o título). Se busca por álbum cuando se conoce, y si no hay etiquetas se aprovecha el nombre del archivo ("007. Artista - Tema"), ignorando etiquetas de relleno ("artist", "title") y ruido como "(HQ)" o "Letra". Solo se acepta un resultado cuyo artista coincida, así nunca aparece la carátula de otro disco.
  - Llegan de a una (unos 3 segundos cada una, primero lo que está en pantalla o sonando) y quedan guardadas en el dispositivo; lo que no se encuentra se vuelve a intentar a la semana.
  - Los colores según la carátula las usan igual que a las propias.
  - Se apaga en Ajustes → *Buscar carátulas en internet*.
- **Retoma** la última canción y posición al abrir la app.
- **Volumen parejo:** mide la sonoridad de cada canción y ajusta la ganancia para que todas suenen igual de fuerte. En Android, las grabadas bajas se amplifican con el realzador de volumen del sistema.
- **Fundido** (crossfade) de 1 a 12 segundos entre canciones, o reproducción continua sin pausas.
  - Con **cruce sobre el pulso**, el cruce arranca en un golpe de la canción que termina y la siguiente entra en su primer golpe, con los tempos emparejados (hasta ±8 % de velocidad, sin cambiar el tono, volviendo de a poco a la normal).
- **Controles del sistema:**
  - Android: notificación de reproducción (con me gusta y aleatorio) y pantalla de bloqueo.
  - Windows: **teclas multimedia** del teclado y la tarjeta de "lo que suena" del panel de volumen, con título, artista, álbum y línea de tiempo.

## 6. Letras sincronizadas

- Letra de lo que suena con el **renglón actual resaltado** y desplazamiento automático; tocar un renglón salta ahí.
- De dónde sale, en orden:
  1. Un archivo **`.lrc`** con el mismo nombre al lado de la canción.
  2. La letra guardada **dentro del MP3**.
  3. **LRCLIB**, un servicio gratuito de letras sincronizadas en internet. Solo recibe título, artista, álbum y duración, y se puede apagar en Ajustes. Si la canción no tiene artista cargado, lo saca del nombre del archivo ("Artista - Tema"), o busca con el nombre entero y solo acepta una letra cuyo artista aparezca en él. Ignora etiquetas de relleno ("artist", "title") y ruido como "(HQ)".
- Si no aparece en ningún lado, la pantalla dice dónde se buscó. Las que no están en LRCLIB se vuelven a buscar a la semana (a veces la comunidad las agrega).
- Formato LRC completo: varias marcas de tiempo por renglón (estribillos) y corrimiento `[offset:]`. También muestra letras sin sincronizar.
- Lo encontrado se guarda en el dispositivo. Si no había internet, lo vuelve a intentar la próxima vez.

## 7. Favoritos y listas de reproducción

- **Favoritos** con "me gusta", desde Reproduciendo o la notificación.
- **Listas de reproducción:** crear, renombrar, borrar, agregar canciones desde el menú ⋮ de cualquier tema, quitar y reordenar arrastrando.
- **Recientes** por perfil.

## 8. Ecualizador

- 5 bandas (graves a agudos), rango ±15 dB.
- Presets **Normal, Pop, Rock, Clásica** y **Usuario**; tocar una banda pasa a Usuario.
- **Espectro en vivo** (24 bandas, FFT propia calculada a partir del audio decodificado) y la forma de onda de lo que suena.
- Se guarda por perfil y se reaplica al abrir la app.
- Android usa el efecto de ecualizador del sistema; Windows usa un filtro de ecualización sobre el audio de media_kit.

## 9. Mezclador automático (Automix)

- Elegís una lista de reproducción y la mezcla sola con **fundido de 8 segundos** entre canciones.
- **Orden inteligente:** analiza el **ritmo, la tonalidad y la energía** de cada canción y arma el set como un DJ.
  - Empieza por la más tranquila.
  - Encadena tempos parecidos (o el doble o la mitad) y tonalidades compatibles en la rueda Camelot.
  - Va subiendo la energía de a poco.
- Alternativa: **orden aleatorio**.
- **Cruce sobre el pulso con tempos emparejados** (igual que el fundido del reproductor normal).
- **Empareja el volumen** entre canciones.
- Muestra BPM y tonalidad de lo que suena y de lo que sigue. Tiene forma de onda, lista de "Siguen" reordenable y "saltar a la siguiente".
- Sigue sonando aunque salgas de la pantalla: un botón flotante **"A"** avisa y te lleva de vuelta.
- Usa la notificación (Android) o los controles multimedia (Windows).

### Modo DJ (solo desktop)

Un mini controlador DJ dentro de TK Music, con el aspecto de VirtualDJ: dos decks y el mezclador ocupando toda la pantalla; las canciones se eligen en un gestor de archivos que se abre en una ventana.

- **Formas de onda en color por frecuencias**, como en los programas de DJ: 100 puntos por segundo (se ve cada golpe) y cada instante pintado según qué suena más: graves, medios y agudos con distinto tono, con un brillo en cada golpe; **cada deck con su color**: el **A en rojo/naranja/crema** y el **B en azul/celeste/blanco**; lo que ya sonó, más apagado. Se calcula decodificando la canción entera con filtros de graves/medios/agudos (unos 40 ms por cada 30 s de audio) y queda guardada en disco: la segunda vez aparece al instante. La vista de la canción entera usa los mismos colores.
- **Formas de onda arriba:** las dos canciones desplazándose con la aguja fija en el medio (las dos crecen hacia arriba desde su base, así los picos se comparan de un vistazo al mezclar), con la **grilla de pulsos** (más marcada en cada compás), el cue, los puntos guardados y el bucle sombreado. Muestran tiempo real, así con dos canciones sincronizadas se ven los pulsos alineados. Arrastrarlas mueve la canción.
- **Cada deck (A azul, B rojo):**
  - Título, artista, tiempo transcurrido y restante, **BPM** con decimales, **tonalidad** (Camelot) e indicador **MAESTRO** (el deck que marca el ritmo).
  - El BPM y la tonalidad aparecen apenas se calculan, sin esperar a la forma de onda. Si no se pueden calcular (archivo raro o análisis trabado más de un minuto), dice **"sin BPM · reintentar"** en vez de quedar analizando.
  - Vista de la canción entera (tocar salta ahí) y **plato** que gira a 33⅓ rpm. Girar el plato con la canción sonando la apura o la frena un instante (para empatar a mano); frenada, la mueve.
  - **Pitch** ±8 %, ±16 % o ±32 %, con tono **FIJO** (cambia el tempo sin cambiar el tono) y **cambio de tonalidad** por semitonos (b / #).
  - **CUE** (sonando vuelve al cue y frena; frenado marca el cue en el pulso más cercano), **PLAY**, **SYNC**, **AUTO** (sincronía automática) y **TONO** (sincronizar tonalidad). CUE, PLAY y SYNC quedan con el nombre que tienen en cualquier controlador DJ.
  - Pads con tres modos: **PUNTOS** (8 puntos guardados de colores, clic derecho borra), **BUCLE** (1, 2, 4, 8 y 16 pulsos, bucle automático, ½ y ×2) y **SALTO** (1, 4, 8 y 16 pulsos adelante o atrás).
- **Salida dividida (siempre):** el deck **A sale en mono solo por la izquierda** y el **B en mono solo por la derecha**, conecte lo que conecte (auriculares, parlantes o un mixer externo). El botón **🔊 IZQ / 🔊 DER** de cada deck hace sonar tres pitidos solo por su lado, para comprobar por dónde sale.
- **Mezclador desplegable:** el botón de arriba del mezclador lo pliega a una columna angosta (vúmetros y crossfader vertical) para darle más lugar a los decks; se recuerda la próxima vez.
- **Ecualizador en su ventana:** la GANANCIA y los AGUDOS, MEDIOS y GRAVES de los dos decks están en una ventana aparte (botón **ECUALIZADOR** del mezclador, o **F4**), con perillas grandes, el valor en dB ("KILL" si la banda está apagada) y **Centrar todo** por deck. En el mezclador queda un aviso chico si un canal tiene algo movido.
- **Perillas centradas:** GANANCIA, AGUDOS, MEDIOS, GRAVES y GENERAL arrancan apuntando arriba al medio (0 dB) aunque el rango no sea simétrico, y al girarlas se "enganchan" en el centro.
- **Mezclador:** fader de volumen y vúmetro por canal (la **GANANCIA**, potenciador de −12 a +12 dB, y el ecualizador de 3 bandas con "kill" están en su ventana), volumen **GENERAL** (hasta +6 dB) y **crossfader** de potencia constante.
  - Los volúmenes son reales en dB (el volumen de mpv es cúbico y se convierte).
  - Al potenciar por encima del original la señal puede saturar (esta versión del reproductor no trae limitador): el vúmetro se marca en rojo arriba.
- **Sync:** iguala el BPM con el otro deck (acepta doble o mitad de tempo) y alinea los pulsos. Si el tempo no entra en el rango del pitch, lo agranda solo.
- **Sincronía automática (AUTO):** el deck sigue solo el tempo y los pulsos del otro sin desfasarse, también durante el crossfade: corrige el desfase de a poco (apurándose o frenándose un pelo) o salta al pulso si se fue lejos.
- **Sincronizar tonalidad:** cambia el tono del deck para que combine con el otro en la rueda Camelot (la misma casilla o una vecina, lo que pida mover menos).
- **Bucle automático:** busca cerca una parte musical pareja (sin silencios ni cortes, según la forma de onda) que arranque en un compás, y arma un bucle de 4 pulsos; tocándolo otra vez pasa a 8, a 16 y se apaga.
- **MEZCLA AUTO:** pasa al otro deck en 8, 16 o 32 pulsos: lo sincroniza, lo arranca en el primer tiempo del próximo compás, mueve el crossfader solo y al final frena el que sale.
- **Gestor de archivos** (botón **Archivos** arriba, o **CARGAR** en cada deck para cargar directo en ese deck):
  - **Solo MP3 y WAV**, con filtros para mostrar uno u otro.
  - A la izquierda: la **Biblioteca TK Music**, **Todas las canciones** (busca en todos los discos de la PC, con avance y botón para detener; lo encontrado se recuerda mientras la app esté abierta), cada **disco** (C:, D:…) para navegar carpeta por carpeta, y accesos a Música, Escritorio y Descargas.
  - En una carpeta: subcarpetas, sus MP3/WAV, "subir" y **Buscar aquí y en subcarpetas**.
  - **Canciones repetidas:** la misma canción aunque el archivo se llame distinto ("003 - La droga", "La droga (1)", "La droga - copia", "from YouTube"…) aparece una sola vez marcada **REPETIDA ×N**; al tocarla se despliegan todas las copias con su carpeta, y cada una se puede cargar. Si pesan exactamente lo mismo dice **IDÉNTICAS**. El filtro **Solo repetidas** muestra nada más esas.
  - Búsqueda por canción, artista o carpeta; BPM, tonalidad, tipo y tamaño. Doble clic carga en el deck libre. No deja cargar en un deck que está sonando.
  - El número de pista del comienzo se ignora aunque venga pegado ("007.grupo caneo - negrita" = "Grupo Caneo - Negrita").
  - Se saltean las carpetas del sistema (Windows, Archivos de programa, Papelera…) y las que no se pueden leer.
  - **Calidad y volumen:** columna **CALIDAD** (kbps del MP3 en verde/amarillo/rojo, o "WAV 16/44") y **VOL dB** (volumen medido). Marcas en cada archivo:
    - **BAJA CALIDAD:** MP3 de menos de 192 kbps, menos de 44,1 kHz o mono.
    - **BAJO VOLUMEN:** muy bajo (menos de −20 dB) o 4 dB o más por debajo de su copia más fuerte.
    - **CORTADA:** dura 8 s o más menos que la copia más larga.
    - **FORMATO FALSO:** la extensión miente (por ejemplo un M4A de YouTube renombrado a .mp3; se reconoce por los primeros bytes del archivo).
    - **RECOMENDADA:** la mejor copia de una repetida, la que conviene dejar. Gana la calidad (WAV > MP3 320 > 256…), después que no esté cortada ni más baja que las otras. El cartelito dice por qué.
  - Al desplegar una repetida se miden sus copias; **Revisar repetidas** revisa todas las que se ven, con avance y botón para detener. En el grupo, A / B cargan la copia recomendada.
  - **Pre-escucha:** el botón de play de cada archivo lo hace sonar (arranca al 30 % de la canción) con una barra para moverse. Pasando de una copia a otra de la misma canción, arranca en el mismo momento, así se comparan de oído. Si hay un deck sonando avisa que sale por los mismos parlantes.
  - **Marcar y borrar:** casilla en cada archivo, en cada repetida (todas sus copias) y arriba (**todas las que se ven**). **Marcar las copias peores** funciona en **todas las repetidas de la lista** (no hace falta abrirlas): revisa primero las que falten, con avance y botón para detener, y marca en cada una todas las copias menos la recomendada. Si se detiene, marca las ya revisadas y avisa cuántas faltan. **Mandar a la papelera (N)** pide confirmación con la lista y el espacio a liberar; mientras se mandan se ve una **barra de avance con porcentaje** ("X de N", el archivo actual); al terminar confirma cuántos se borraron, cuánto se liberó y cuáles no se pudieron (en uso o sin permiso). Van a la **Papelera de reciclaje** de Windows: se pueden recuperar. Las canciones cargadas en un deck no se pueden marcar. Si se borró algo de la biblioteca, se vuelve a leer.
- Al entrar se pausa el reproductor normal (y el Mezclador automático); las teclas multimedia y el panel de Windows controlan los decks. Al salir con música sonando, pregunta antes.
- Los bucles son exactos (el bucle A-B del reproductor) y los cue, puntos, bucles y saltos caen en la grilla de pulsos.
- **Auto DJ (lista que suena sola):** botón **Auto DJ** arriba (o **F8**). Se arma una lista con canciones de **Archivos** (cualquier disco: botón "+ LISTA" en cada fila o doble clic) o con una **lista guardada**; se reordena arrastrando, se sacan canciones y se guarda para la próxima vez.
  - **Arrancar Auto DJ:** si no suena nada, pone la primera en el deck del lado del crossfader y la arranca. Siempre deja **la siguiente cargada en el deck libre** y, cuando a la que suena le queda lo justo, **la mezcla sola** con la mezcla automática: la sincroniza, la hace entrar en el primer tiempo del próximo compás y mueve el crossfader en **8, 16 o 32 pulsos**. Al terminar, carga la que sigue en el deck que quedó libre.
  - **Mezclar ya** pasa a la siguiente sin esperar el final. **Orden inteligente** ordena lo que falta por ritmo, tonalidad y energía. La ventana muestra qué suena, qué sigue y qué ya sonó; se puede cerrar y el Auto DJ sigue (el botón de arriba muestra "Auto DJ · 3/12"). Mientras tanto se pueden seguir tocando los decks.
- **Grabar mezcla:** el botón rojo de arriba (o **F9**) graba **solo lo que sale por la salida de audio de la computadora**, en estéreo tal cual se escucha (deck A a la izquierda, deck B a la derecha, con crossfader, ecualizador y volumen general aplicados), a un **WAV** de 16 bits en **Música\TK Music\Mezclas** ("Mezcla AAAA-MM-DD HH.MM.SS.wav").
  - Mientras graba muestra el tiempo y un vúmetro de lo que entra (amarillo si satura).
  - Al terminar avisa dónde quedó, con **Ver archivo** para abrir la carpeta.
  - Los silencios quedan grabados (la duración es la real). Si se cambia o desconecta la salida de audio, corta y guarda lo grabado hasta ahí; al salir del Modo DJ o cerrar la app grabando, también cierra bien el archivo.
  - Graba todo lo que suena en la PC en ese momento: si otra app hace ruido, también entra.
- **Atajos de teclado:** cada botón tiene su tecla, para mezclar sin mouse. El botón del teclado (o **F1**) abre la sección **Atajos de teclado**: un teclado dibujado con cada tecla pintada del color de su deck y lo que hace, y la lista de cada atajo con **para qué sirve**. Los cartelitos de los botones también dicen su tecla.
  - El deck A va con la mitad izquierda del teclado y el B con la derecha, con la misma forma:

    | Acción | Deck A | Deck B |
    |---|---|---|
    | Pads 1–4 del modo elegido (Shift: 5–8; Alt: borrar punto) | 1 2 3 4 | 7 8 9 0 |
    | Cambiar modo de pads (PUNTOS → BUCLE → SALTO) | 5 | 6 |
    | CUE · PLAY · SYNC · AUTO · TONO (Shift: tono original) | Q W E R T | Y U I O P |
    | Pitch − · + (0,1 %; Shift 1 %) · a 0 · rango · FIJO | A S D F G | H J K L Ñ |
    | Semitono b · # · CARGAR · probar salida | Z X C V | N M , . |

  - Mezclador y general: **← →** crossfader (Shift: al extremo), **Espacio** crossfader al centro, **↑ ↓** volumen general, **Intro** mezcla automática (otra vez la cancela), **F5 / F6 / F7** mezcla en 8 / 16 / 32 pulsos, **F2** archivos, **F3** plegar el mezclador, **F4** ecualizador, **F8** Auto DJ, **F9** grabar, **F1** atajos.
  - Se reconocen por su lugar en el teclado, así funcionan igual con teclado español o inglés. Ctrl y Win quedan libres; mantener apretado repite solo en pitch, crossfader y volumen.
- **Controlador DJ: Numark Mixtrack Pro 3** (y Mixtrack 3), por MIDI:
  - **Se detecta solo** al enchufarlo con el Modo DJ abierto: aparece **"Nuevo dispositivo detectado"** (como en VirtualDJ) con el equipo y **dónde están conectados los altavoces**: **Computador** o **MixTrack PRO 3** (su salida MASTER). Con **"No mostrar de nuevo"** la próxima vez usa lo elegido sin preguntar. Al desenchufarlo, el sonido vuelve a la computadora.
  - Arriba aparece un botón con el controlador conectado: cambiar los altavoces, **invertir el fader de pitch**, la lista de **qué hace cada control** y un **monitor** que muestra cada mensaje que llega y qué hizo.
  - **Todo maneja los decks:** PLAY (sin canción abre los archivos), CUE (mantenido en el CUE suena mientras lo apretás), SYNC (SHIFT: sincronía automática), platos (tocándolos arriba mueven la canción como un vinilo; por el costado la apuran o frenan un instante; botón SCRATCH), pitch de 14 bits, PITCH BEND ±, pads (puntos 1-4, bucles de 2/4/8/16 y saltos de ±1/±4), LOOP IN / OUT / RELOOP / ½, PAD MODE (cambia los pads en pantalla), TAP = TONO, ecualizador, FILTER = GANANCIA, faders de canal, crossfader, MASTER, LOAD A/B y BROWSE.
  - **Toma suave:** un fader o perilla no manda hasta que su posición alcanza la de la pantalla, así nada pega saltos al conectar.
  - **Luces:** PLAY, CUE, SYNC, puntos, bucles, SCRATCH y los **vúmetros** del controlador siguen el estado real. Al salir se apagan.
  - "Grabar mezcla" graba la salida elegida (también la placa del controlador).
  - Sin función por ahora: FX 1-3, BEAT, TOUCH STRIP, girar BROWSE y la salida de **auriculares** (CUE de auriculares, CUE GAIN y CUE MIX).
  - Un controlador MIDI lo puede usar **un solo programa a la vez**: con VirtualDJ (u otro) abierto, TK Music avisa que está ocupado.

## 10. Almacenamiento externo

- Reproducir música directo desde un **pendrive** (USB-OTG en Android) o **cualquier disco o carpeta externa** (Windows), sin sumarla a la biblioteca.
- Las carpetas conectadas se recuerdan por perfil; se navega por subcarpetas.

## 11. Audios de WhatsApp y música en línea

### Audios de WhatsApp (solo Android)

Menú → **Audios de WhatsApp**: un gestor de archivos de los audios recibidos por WhatsApp (audios reenviados, notas de voz y audios mandados como documento), que normalmente no aparecen en la biblioteca.

- **Habilitar la carpeta de WhatsApp** (una sola vez): se abre el selector de Android directo en `Android/media/com.whatsapp/WhatsApp/Media`; se toca "Usar esta carpeta" y "Permitir". Hace falta porque WhatsApp guarda las notas de voz donde el sistema no las indexa (`.nomedia`). La app la recuerda; se puede cambiar desde el menú ⋮ de la pantalla. Sin habilitarla solo se ven los audios reenviados y solo se pueden pasar a la biblioteca.
- **Carpetas:** se entra carpeta por carpeta (WhatsApp Audio, WhatsApp Voice Notes, WhatsApp Documents…), con la ruta arriba y el botón **Subir una carpeta** (o Atrás). Solo se muestran las carpetas que tienen audios, con cuántos tienen y cuánto ocupan. Las carpetas semanales de las notas de voz (`202439`) se muestran como "Semana 39 de 2024".
- **Todos los audios:** todos juntos, los más nuevos primero, con filtros **Todos / Notas de voz / Audios** y la carpeta de cada uno.
- **Buscar:** en la carpeta actual (y las de adentro) o en todos los audios.
- **Escuchar** cada audio con ▶ antes de decidir.
- **Marcar:** uno por uno, carpetas enteras, o **todo lo que se ve** con el botón de arriba. La selección se mantiene al moverse entre carpetas; abajo se ve cuántas carpetas y audios hay marcados.
- **A biblioteca:** copia los audios marcados (los de las carpetas marcadas también), con el nombre limpio, a **Música/TK Music/Audios de WhatsApp**. Ventana de avance ("X de N", porcentaje y el audio actual) y resumen: cuántos pasaron y cuáles no, con el motivo. Los que ya pasaron quedan con la marca **En biblioteca**; si se vuelven a elegir, pregunta si pasar solo los nuevos o todos otra vez. El original no se toca.
- **Eliminar:** borra los audios y **carpetas enteras** marcadas. Primero una alerta con lo que se va a borrar, cuánto se libera y un aviso si esas carpetas también tienen fotos, videos o documentos (se borran también); después la ventana de avance y un resumen de lo que se borró y lo que no. Es definitivo: el teléfono no tiene papelera. Si Android no dio permiso para borrar, el resumen explica cómo volver a habilitar la carpeta.
- Nombres legibles: `PTT-20260927-WA0003` se muestra como "Nota de voz 27-09-2026 (3)" y `AUD-…` como "Audio de WhatsApp …".
  - Antes se copiaban a Download, pero en Android 10+ el sistema no deja crear audios ahí (fallaba) y además la biblioteca los volvía a esconder por tener el código de WhatsApp en el nombre.
- En Windows no está en el menú: los audios de WhatsApp de la PC ya entran solos a la biblioteca (se buscan en todos los discos).

### En línea

- Pestaña **En línea** en la barra de abajo: canciones completas para **escuchar por internet** sin bajarlas.
  - **Lo más escuchado** de la semana, con filtro por género (Latina, Pop, Urbano, Electrónica, Reggae, Dancehall, R&B, Rock, Jazz, Acústica, Lo-Fi).
  - **Buscar** por canción o artista.
  - Se ven solo las canciones (carátula, título, artista, duración), sin mostrar de qué servicio vienen.
- Suenan con el reproductor de siempre: mini reproductor, Reproduciendo, cola, **colores según la carátula**, notificación y controles del sistema.
- **Descargar:** solo cuando el artista lo permite sin condiciones. Se guarda como MP3 (320 kbps) en la biblioteca, con título, artista, género y carátula adentro del archivo. Las demás muestran una nube: se escuchan pero no se bajan.
- Lo que no aplica a las canciones en línea: volumen parejo, cruce sobre el pulso, forma de onda, favoritos y listas (se pueden usar una vez descargadas).
- Si no hay internet o el servicio no responde, lo avisa con un botón **Reintentar**. Las listas se guardan 10 minutos para no pedirlas de nuevo a cada rato.
- Fuente (interna, no se muestra): catálogo abierto de **Audius**, con música que los propios artistas publican para escuchar en streaming y, si quieren, descargar. Es música de artistas independientes: no incluye artistas de sellos comerciales.
- La app **no descarga de YouTube, Spotify ni otras plataformas de streaming**, a propósito: sus condiciones no lo permiten y Google Play retira las apps que lo hacen.

## 12. Sincronizar con otro dispositivo

Varios dispositivos escuchan **la misma lista, al mismo tiempo**. Funciona **entre Android y Windows en cualquier combinación**.

**Conexión: Wi-Fi o Bluetooth**

| | Wi-Fi (recomendado) | Bluetooth |
|---|---|---|
| Invitados | Hasta **15** | Hasta **6** (queda un lugar libre para auriculares o parlante) |
| Velocidad | Las canciones llegan en segundos | ~100–200 KB/s repartidos entre todos |
| Requisito | Misma red, o la **zona Wi-Fi** (hotspot) de un teléfono | Dispositivos emparejados |
| Cómo se encuentran | **Escaneando el QR** del anfitrión, o aparece solo en la lista de la red; si no, se escribe su IP | **Escaneando el QR** del anfitrión, o se elige de la lista de emparejados |
| Arranque | Cuando el anfitrión quiere; los que llegan después se suman | Si eligió invitados, al conectarse todos (o "Empezar con los que ya están"); si no, cuando él quiere |

En Bluetooth también se verifica la **capacidad** del equipo (detecta los que solo tienen Bluetooth LE) y se marca qué emparejados están **conectados ahora**.

**Unirse con QR**
- El anfitrión le pone un **nombre a la sala** (si no, usa el nombre del dispositivo) y, durante la sesión, ve una tarjeta con el **QR**, "TK Music" y "Sala: …", con opción de **verlo en grande**.
- El invitado toca **"Unirse con QR"** (en la primera pantalla o en la de buscar anfitriones) y lo escanea: la app sabe sola si es por Wi-Fi o Bluetooth y se conecta.
  - **Wi-Fi:** el QR lleva las direcciones del anfitrión y su puerto real; se prueba primero la que está en la misma red que el invitado y, si no responde, las demás.
  - **Bluetooth:** el QR lleva el nombre del Bluetooth del anfitrión (y en Windows también su dirección y su canal). El invitado tiene que tenerlo **emparejado**; si no, la app le avisa y le abre el Bluetooth del sistema. Con QR, el anfitrión Bluetooth ya no necesita elegir invitados de antemano.
- Lector: en **Android**, la cámara lee el QR en vivo. En **Windows**, la cámara de la PC saca fotos seguidas y la app las analiza. En los dos se puede **elegir una imagen del QR** (por ejemplo, una captura que te mandaron).
- Solo acepta QR de TK Music: si ve otro, avisa y sigue buscando.

**Lista compartida**
- El anfitrión la arma con **varias canciones** o **una lista guardada**, y puede agregar o quitar durante la sesión.
- **Los invitados también agregan canciones** de su propia biblioteca. Se suben al anfitrión en segundo plano (con porcentaje) y él las reparte al resto. Cada canción muestra **quién la agregó** y su **BPM y tonalidad**.
- **Mezclar:** orden aleatorio de lo que viene.
- **Ordenar automáticamente:** por título, artista, álbum, duración, **ritmo (BPM)** o **inteligente** (ritmo, tonalidad y energía, como un DJ). Se mantiene ordenada cada vez que alguien agrega canciones; *"Como se fueron agregando"* vuelve al orden de llegada.

**Reproducción**
- El anfitrión controla **anterior / play-pausa / siguiente**, la **barra para buscar** y puede tocar cualquier canción de la lista. Pasa sola a la siguiente al terminar.
- Todos ven la **carátula, título, artista, álbum** y el avance.
- **Sincronía de reloj** tipo NTP por invitado y **corrección continua del desfase**:
  - Menos de 25 ms: no hace nada.
  - Entre 25 y 300 ms: ajuste suave de velocidad (±4 %).
  - Más de 300 ms: salto directo.

**Karaoke y reacciones**
- **Modo karaoke:** la **letra sincronizada, grande**, en todos los dispositivos. El anfitrión la busca y la reparte; cada invitado también puede prenderlo solo en su pantalla.
- **Reacciones** ❤️ 🔥 😂 👏 🎉 💃: aparecen flotando en la pantalla de **todos**, con el nombre de quién las mandó. Hay un límite de ritmo para que nadie la llene.

**Transferencia y streaming**
- Las canciones se envían **en trozos en segundo plano**: primero la que suena, después las siguientes. Los controles nunca quedan trabados detrás de una transferencia.
- **Porcentaje de carga** de cada canción y del invitado más atrasado.
- **Streaming:** el invitado empieza a escuchar **antes de tener el archivo completo**, apenas lo recibido alcanza para no cortarse.
- Si el anfitrión salta a otra canción, esa pasa primero.
- Los archivos recibidos se **borran al terminar** la sesión.

**Cómo se conectan (Wi-Fi y Bluetooth van por separado)**
- Cada sesión usa **un solo** transporte, el que se eligió al empezar (o el que dice el QR): la parte de Wi-Fi y la de Bluetooth no se mezclan. Por encima hablan el mismo protocolo, así que el resto (lista, reloj, archivos, reacciones) funciona igual con los dos.
- **Wi-Fi:** el invitado recién se da por conectado cuando el anfitrión lo saluda. Si la sala está llena (15) o del otro lado no hay un anfitrión de TK Music, avisa enseguida en vez de quedarse "Conectando…".
- **Bluetooth:** el invitado Android prueba varias formas antes de rendirse: buscar el servicio de TK Music (cifrado y sin cifrar) y, si eso falla, conectarse directo al canal del anfitrión (el del QR, o el **canal 22**, que es el fijo del anfitrión en Windows). Así funciona también con placas Bluetooth de PC y teléfonos con los que la búsqueda del servicio falla.
- Los avisos de error son **distintos para cada uno**: qué revisar en Wi-Fi (misma red, firewall de Windows, redes que no dejan verse) o en Bluetooth (anfitrión por Bluetooth con la sesión iniciada, vinculados), y al final un **"Detalle"** con el motivo técnico de cada intento.

**Precisión de la sincronía**
- **Reloj:** el invitado mide la diferencia de reloj con 10 idas y vueltas y se queda con las 3 más rápidas (una respuesta que viajó detrás de un pedazo de archivo tarda más y falsearía la medida). Se vuelve a medir cada 30 s.
- **Posición exacta:** en Windows la posición del reproductor se calcula al milisegundo entre los avisos del reproductor (que llegan cada ~50–100 ms).
- **Arranque:** se espera la hora exacta de arranque con precisión de ~1 ms (el temporizador común se pasa hasta 15 ms en Windows).
- **Corrección continua:** cada invitado se compara solo, **cada 0,3 s**, con la última referencia del anfitrión. Por debajo de 12 ms no toca nada; hasta 400 ms apura o frena en proporción al desfase (hasta ±6 %, sin cambiar el tono) y se acerca de a poco sin pasarse; más, salta directo.
- **Ajuste fino por dispositivo ("Sincronía"):** el **retraso de este dispositivo** (−600 a +600 ms, de a 10 o 50) compensa el parlante: uno Bluetooth suma 150–300 ms que ningún reproductor informa. Se escucha el cambio en el momento y queda guardado. El invitado ve además su desfase medido ("Muy bien · +3 ms").
- Probado de punta a punta con dos reproductores reales conectados por Wi-Fi: **0–2 ms** de diferencia, y con +100 ms de ajuste el invitado queda 100 ms adelante.

**Recuperación**
- **Resincronizar** (invitado) o **Resincronizar invitados** (anfitrión): vuelve a medir el reloj y se alinea con lo que suena.
- **Reconectar** si se corta la conexión, sin volver a bajar lo que ya tenía.

## 13. Ajustes

- **Volumen parejo** entre canciones.
- **Fundido** (0 a 12 s) y **cruce sobre el pulso**.
- **Buscar carátulas en internet** para las canciones que no traen imagen.
- **Colores según la carátula** en todas las pantallas de lo que suena.
- **Buscar letras en internet**.

## 14. Alertas y errores

- Cada error tiene un **código** y un mensaje para el usuario; el detalle técnico va siempre al log.
- Alertas con ícono y color según gravedad (**advertencia** / **error**).
- Red de seguridad global para errores no previstos y lectura segura de datos guardados: un dato corrupto se descarta sin romper la app.
- **Firebase Crashlytics** en Android: informe automático de cierres inesperados.

## 15. Diferencias por plataforma

| Función | Android | Windows | Linux / macOS |
|---|:---:|:---:|:---:|
| Biblioteca con tags y carátulas | ✅ | ✅ | Solo nombre de archivo |
| Carátulas de internet para las que no traen | ✅ | ✅ | ✅ |
| Reproducción, cola, favoritos, listas | ✅ | ✅ | ✅ |
| Volumen parejo | ✅ | ✅ | — |
| Fundido entre canciones | ✅ | ✅ | ✅ (sin cruce sobre el pulso) |
| Editor de tags | ✅ (en la app) | ✅ (en la app + MP3) | ✅ (en la app) |
| Colores según la carátula (en todas las pantallas de lo que suena) | ✅ | ✅ | Con carátula propia o de internet |
| Letras sincronizadas | ✅ | ✅ | ✅ |
| Forma de onda, espectro, BPM y tonalidad | ✅ | ✅ | — |
| Ecualizador | ✅ | ✅ | ✅ |
| Temporizador de apagado | ✅ | ✅ | ✅ |
| Mezclador automático | ✅ | ✅ | ✅ (sin orden inteligente) |
| Modo DJ (dos decks) | — | ✅ | ✅ (sin BPM ni tonalidad: sin sync) |
| Almacenamiento externo | ✅ | ✅ | ✅ |
| Audios de WhatsApp (ver, pasar, borrar) | ✅ | — | — |
| En línea (escuchar y descargar) | ✅ | ✅ | ✅ |
| Controles del sistema | Notificación | Teclas y panel de Windows | — |
| Sincronizar por **Wi-Fi** | ✅ | ✅ | ✅ |
| Sincronizar por **Bluetooth** | ✅ | ✅ | — |
| Crashlytics | ✅ | — | — |

**Limitaciones conocidas**
- En Windows, las notas de voz `.ogg`/`.opus` suenan, pero no muestran onda ni espectro ni se analiza su ritmo: Windows no trae decodificador Opus.
- En Android 13 o superior, los archivos `.lrc` al lado de la canción pueden no ser accesibles (el sistema solo deja leer archivos de audio). Quedan la letra dentro del MP3 y la búsqueda en internet.
- En Windows, la primera sesión por Wi-Fi puede mostrar un aviso del firewall: hay que permitir el acceso.
- Algunas redes (Wi-Fi de hoteles o empresas) bloquean que los dispositivos se vean entre sí. Ahí conviene el hotspot de un teléfono o Bluetooth.
- En **En línea**, la mayoría de las canciones solo se pueden escuchar: el botón de descarga aparece únicamente cuando el artista la liberó.
- Las carátulas y letras de internet dependen de que la canción exista en esos catálogos; si no, la canción queda sin carátula o sin letra antes que mostrar una equivocada.

## 16. Instalar en Windows: instalador y versión portátil

Hay dos formas de llevar TK Music a otra PC con **Windows 10 u 11 de 64 bits**, y se generan juntas con un solo comando (ver "Cómo se generan").

### Instalador — `TK_Music_Setup_<versión>.exe` (~17 MB)
- Asistente en español. **No pide administrador**: instala solo para el usuario. Si se tienen permisos, se puede elegir instalarlo para todos.
- Crea el acceso en el **menú Inicio**, un **ícono en el escritorio** opcional, y al terminar ofrece abrir TK Music.
- Trae todo lo que necesita, incluido el runtime de Visual C++: abre en PCs donde nunca se instaló nada.
- **Actualizar:** se instala la versión nueva encima y reemplaza la anterior. Si TK Music está abierto, ofrece cerrarlo.
- **Desinstalar:** desde "Aplicaciones instaladas" de Windows. No se borran los datos del usuario.

### Portátil — `TK_Music_Portable_<versión>.zip` (~21 MB)
- No se instala: se descomprime y se abre **`tk_music.exe`** dentro de la carpeta "TK Music <versión>".
- Hay que llevar **la carpeta entera** (el exe, sus DLL y la carpeta `data`): el exe solo no abre.
- Sirve para usarlo desde un pendrive o en una PC donde no se quiere instalar nada.
- **Actualizar:** se reemplaza la carpeta. **Quitarlo:** se borra la carpeta.

### Qué conviene usar

| | Portátil (ZIP) | Instalador |
|---|---|---|
| Hay que instalar | No, se descomprime y listo | Sí, con asistente |
| Acceso en el menú Inicio / escritorio | No (se crea a mano) | Sí |
| Desinstalar | Borrar la carpeta | Desde "Aplicaciones instaladas" |
| Actualizar | Reemplazar la carpeta | Instalar la nueva encima |
| Aviso de Windows si se descargó de internet | **Sí, igual** | Sí |

### El aviso "Windows protegió su PC"
- Aparece porque el programa **no está firmado digitalmente** y **vino de internet** (WhatsApp, Drive, una página…). Da igual si es el instalador o el portátil.
- Se pasa con **"Más información" → "Ejecutar de todas formas"**.
- Si se copia por **pendrive**, normalmente no aparece.
- Para que no aparezca hay que firmarlo con un **certificado de firma de código** a nombre del autor. Opciones:
  - Publicarlo en la **Microsoft Store** (la Store lo firma).
  - **Azure Trusted Signing** (alrededor de USD 10 por mes, según el país).
  - Un certificado **OV** de Certum, Sectigo, SSL.com o DigiCert (con token USB o firma en la nube).
- Aun firmado, al principio SmartScreen puede avisar hasta que el programa junta "reputación" con las descargas.

### Los datos del usuario
- Perfiles, favoritos, listas, ajustes y análisis guardados quedan **en cada PC**, fuera de la carpeta del programa, con el instalador y con el portátil. Por eso desinstalar o borrar la carpeta no los borra, y el portátil no los lleva de una PC a otra.

### Cómo se generan

```powershell
powershell -ExecutionPolicy Bypass -File windows\installer\build_installer.ps1
```

El script hace, en orden:
1. Compila la app en Release (se saltea con `-SkipBuild`).
2. Copia al lado del exe el runtime de Visual C++ que trae Visual Studio.
3. Arma el instalador con **Inno Setup 6** usando `windows/installer/tk_music.iss`.
4. Arma el ZIP portátil.

El resultado queda en **`build\installer\`**, con la versión de `pubspec.yaml` en el nombre: para sacar una versión nueva, primero se sube `version:` ahí.

- Hace falta en la PC donde se compila: Flutter, Visual Studio 2022 con C++ e Inno Setup 6.
- El `AppId` del `.iss` no se cambia nunca: es lo que hace que una versión nueva actualice a la instalada en vez de instalarse al lado.
- Probado: el instalador se instaló en silencio, la app abrió desde la carpeta instalada y el desinstalador la quitó. El ZIP se descomprimió en otra carpeta y la app abrió desde ahí.

## 17. Arquitectura (resumen técnico)

- **Flutter** con Clean Architecture (dominio, datos, presentación) e inyección de dependencias con `get_it`.
- **Reproductor:** `just_audio` + `audio_service` en Android; `media_kit` (mpv) en desktop, detrás de la misma interfaz (`AppAudioHandler`). El fundido y el volumen parejo son comunes a los dos (`CrossfadeCoordinator`).
- **Análisis musical** en Dart: el código nativo solo decodifica un tramo de audio. Sobre eso se calculan:
  - Tempo, con flujo espectral y autocorrelación.
  - Fase de los pulsos.
  - Tonalidad, con croma contra los perfiles de Krumhansl–Schmuckler.
  - Energía.
  - El orden para mezclar, con costo de transición por tempo, rueda Camelot y energía.
- **Código nativo propio:**
  - Android (Kotlin): Bluetooth RFCOMM, decodificación con MediaCodec (onda, espectro, volumen, PCM para el análisis), almacenamiento externo (SAF), importación de WhatsApp, guardado de descargas en Música y candado de multicast para el descubrimiento Wi-Fi.
  - Windows (C++): Bluetooth con Winsock/RFCOMM, registro SDP y nombre/dirección del propio adaptador (para el QR), decodificación con Media Foundation, tags con el sistema de propiedades de Windows, carátulas con Shell + WIC, y controles multimedia (SMTC).
- **Sincronización:** un mismo protocolo por dos transportes, **Bluetooth** (nativo) y **Wi-Fi** (TCP + anuncio por UDP, en Dart).
  - Frames de control en JSON y archivos en trozos, con el final del archivo enviado primero.
  - En el invitado, un servidor HTTP local (`127.0.0.1`) sirve el archivo mientras llega.
- **Etiquetas ID3** (lectura, escritura, carátula y letra embebidas) y formato **LRC**, en Dart puro.
- **Modo DJ:** un reproductor mpv por deck (`DjDeck`). Pitch con la velocidad de mpv (tono fijo = corrección de tono de mpv); cambio de tonalidad con velocidad + `scaletempo`; bucles con el A-B loop de mpv. "Grabar mezcla" es una captura *loopback* de WASAPI (`windows/runner/loopback_recorder.h`, con un flujo de silencio en la misma salida para que los silencios también se graben), probada con un test nativo que reproduce un tono solo por la izquierda y revisa el WAV. El controlador: plugin MIDI propio con WinMM (`windows/runner/midi_plugin.cpp`, detecta al enchufar consultando cada 2 s), mapeo en `dj_controller.dart` con los números del Mixtrack (los mismos del mapeo libre de Mixxx) y la salida de cada deck elegida con `audio-device` de mpv. Los atajos están definidos en un solo lugar (`dj_shortcuts.dart`), de donde salen el manejo de las teclas y los cartelitos; la ayuda está en el mismo archivo. La libmpv de Windows trae FFmpeg recortado (de sus filtros de audio solo `equalizer`, sin `pan` ni conversor de formatos), así que la cadena de cada deck (`djDeckChain`) se arma con eso: conversión a muestras planas con el conversor de mpv, las 3 bandas en un solo filtro `equalizer` (se mueven en caliente con `af-command`), paso a mono y el otro lado apagado con ecualizadores a −60 dB. Un test mide la salida real (izquierda/derecha) con MP3 y WAV. `DjMixer` hace el crossfader, el sync y el auto sync (cada 50 ms), y las cuentas (fase, Camelot, auto loop) están en `dj_math.dart`.
- **QR de las salas:** invitación `tkmusic://join?...` (`SyncInvite`), dibujada con `qr_flutter`. Se lee con `mobile_scanner` en Android y, en Windows, con fotos de `camera_windows` decodificadas por `zxing2` (Dart puro, en un isolate).
- **Servicios de internet**, todos gratis y sin cuenta:
  - Carátulas: búsqueda pública de iTunes (`OnlineArtwork`), de a un pedido cada ~3 s y con caché en el dispositivo.
  - Letras: LRCLIB (`LyricsStore`).
  - Música en línea: API abierta de Audius, encapsulada en `OnlineCatalog` (las pantallas no saben de dónde viene; se puede cambiar o sumar otra fuente sin tocarlas).
  - La limpieza de títulos y artistas para buscar (nombre de archivo, etiquetas de relleno, ruido) es común a carátulas y letras (`SongIdentity`).
- **Descargas** (`Mp3LinkDownloader`): se verifica que sea MP3 por su contenido (etiqueta ID3 o cuadro MPEG Layer III), no por la extensión, con avance, cancelación y límite de tamaño. Se guardan en Música/TK Music (Android, vía MediaStore) o en `Música\TK Music\Descargas` (Windows).
