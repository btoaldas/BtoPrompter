# Editor de composición — Fase 4 (pedido de Alberto, 2026-08-01)

*Pedido dictado por Alberto al cierre de la fase 3 (v0.0.6). Documentado ANTES de
implementar para sobrevivir cortes de sesión. Lo ya entregado está en el README;
esto es SOLO lo que falta.*

---

## 1. Orden de capas POR TRAMO (z-order por corte)

Hoy el orden de las capas es GLOBAL (el array `extraLayers` del proyecto). Alberto
quiere que **cada tramo tenga su propio orden**: en el corte 1 la capa A arriba y
la B abajo; en el corte 2 al revés; con 10 capas, poder mandar una a la posición
3, 4, 5…

**Diseño propuesto:**
- `SegmentLayout` gana `var layerOrder: [UUID]?` — el orden de dibujo de las capas
  en ESE tramo. `nil` = usar el orden global del array (retrocompatible).
- El compositor, al dibujar un instante, ordena `extraLayers` según el
  `layerOrder` del tramo vigente (las capas que no estén en la lista van al final
  en orden global).
- Menú contextual del lienzo vivo (clic derecho sobre el componente) COMPLETO:
  - Traer al frente (top) / Enviar al fondo (bottom)
  - Traer adelante (+1) / Enviar atrás (−1)
  - Submenú **"Posición…"** → 1..N (N = número de capas)
  - Y aclarar en el menú si el cambio es "solo en este tramo" o "en todo el
    vídeo" (dos secciones del menú, o modificador Alt).
- El panel de capas muestra el orden DEL TRAMO seleccionado cuando exista
  layerOrder, con un botón "usar este orden en todo el vídeo".

## 2. Subtítulos (activables/desactivables)

Dos fuentes de subtítulos:
1. **Archivo subido** (SRT/VTT): parsear → lista {from, to, texto}.
2. **Del teleprompter**: la app YA SABE qué palabra se dijo en qué segundo
   — `VoiceDiagnostics` escribe `words.jsonl` con {i, w, t_session} cuando el
   diagnóstico está activo, y el karaoke avanza palabra a palabra incluso por
   tiempo. Falta: que el GRABADOR escriba SIEMPRE una pista ligera
   palabra↔segundo durante la grabación (subtitulos.jsonl en la carpeta de la
   grabación, pocas KB, sin audio) aunque el diagnóstico esté apagado.
   El "ScriptTrack" del plan de la fase 2 es esto mismo; Alberto ahora lo
   validó vía subtítulos.

**Diseño propuesto:**
- Nueva pieza del proyecto: `var subtitles: SubtitleTrack?` con
  `{enabled, source (.file(path)|.prompter), style (tamaño, color, fondo,
  posición), chunks: [{from, to, text}]}`.
- Se QUEMAN en el vídeo con Core Image (el compositor ya dibuja por instante;
  un texto más es un caso nuevo en FrameComposer). CTLine/CoreText → CGImage
  cacheado por texto (igual que las máscaras).
- Agrupar palabras en frases de N palabras o por oración del guion (el parser ya
  separa oraciones) — configurable.
- Toggle en el inspector; estilo parametrizable.
- El grabador escribe `subtitulos.jsonl` en cada grabación (palabra + segundo
  relativo al inicio real de la grabación = firstFrameTimes["camara"]).

## 3. Capas de AUDIO

Hoy: el audio del montaje es SOLO el de la cámara. Alberto quiere:
- Volumen por fuente: audio de cámara (micrófono), audio de pantalla (si algún
  día se captura), y **audios subidos** (música de fondo bajita, efectos).
- Cada audio subido con: volumen, **recorte del archivo** (usar del minuto 1 al
  3 de un MP3 de 3 minutos) y **posición en el proyecto** (que suene del segundo
  A al B del montaje).

**Diseño propuesto:**
- `var audioLayers: [AudioLayer]` con `{id, path, name, volume (0..1),
  sourceStart (segundo del archivo donde empieza), projectStart, duration}`.
- `CompositionBuilder`: una pista de audio más por AudioLayer
  (insertTimeRange(sourceStart..., at: projectStart)) + `AVMutableAudioMix` con
  volumen por pista (y el volumen de la cámara también expuesto).
- UI: sección "Audio" en el inspector: fila por audio con volumen, desde/hasta
  del archivo, desde del proyecto; + botón añadir. El volumen de "Micrófono
  (cámara)" siempre visible.
- La exportación hereda el audioMix (AVAssetExportSession.audioMix).

## 4. Presets estilo OBS (plantillas en 3 niveles)

Modelo mental de Alberto = OBS: escenas → componentes → configuraciones.

- **Preset de COMPONENTE (capa)**: geometría + forma + ajuste + opacidad con
  nombre. Aplicable a cualquier capa.
- **Preset de ESCENA (tramo)**: el `SegmentLayout` completo + las capas que
  participan con sus posiciones.
- **Preset de PROYECTO (plantilla)**: N cortes con sus escenas y componentes.
  **Fuentes placeholder**: si la plantilla usa archivos que no existen en el
  proyecto destino, se guardan como "demo 1", "demo 2"… y al aplicar la
  plantilla el usuario elige qué poner en cada hueco (webcam, escritorio, un
  archivo, nada). Diálogo de mapeo al aplicar.
- Guardado con el patrón de `CustomStylesStore` (JSON en Application Support),
  p. ej. `video-presets.json`. Los de fábrica (los 6 actuales) se mantienen.
- UI: menú "Guardar como preset…" (capa/tramo/proyecto según contexto) +
  selector al aplicar.

## 5. Transiciones entre tramos

Fundido o deslizamiento alrededor del corte, SIN romper la metodología de
tramos (pedido explícito: nada de que el corte deje de ser corte).

**Diseño propuesto:**
- `SegmentLayout` gana `var transitionIn: Transition` (`.cut | .fade(ms) |
  .slide(ms)`), aplicada a la ENTRADA del tramo.
- El compositor ya resuelve por instante: si `t` está a menos de `ms` del corte
  de entrada, dibuja AMBOS layouts (el saliente y el entrante) y mezcla
  (dissolve con CIDissolveTransition, o interpola camRect/splitRatio para
  movimiento suave). Una sola instrucción sigue cubriendo todo — cero cambio
  estructural.
- UI: picker de transición en el inspector del tramo.

## 6. Arrastrar los cortes en la línea de tiempo

- Los marcadores naranjas de la regla se agarran y arrastran
  (`VideoProject.moveCut` ya existe con clamp anti-invasión de vecinos).
- Imán a segundos enteros y a capítulos del guion (si existen).
- El bloque del tramo muestra el tiempo mientras se arrastra.

## 7. Descartado por Alberto (no lo quiere / no lo entendió — NO hacer)

- Buscar una frase del guion y saltar a su segundo en el editor.
- Capítulos incrustados en el archivo MP4.
(Ambos anotados por si algún día los pide con otras palabras.)

## Orden de implementación sugerido (cada pieza = commit + verificación)

1. Z-order por tramo + menú contextual completo (posiciones). ← lo más pedido
2. Arrastrar cortes en la timeline (barato, muy visible).
3. Transiciones (fade primero; slide después).
4. Capas de audio (pistas + audioMix + UI).
5. Subtítulos (grabador escribe subtitulos.jsonl + capa quemada + SRT).
6. Presets OBS (componente → escena → plantilla con placeholders).

## Reglas que siguen vigentes

- Todo parametrizable y apagado por defecto si toca permisos/red/grabación.
- El teleprompter JAMÁS aparece en grabaciones ni capturas.
- Revisión (código+seguridad) antes de cada release; release solo bajo pedido.
- project.json de versiones anteriores carga intacto (init tolerante).
