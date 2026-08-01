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
- ⚙️ **Configuración central** (engranaje o `⌘,`): General, Voz, Diagnóstico, Ensayo IA, Remoto y actualizaciones.
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
- 📱 **Control remoto desde el teléfono (opcional)** — servidor local con QR para escanear y dos pestañas: **Teleprompter** (play/pausa, velocidad, saltos) y **Ordenador** (flechas, avance y retroceso de página, clics, trackpad virtual y teclado). Sirve para pasar diapositivas en Keynote, PowerPoint, Vista Previa, un PDF o el navegador, porque envía teclas reales del sistema. Protegido con token, solo en tu red, y el control del ordenador exige un permiso aparte.
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

- **Swift** (AppKit + SwiftUI), cero dependencias externas, arquitectura por capas (ver [ARCHITECTURE.md](ARCHITECTURE.md)).
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

`build.sh` compila con `swiftc -O` y firma ad-hoc. Si quieres moverla, copia `dist/BtoPrompter.app` a `/Applications`.

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

### Notas sobre la invisibilidad

- Funciona con todo software que capture pantalla mediante las APIs de macOS (Zoom, Teams, Meet, OBS, QuickTime…).
- **No** sobrevive a capturadoras de hardware (HDMI) ni AirPlay.
- Si compartes pantalla completa con la app enfocada, la barra de menú de macOS muestra el nombre de la app; compartir solo la ventana de tu presentación lo evita.
- Haz siempre una grabación de prueba de 30 segundos antes del evento real.

Flags de desarrollo: `--capturable` (arranca visible en capturas, útil para probar) y `--autostart` (entra directo al prompter reproduciendo).

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
