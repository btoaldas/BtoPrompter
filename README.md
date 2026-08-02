# BtoPrompter

**ES** — Teleprompter flotante para macOS, invisible al compartir pantalla.
**EN** — Floating teleprompter for macOS, invisible to screen sharing (Zoom, Teams, Meet). Word-by-word karaoke highlighting, adjustable speed and transparency. Pure Swift app, no dependencies.

---

## ¿Qué es?

BtoPrompter es un teleprompter que flota **encima de todas tus ventanas** mientras presentas, pero que **no aparece en la pantalla compartida** de Zoom, Teams, Meet ni en capturas de pantalla. Solo tú lo ves. Ideal para conferencias, clases en línea, videollamadas y grabaciones donde quieres leer un guion sin que se note.

### Características

- 🫥 **Invisible al compartir pantalla** — la ventana se excluye de capturas y streams (`NSWindow.sharingType = .none`). Conmutable con un clic (ojo verde/rojo).
- 🎤 **Karaoke palabra por palabra** — la palabra actual se resalta en amarillo, lo ya leído se atenúa, el texto avanza solo con scroll centrado. El resaltado nunca cambia el tamaño del texto: las líneas no saltan de sitio.
- ⏯️ **Control total** — play, pausa, reiniciar, saltar adelante/atrás, más rápido/más lento (palabras por minuto), pausas automáticas más largas en puntos y comas.
- 🌍 **Atajos globales** — pausa/play y velocidad funcionan aunque el foco esté en PowerPoint, Keynote o cualquier otra app, solo mientras el prompter está activo.
- 🗂️ **Biblioteca de discursos** — guarda, organiza en carpetas, marca borradores, archiva o elimina. Todo con guardado automático.
- 📥 **Importación** — texto (`.txt`), Markdown (`.md`), PowerPoint (`.pptx`, extrae el texto de las diapositivas) y audio (`.m4a`, `.mp3`, `.wav`…, transcrito con el motor de voz del sistema).
- 🏷️ **Líneas guía** — líneas que empiezan con `//` (y opcionalmente los títulos `#`) se ven en azul como referencia ("Diapositiva 2 — mirar al público") pero el karaoke no las lee ni las cuenta.
- ✨ **Ensayo con IA (opcional, apagado por defecto)** — un modelo de lenguaje marca el ritmo del discurso sin cambiar ninguna palabra: pausas (…), guías de actuación (`// Aquí más enfático`), signos de entonación y velocidades por tramo (`[v+20]`, `[v-30]`, `[v=]`). Compatible con Groq, OpenAI, OpenRouter o cualquier API estilo OpenAI con tu propia key. Estilos: conferencia, clase, dictado, motivacional o prompt personalizado. El resultado se guarda como discurso nuevo; el original queda intacto.
- 🪟 **Transparencia 0–100 %** — al 0 % desaparece el fondo y solo quedan las letras flotando sobre tu presentación o tu audiencia.
- 🎈 **No roba el foco** — es un panel no-activante: flota incluso sobre apps en pantalla completa y puedes hacer clic sin quitarle el teclado a tu presentación.
- 📏 **Modo minimalista** — barra delgada pegada arriba de la pantalla (debajo del notch), todo el ancho, karaoke en máximo 2 líneas con controles esenciales a los costados. Tecla `M` para entrar y salir; el alto se adapta al tamaño de letra.
- 🔠 **Tamaño de letra ajustable** en vivo.
- 🖱️ **Clic en cualquier oración** para saltar directamente ahí.
- ⚙️ **Configuración central** (engranaje o `⌘,`): General, Voz, Lectura, Diagnóstico, Ensayo IA, Remoto y actualizaciones. También accesible **durante la presentación**, sin parar ni volver al editor.
- 🎤 **Comprobación real del micrófono** — la pestaña Voz muestra el estado de los permisos nada más abrirla y el botón «Comprobar micrófono» abre la entrada de audio, mide el sonido que entra y responde con el nombre del micrófono y el nivel captado.
- ⏱️ **Cuenta regresiva y autoplay** — 3-2-1 configurable (0–10 s) antes de arrancar, y opción de reproducir automáticamente al entrar al prompter.
- 🗣️ **Seguimiento por voz (opcional)** — Apple local o nube, ElevenLabs, Deepgram, Mistral Voxtral, Soniox, AssemblyAI, Speechmatics y Gladia. Cada proveedor con **su API key, su modelo y su autorización por separado**, con prueba de clave incluida. Proveedor principal y respaldo configurables; si la voz falla, el guion sigue avanzando por tiempo en vez de quedarse congelado.
- 📥 **Modelos locales descargables** — catálogo Whisper (base a large v3 turbo) con descarga que se puede cancelar y **continuar donde quedó**, incluso tras cerrar la app.
- 🧭 **Alineación conservadora** — jamás retrocede por sí sola, ignora parciales duplicados y, ante frases repetidas o saltos grandes, espera contexto adicional antes de mover el guion.
- 🧰 **Diagnóstico local controlado** — logs rotados, eventos y grabación opcional solo de voz, con **cada palabra alineada al segundo exacto de la grabación**. Retención y espacio máximo configurables; claves y tokens se ocultan.
- 📈 **Análisis de tus ensayos** — informe con tu ritmo real, tus pausas más largas (y la palabra que las precede), tramos rápidos y lentos, correcciones y cuánto avanzaste hablando.
- 🧠 **Perfil local del orador (opcional)** — aprende ritmo, longitud de frase, conectores y muletillas de tus ensayos. Compartir ese resumen con Ensayo IA requiere un segundo permiso explícito.
- 🎨 **Estilos de ensayo propios** — crea, nombra, edita y elimina tus estilos, o **genera uno desde tus ensayos medidos**: con tus datos locales o redactado por la IA a partir de ellos.
- 🔊 **Lectura en voz alta multi-proveedor** — voces de macOS, **voces locales propias** (modelos Piper `.onnx` que instalas tú) o ElevenLabs, OpenAI, Gemini y Deepgram Aura, eligiendo modelo y voz. Lo local no envía nada a internet.
- 🎬 **Diapositivas automáticas (opcional)** — al cruzar una guía "// Diapositiva N" avanza la presentación: Keynote y PowerPoint por AppleScript, o **cualquier app** enviando la flecha derecha (Vista Previa, PDF, navegador).
- ⏱️ **Cronómetro de ensayo** — al terminar te dice tiempo real, ritmo efectivo y, si pones una meta en minutos, la velocidad exacta que necesitas; calibración con un clic.
- 📱 **Control remoto desde el teléfono (opcional)** — servidor local con QR y tres pestañas. **Teleprompter**: iniciar, traer al frente, play/pausa, velocidad, saltos, micrófono con estado en vivo, modo minimalista, transparencia, minimizar y encuadrar. **Ordenador**: flechas, avance y retroceso de página, clics, trackpad virtual y teclado — pasa diapositivas en Keynote, PowerPoint, Vista Previa, un PDF o el navegador, porque envía teclas reales del sistema. **Guion**: el discurso completo en el teléfono con el mismo karaoke del Mac (ver siguiente punto). Protegido con un código aleatorio de 128 bits comparado en tiempo constante, solo en tu red; el control del ordenador exige un permiso aparte y renovar el código expulsa al instante cualquier dispositivo conectado.
- 📲 **Espejo del guion en el teléfono** — pestaña «Guion» del remoto: el texto completo con la palabra actual resaltada y centrada, sincronizada palabra a palabra con el Mac por un canal en vivo (el móvil no pregunta: la posición le llega sola, incluida la cuenta regresiva 3-2-1 y el estado de grabación). Tamaño de letra ajustable, **modo espejo** para ponerlo frente a una cámara réflex, transporte y botón de grabar sin cambiar de pestaña. Si editas el guion en el Mac, el teléfono lo recarga solo.
- 🎞️ **Editor de composición por tramos (opcional, apagado por defecto)** — junta cámara y pantalla en un vídeo publicable **sin salir de la app**: del segundo A al B la cara en círculo abajo a la derecha, del B al C arriba a la izquierda, después lado a lado 30/70. Corta con la tecla `S` (o un tramo por capítulo del guion, automático), ajusta el reparto del lado a lado, recorta cada fuente a mano o déjala llenar su ventana, y elige fondo de color, degradado o imagen (mosaico, expandida, adaptada…). Además, **N capas tuyas** (vídeos e imágenes con orden, geometría, opacidad y tiempos de aparición propios), **fuentes propias** (tu vídeo en lugar del escritorio o de la webcam) y **selector de proyectos** para retomar cualquier grabación o montar un proyecto desde vídeos sueltos. Presets 1–6, proyecto guardado junto a los vídeos, y exportación MP4 donde lo que ves es exactamente lo que sale.
- 🎥 **Grabación de presentaciones (opcional, apagada por defecto)** — graba la **cámara** (con tu micrófono) y la **pantalla** como **dos archivos separados que arrancan sincronizados** (desfase medido: menos de 50 ms), listos para montar en cualquier editor. El teleprompter **jamás aparece** en la grabación de pantalla: la captura excluye la ventana igual que el compartir pantalla. Cuenta regresiva configurable, elección de cámara, **capítulos automáticos** al cruzar cada guía (queda un `capitulos.txt` con los tiempos) y un `sync.txt` con la hora exacta del primer fotograma de cada archivo. Los vídeos quedan en `Películas/BtoPrompter` (o la carpeta que elijas), accesibles sin abrir la app. Botón en la barra del prompter y en el teléfono. La pantalla requiere macOS 15+; la cámara funciona en cualquier versión.
- 📄 **Exportar a PDF** — el guion marcado (guías, velocidades, pausas) listo para imprimir como respaldo.
- 🔄 **Auto-actualización** — el aviso de versión nueva descarga, valida e instala solo (desactivable).
- 🗄️ **Organización**: arrastra discursos a carpetas (o usa el menú contextual), colapsa carpetas, marca borradores, archiva.

### Atajos de teclado

| Tecla | Acción |
|-------|--------|
| `␣` espacio | Play / pausa |
| `←` `→` | Saltar ±10 palabras |
| `⇧←` `⇧→` | Saltar ±1 palabra (fino) |
| `↑` `↓` | Velocidad ±10 ppm |
| `+` `−` | Tamaño de letra |
| `[` `]` | Transparencia del fondo |
| `R` | Reiniciar |
| `M` | Modo minimalista (barra de 2 líneas arriba) |
| `Esc` | Volver al editor |

**Atajos globales** (funcionan desde cualquier app mientras el prompter está activo):

| Tecla | Acción |
|-------|--------|
| `⌥⌘P` | Play / pausa |
| `⌥⌘↑` `⌥⌘↓` | Velocidad ±10 ppm |

## Tecnología

- **Swift** (AppKit + SwiftUI), cero dependencias externas, arquitectura por capas.
- Tokenización de oraciones con **NaturalLanguage** (`NLTokenizer`).
- Se compila con `swiftc` directo — no requiere proyecto de Xcode.
- Requiere macOS 13 o superior (Apple Silicon o Intel). El nuevo Apple Speech local en vivo requiere macOS 26; en versiones anteriores se puede elegir otro proveedor compatible.

## Instalación

```bash
git clone https://github.com/btoaldas/BtoPrompter.git
cd BtoPrompter
./build.sh
open dist/BtoPrompter.app
```

`build.sh` compila con `swiftc -O` y firma la app. Si quieres moverla, copia `dist/BtoPrompter.app` a `/Applications`.

**Permisos que sobreviven a las actualizaciones.** Con firma ad-hoc, macOS ata los permisos (micrófono, Accesibilidad) al hash exacto del binario, así que cada recompilación los invalida aunque sigan marcados en Ajustes. Para evitarlo, crea una vez un certificado local de firma llamado `BtoPrompter Local Signing` en tu llavero: `build.sh` lo detecta solo y lo usa, y entonces el permiso se concede una sola vez. Sin certificado se firma ad-hoc, como antes. Puedes indicar otro nombre con `BTOPROMPTER_SIGN_ID`.

## Uso

1. Pega tu discurso (botón **Pegar** o ⌘V).
2. Ajusta la velocidad (ppm = palabras por minuto).
3. **Iniciar** → entra al prompter en pausa; espacio para arrancar.
4. Ajusta transparencia con `[` `]` para ver tu presentación detrás del texto.

### Ensayo con IA

En el editor, botón **IA…** → activa el interruptor, elige proveedor (Groq, OpenAI, OpenRouter o URL personalizada), pega **tu propia API key**, elige el estilo y pulsa **Preparar discurso**. Las marcas que genera son las mismas que puedes escribir a mano:

- `palabra…` — pausa de respiración (el prompter espera más).
- `// texto` — guía visible no leída (azul).
- `[v+20]` / `[v-30]` / `[v=]` al inicio de línea — sube/baja la velocidad de ese tramo, o vuelve a la normal.

La key se guarda en un archivo local con permisos privados (`0600`); nunca se incluye en logs ni en el repositorio. El texto solo se envía al proveedor que tú configures cuando ejecutas esta función.

### Voz, privacidad y modelos

- **Apple local** usa el dictado progresivo de macOS 26 y su modelo de idioma administrado por el sistema. En Configuración → Voz puedes comprobarlo, descargarlo, pausar y continuar.
- Los proveedores externos están bloqueados hasta que actives **“Autorizo enviar mi voz…”** y agregues tu propia API key.
- El failover omite proveedores sin permiso o sin key y continúa con el siguiente respaldo disponible.
- Las grabaciones de diagnóstico son opcionales, locales y visibles mediante Configuración → Diagnóstico; pueden borrarse desde allí.
- La transcripción de archivos de audio sigue disponible al importar `.m4a`, `.mp3`, `.wav`, `.aac`, `.aiff`, `.caf` o `.flac`.

### Editor de composición (por tramos de tiempo)

En Configuración → Grabación activa **«Editor de composición»**. Al terminar una grabación (basta una sola pieza: cámara o pantalla), el editor se abre solo con la composición lista; también vive en el menú (**Componer grabación…**, ⌘E) para retomar cualquier grabación anterior, y con `--editor` se abre directo al arrancar.

El vídeo se divide en **tramos de tiempo** y cada tramo tiene su propia receta:

- **Cortar aquí** (tecla `S`): parte el tramo bajo el cursor. **Fusionar tramo** lo une con el anterior — nunca quedan huecos, por construcción. **Un tramo por capítulo** genera todos los cortes desde las guías del guion (`capitulos.txt`).
- **Modos por tramo**: cámara sobre pantalla (círculo/redondeada/rectángulo con borde, 9 posiciones rápidas + tamaño y posición finos), **lado a lado con reparto ajustable** (20/80 a 80/20), solo pantalla o solo cámara.
- **Ajuste por fuente**: llenar (recorta sobrante), encajar entera, o **recorte manual** — eliges exactamente qué parte del fotograma original se usa (desde la izquierda/arriba, ancho, alto).
- **Fondo del vídeo**: color fijo, degradado de dos colores, o **imagen** (expandida, adaptada, estirada, mosaico o centrada).
- **Presets** con teclas 1–6 que aplican una receta completa al tramo seleccionado.

- ⌨️ **Teclas en pantalla** (opcional, apagado por defecto): muestra «⌘S» abajo cuando pulsas un atajo, lo clásico de los tutoriales. Esquina, duración y tamaño ajustables. **Por privacidad solo se registran ATAJOS** (con ⌘, ⌥ o ⌃) y teclas que no escriben (Esc, flechas, Intro): el texto que tecleas **nunca** se guarda, porque podría ser una contraseña.
- 🤫 **Marcar los silencios**: la app sabe en qué segundo dijiste cada palabra, así que encuentra los huecos donde nadie habló y **pone un corte en cada uno** para que los revises y los quites — la mitad del trabajo de editar un tutorial.
- 🖱️ **Cursor resaltado**: un halo suave que sigue al puntero en la grabación de pantalla — lo que separa un tutorial que se entiende de uno donde nadie encuentra el ratón. El recorrido se registra al grabar (20 veces por segundo, unos pocos KB) y en el editor se enciende, se le da tamaño, anillo y color. El halo se desliza entre muestras, sin saltos.
- 🔍 **Zoom por tramo dibujándolo**: pulsa la lupa y **encuadra sobre el vídeo** la zona a la que acercarte en ese corte; el acercamiento entra con una rampa suave en vez de un salto, y otro botón vuelve al 100 %. Solo afecta a ese tramo: al siguiente corte vuelves al plano general.
- 🔇 **Limpiar el sonido del sistema del micrófono** (opcional, después de grabar): si mientras hablabas sonaba algo en el Mac, el micrófono lo captó. La app tiene ese sonido también en **digital** (grabado con la pantalla, sin pasar por el aire) y lo usa como referencia exacta para restarlo. **Es una prueba, no un camino sin vuelta**: la voz limpia se guarda como archivo aparte, **tu grabación original nunca se toca**, y un botón devuelve el micrófono de siempre. Puedes hacer varios intentos y comparar. **Medido: 11 dB menos** de sonido del sistema, y cuando no hay nada que quitar la voz sale intacta. No llega a lo que consigue una llamada en vivo — los relojes de la cámara y de la pantalla van cada uno por su lado —, así que para separación total siguen ganando los auriculares.
- **Anotaciones de curso**: barra de herramientas sobre la previsualización con **flecha, recuadro, elipse, subrayado, texto, tachado, pixelado, nota adhesiva y lápiz libre**. La nota es un papelito de color con tu texto; el lápiz guarda el trazo completo y se mueve y escala con la capa. Eliges la herramienta, arrastras sobre el vídeo y queda como una capa más — con sus tiempos de aparición, su orden y su arrastre. El **pixelado tapa datos sensibles** (contraseñas, nombres, correos) difuminando o cuadriculando esa zona del vídeo real.
- **Orden de capas por tramo**: en un corte la capa A encima y en el siguiente al revés — clic derecho sobre el componente: traer al frente/adelante/atrás/al fondo o «Posición…» 1..N, solo en ese tramo o en todo el vídeo.
- **Transiciones**: cada tramo puede entrar con fundido desde el anterior (o corte seco, el valor por defecto), 100–2000 ms.
- **Audio desacoplado por fuente**: el escritorio y la webcam traen cada uno imagen Y sonido, y los combinas libres — la vista del escritorio con solo el audio de la webcam, o al revés (volúmenes independientes de micrófono y sistema). Además **audios tuyos** (música de fondo, efectos) con volumen, recorte del archivo (usar del minuto 1 al 3 de un MP3) y posición exacta, y **voz en off grabable desde el editor**: pulsa el botón, narra, y la toma entra como capa de audio donde estaba el cursor — N tomas, todas ajustables.
- 🎬 **Modo Estudio** (menú «Estudio…», ⌘0): grabar **sin teleprompter**, para tutoriales, clases y demos donde no hay guion que leer. Ventana propia con **la cámara en vivo** para encuadrarte, los interruptores de qué grabar a mano (cámara, pantalla, micrófono, sonido del sistema), los segundos de preparación y un botón grande de grabar/pausar/parar con el cronómetro. Usa el mismo motor y la misma carpeta que todo lo demás; solo cambia por dónde entras. Tampoco aparece en la grabación.
- 🎛️ **Mando flotante de grabación** — un panel pequeño que flota sobre todo, **se arrastra a donde quieras** y recuerda su sitio: grabar, pausar y parar con un clic, con el cronómetro a la vista. **No aparece en las grabaciones ni en las capturas**, igual que el teleprompter: es un control de quien graba, no contenido. Atajos ⌘R (grabar/parar) y ⌘⇧R (pausar/reanudar).
- 🔇 **Cancelación del eco del sistema** (opcional): si mientras hablas suena algo en el Mac, el micrófono lo capta por los altavoces y queda duplicado. Con esta opción el micrófono se graba aparte y limpio con la tecnología de voz de macOS — la misma que usan Zoom y Teams. **Medido: 38 dB menos** de audio del sistema en el micrófono (−26,5 dB → −64,6 dB).
- ⏱️ **Cuenta regresiva a pantalla completa**: el 3, 2, 1 grande antes de grabar, con teleprompter o sin él, y los segundos se eligen **en el propio mando** (0, 3, 5, 10 o 15) sin abrir Ajustes. No aparece en la grabación.
- **Sonido del sistema y copias solo-audio** (Ajustes → Grabación, apagados por defecto): graba también lo que suena en el Mac (va en el archivo de pantalla) y extrae copias sueltas `audio-webcam.m4a` / `audio-sistema.m4a` para usarlas donde quieras sin abrir el editor.
- **Cortes arrastrables**: los marcadores de la línea de tiempo se agarran y se mueven, con imán a segundos enteros.
- **Subtítulos** (activables por proyecto): generados **del propio teleprompter** — la app sabe qué palabra dijiste en qué segundo y arma las frases sola — o importados de un archivo SRT. Cinco modelos de estilo (Clásico TV, Formal, Juvenil, Invertido, Minimal) y todo configurable: posición arriba/medio/abajo, una o dos filas, ancho, tamaño, color, sombra y caja de fondo. **Por defecto NO se queman**: al exportar salen como `video.srt` separado junto al MP4, listo para subirlo a YouTube como pista (quemarlos es la opción, en la propia interfaz).
- **Subtítulos SIN teleprompter**: pulsa «Transcribir el audio» y la app escucha tu grabación y arma las frases con el instante real de cada palabra — para tutoriales y clases hablando libre, sin guion. De ahí encadenan las traducciones y el doblaje.
- **Traducciones con IA a los 10 idiomas más hablados** (español, inglés, chino, hindi, francés, árabe, bengalí, portugués, ruso, japonés): un clic y salen `video.en.srt`, `video.ja.srt`… con los tiempos reales intactos, usando el proveedor de IA que tú configures. Y **«Refinar con IA»**: puntuación, mayúsculas y cortes naturales sin tocar los tiempos.
- **Doblaje con IA**: traduce tus frases y las sintetiza una a una con el proveedor de voz configurado (ElevenLabs, OpenAI…), cada frase alineada a su segundo real como capa de audio editable; el micrófono original se baja a cero y tú decides si lo devuelves. Avisa del costo (una llamada por frase) antes de lanzar.
- **Presets estilo OBS en cuatro niveles**: guarda y aplica **características** (solo la apariencia de una capa), **componentes** (la capa completa), **escenas** (el tramo con sus capas) y **plantillas de proyecto entero**. Las plantillas nunca arrastran tus archivos: las capas quedan como «demo 1, demo 2…» y al aplicarlas eliges qué archivo va en cada hueco.
- **Voz en off grabable**: pulsa, narra y la toma entra como capa de audio donde estaba el cursor — N tomas, cada una con su volumen, recorte y posición.
- **N capas tuyas**: añade los vídeos e imágenes que quieras encima del montaje. Cada capa tiene su posición, su tamaño (escalado o **deformado**), su recorte, su forma, su opacidad, su orden (cuál va delante de cuál, incluso detrás de la cámara flotante) y **sus tiempos**: aparece y desaparece en los segundos que tú decidas, las veces que quieras.
- **Fuentes propias**: sustituye la pantalla o la cámara grabadas por un vídeo tuyo (o aporta la que falte).
- **Selector de proyectos**: abre cualquier grabación o proyecto anterior, no solo el último. Y **«Nuevo desde vídeos…»** monta un proyecto desde vídeos sueltos sin grabar nada (el primero es la base, el resto entran como capas; no se copian, se referencian).

El proyecto se guarda en `project.json` junto a los `.mov`: cierra y retoma cuando quieras; los originales nunca se tocan. La previsualización usa **el mismo motor de dibujo** que la exportación (Core Image, sin CALayer): lo que ves es exactamente lo que sale. Prueba reproducible sin interfaz: `--test-compose <carpeta> <salida.mp4> [preset]` (usa el `project.json` de la carpeta si existe).

> El editor es una ventana normal: **sí** aparece al compartir pantalla. La invisibilidad es del teleprompter.

### Grabación de presentaciones

En Configuración → Grabación: activa la función, elige qué grabar (cámara, pantalla o ambas) y desde dónde (botón en la barra del prompter, **menú «Grabar / Detener grabación» ⌘R para grabar sin teleprompter**, o el botón «Grabar» del teléfono). Al empezar a grabar el teleprompter arranca solo, si lo estabas usando. Cada grabación crea una carpeta con fecha y hora en `Películas/BtoPrompter`:

```
2026-08-01-160809/
├── camara-2026-08-01-160809.mov     ← tú, con el audio del micrófono
├── pantalla-2026-08-01-160809.mov   ← tu pantalla, SIN el teleprompter
├── sync.txt / sync.json             ← hora exacta del primer fotograma de cada archivo
├── capitulos.txt                    ← una marca de tiempo por cada guía cruzada
└── project.json                     ← tu proyecto del editor de composición (si lo usaste)
```

Los dos vídeos arrancan a la vez (el motor prepara el hardware primero y solo escribe cuando la cámara ya entrega imagen), así que en el editor basta ponerlos en paralelo. La primera vez, macOS pedirá permiso de cámara y de grabación de pantalla.

### Notas sobre la invisibilidad

- Funciona con todo software que capture pantalla mediante las APIs de macOS (Zoom, Teams, Meet, OBS, QuickTime…), **incluida la propia grabación de pantalla de la app**.
- **No** sobrevive a capturadoras de hardware (HDMI) ni AirPlay.
- Si compartes pantalla completa con la app enfocada, la barra de menú de macOS muestra el nombre de la app; compartir solo la ventana de tu presentación lo evita.
- Haz siempre una grabación de prueba de 30 segundos antes del evento real.

Flags de desarrollo: `--capturable` (arranca visible en capturas, útil para probar), `--autostart` (entra directo al prompter reproduciendo) y `--test-sharing` (comprobación automática de la invisibilidad: crea una ventana excluida y una de control, captura la pantalla y verifica que la primera no aparece y la segunda sí).

## Privacidad

- Todo funciona en tu Mac por defecto: seguimiento con Apple local, lectura con voces del sistema o locales, diagnóstico y perfil del orador.
- **Nada sale del equipo sin que lo autorices**, y la autorización es **por proveedor**, no un interruptor general.
- Las API keys se guardan en un archivo propio con permisos `0600`, nunca en las preferencias ni en los registros.
- Las grabaciones y transcripciones son locales, con límites de días y de espacio, y se pueden borrar desde la app.

## Contribuir

¡Este proyecto es abierto y las mejoras son bienvenidas! Ideas, issues y pull requests: adelante. Algunas líneas en las que se puede aportar:

- Espejado horizontal para teleprompters físicos con espejo
- Localización a otros idiomas
- Motor Whisper/NeMo completamente local y empaquetado
- Voces TTS externas y clonadas con consentimiento explícito
- Avatar autorizado con cámara/micrófono virtual como módulo independiente
- Marcadores y notas de tiempo dentro del discurso

## Licencia

[MIT](LICENSE) — úsalo, modifícalo y compártelo libremente.
