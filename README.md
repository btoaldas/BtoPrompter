# BtoPrompter

**ES** — Teleprompter flotante para macOS, invisible al compartir pantalla.
**EN** — Floating teleprompter for macOS, invisible to screen sharing (Zoom, Teams, Meet). Word-by-word karaoke highlighting, adjustable speed and transparency. Single-file Swift app, no dependencies.

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
- 🪟 **Transparencia 0–100 %** — al 0 % desaparece el fondo y solo quedan las letras flotando sobre tu presentación o tu audiencia.
- 🎈 **No roba el foco** — es un panel no-activante: flota incluso sobre apps en pantalla completa y puedes hacer clic sin quitarle el teclado a tu presentación.
- 🔠 **Tamaño de letra ajustable** en vivo.
- 🖱️ **Clic en cualquier oración** para saltar directamente ahí.

### Atajos de teclado

| Tecla | Acción |
|-------|--------|
| `␣` espacio | Play / pausa |
| `←` `→` | Saltar ±10 palabras |
| `↑` `↓` | Velocidad ±10 ppm |
| `+` `−` | Tamaño de letra |
| `[` `]` | Transparencia del fondo |
| `R` | Reiniciar |
| `Esc` | Volver al editor |

**Atajos globales** (funcionan desde cualquier app mientras el prompter está activo):

| Tecla | Acción |
|-------|--------|
| `⌥⌘P` | Play / pausa |
| `⌥⌘↑` `⌥⌘↓` | Velocidad ±10 ppm |

## Tecnología

- **Swift** (AppKit + SwiftUI), un solo archivo fuente, cero dependencias externas.
- Tokenización de oraciones con **NaturalLanguage** (`NLTokenizer`).
- Se compila con `swiftc` directo — no requiere proyecto de Xcode.
- Requiere macOS 13 o superior (Apple Silicon o Intel).

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

### Notas sobre la invisibilidad

- Funciona con todo software que capture pantalla mediante las APIs de macOS (Zoom, Teams, Meet, OBS, QuickTime…).
- **No** sobrevive a capturadoras de hardware (HDMI) ni AirPlay.
- Si compartes pantalla completa con la app enfocada, la barra de menú de macOS muestra el nombre de la app; compartir solo la ventana de tu presentación lo evita.
- Haz siempre una grabación de prueba de 30 segundos antes del evento real.

Flags de desarrollo: `--capturable` (arranca visible en capturas, útil para probar) y `--autostart` (entra directo al prompter reproduciendo).

## Contribuir

¡Este proyecto es abierto y las mejoras son bienvenidas! Ideas, issues y pull requests: adelante. Algunas líneas en las que se puede aportar:

- Espejado horizontal para teleprompters físicos con espejo
- Localización a otros idiomas
- Control remoto desde el teléfono
- Marcadores y notas de tiempo dentro del discurso

## Licencia

[MIT](LICENSE) — úsalo, modifícalo y compártelo libremente.
