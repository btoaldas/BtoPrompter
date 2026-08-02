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

### 2b. AMPLIACIÓN dictada (cuarta tanda): estilos completos + refinado con IA

- **Estilos configurables TODOS**: posición (arriba/medio/abajo), una o dos
  filas, ancho completo o 50–100 %, texto blanco con sombra negra, negro con
  sombra blanca, con caja de fondo u sin ella, tamaño. Y **modelos con
  nombre** (presets de estilo): Clásico TV, Formal, Juvenil, Invertido,
  Minimal… El usuario elige un modelo y ajusta encima.
- **NO karaoke** (el propio Alberto lo descartó: confuso). Solo frases.
- **Refinado con IA**: botón que manda las palabras+tiempos (y el guion) al
  proveedor de IA ya configurado en la app (Groq/OpenAI/…, misma
  infraestructura del Ensayo IA) para que devuelva frases bien puntuadas,
  con mayúsculas correctas y cortes naturales, respetando los tiempos
  medidos. El análisis del AUDIO ya lo cubren los proveedores STT de la app
  si hiciera falta re-transcribir; la v1 refina sobre palabra↔segundo que ya
  es real.

## 3. Capas de AUDIO — ✅ base HECHA (commit 3a3c856) + AMPLIACIÓN dictada

HECHO: `audioLayers` (volumen, recorte del archivo con sourceStart, posición
con projectStart, duración), `micVolume`, AVMutableAudioMix en preview y
export, sección Audio en el inspector. Verificado con tono medido a −31 dB.

### 3b. AMPLIACIÓN (dictado 2026-08-01, segunda tanda): audio y vídeo DESACOPLADOS por fuente

El modelo mental correcto: el escritorio trae IMAGEN + SONIDO; la webcam trae
IMAGEN + SONIDO. Son 4 canales lógicos y el usuario combina los que quiera:
- Caso clave dictado: "solo la VISTA del escritorio con solo el SONIDO de la
  webcam, sin que se vea la webcam" — y el inverso.
- Decisión de diseño: NO partir en 4 capas visibles (ruido); las fuentes se
  quedan como están y el DESACOPLE es de mezcla: la imagen la decide el modo
  del tramo (solo pantalla / solo cámara / overlay / lado a lado) y el sonido
  lo deciden los volúmenes independientes: `micVolume` (webcam, hecho) +
  `screenAudioVolume` (NUEVO).
- Requisito previo: hoy la grabación de pantalla NO captura audio
  (`capturesAudio = false`). Nueva opción parametrizable en Ajustes →
  Grabación: **"Sonido del sistema en la grabación de pantalla"** (OFF por
  defecto) → `SCStreamConfiguration.capturesAudio = true` → pantalla-*.mov
  con pista de audio. El builder añade esa pista con su volumen propio.
- AÑADIDO (tercera tanda dictada): **copias solo-audio opcionales** — el vídeo
  se guarda SIEMPRE con su audio embebido (mute = cosa de mezcla, no se pierde
  nada), y además, con la opción activada, al terminar la grabación se
  EXTRAEN copias aparte: `audio-webcam-<stamp>.m4a` (micrófono) y
  `audio-sistema-<stamp>.m4a` (sonido del Mac, si se capturó). Así el usuario
  tiene el audio suelto para usarlo donde quiera sin abrir el editor.

### 3c. VOZ EN OFF (dictado): N capas grabables desde el editor

- Botón "🎙 Grabar voz en off" en la sección Audio: graba del micrófono EN EL
  MOMENTO (AVAudioRecorder → `voz-off-<stamp>.m4a` en la carpeta del
  proyecto) y al parar se añade como AudioLayer con `projectStart` = donde
  estaba el cursor al empezar a grabar.
- N capas de voz en off, cada una posicionable en los segundos que quiera,
  con volumen y recorte como cualquier otro audio. Es ADICIONAL, nunca
  reemplazo del micrófono de la grabación original.
- Mientras graba: indicador rojo + cronómetro; opcional reproducir el vídeo
  en paralelo (para narrar viendo la imagen) — versión 1: solo grabar.
- Permiso de micrófono: el que la app ya tiene; la acción es explícita.
- La exportación hereda el audioMix (AVAssetExportSession.audioMix). HECHO.

### 2c. QUINTA TANDA dictada (2026-08-01, noche) — SOLO PLANIFICADO, NO ejecutar aún

**Subtítulos separados del vídeo (por defecto NO quemados):**
- La decisión es POR PROYECTO y EN LA INTERFAZ (no una configuración global):
  al exportar, el usuario elige — (a) quemar los subtítulos en el vídeo,
  (b) exportarlos como archivo .SRT SEPARADO junto al MP4 (para subirlo a
  YouTube como pista de subtítulos), o ambos. POR DEFECTO: separado, sin
  quemar.
- El editor ya sabe generar el SRT (chunks → formato SRT es trivial, el
  parser inverso ya existe).

**Traducciones con IA (los 10 idiomas más hablados):**
- Botón "Traducir subtítulos…": con la IA configurada en la app (misma
  infraestructura del Ensayo IA) se genera un SRT POR IDIOMA: español,
  inglés, chino mandarín, hindi, francés, árabe, bengalí, portugués, ruso,
  japonés (lista de 10, ajustable). Exporta video.mp4 + video.es.srt +
  video.en.srt + … listos para YouTube.
- Los tiempos NO se tocan (ya son reales); la IA solo traduce el texto de
  cada chunk manteniendo el número de bloques.

**Doblaje del audio con IA (idea grande, EN COLA, no empezar sin OK):**
- Cambiar la voz del orador a otro idioma con ElevenLabs (la app ya tiene la
  infraestructura TTS de ElevenLabs para la lectura y wa-voice): voz
  masculina o femenina a elegir, lo más humano posible.
- v1: UNA sola voz para todo el vídeo (multi-orador después).
- Pipeline: subtítulos con tiempos → traducción → TTS por frase → pista de
  audio nueva alineada a los tiempos (estirando/encogiendo si la frase
  doblada no cabe) → entra como AudioLayer sustituyendo al micrófono.
- Los 10 idiomas como opción (pesado: un TTS por frase por idioma — avisar
  del costo antes de lanzar).

## 4. Presets estilo OBS (plantillas en 4 niveles — afinado en la segunda tanda)

Modelo mental de Alberto = OBS: escenas → componentes → configuraciones.
CUATRO niveles (dictado): características de capa, componente, escena,
proyecto completo.

- **Preset de CARACTERÍSTICAS (estilo)**: solo la apariencia — forma, borde,
  opacidad, ajuste — SIN geometría. Aplicable a cualquier capa sin moverla.
- **Preset de COMPONENTE (capa)**: geometría + forma + ajuste + opacidad con
  nombre. Aplicable a cualquier capa.
- **Preset de ESCENA (tramo)**: el `SegmentLayout` completo + las capas que
  participan con sus posiciones (y su orden del tramo).
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

## Orden de implementación (cada pieza = commit + verificación)

1. ✅ Z-order por tramo + menú contextual completo (commit 357bab9)
2. ✅ Arrastrar cortes en la timeline (commit b25c092)
3. ✅ Transiciones fade (commit b25c092)
4. ✅ Capas de audio base (commit 3a3c856)
5. Sonido del sistema en la grabación de pantalla + screenAudioVolume (3b).
6. Voz en off grabable, N capas (3c).
7. ✅ Subtítulos: subtitulos.jsonl del grabador + agrupador de frases +
   parser SRT + dibujo Core Text cacheado + 5 modelos de estilo + UI completa
   (posición/filas/ancho/tamaño/color/sombra/caja). Verificado con fotogramas
   del MP4 exportado. PENDIENTE de la 4ª/5ª tanda: refinado con IA, SRT
   separado sin quemar (por defecto), traducciones 10 idiomas, doblaje
   ElevenLabs (ver 2b y 2c).
8. ✅ Presets OBS en 4 niveles: VideoPresetStore (video-presets.json) con
   características/componente/escena/plantilla, placeholders "demo N"
   verificados en selftest (jamás rutas reales), diálogo de mapeo al aplicar.
   Menús Guardar…/Aplicar… en el inspector.

## Reglas que siguen vigentes

- Todo parametrizable y apagado por defecto si toca permisos/red/grabación.
- El teleprompter JAMÁS aparece en grabaciones ni capturas.
- Revisión (código+seguridad) antes de cada release; release solo bajo pedido.
- project.json de versiones anteriores carga intacto (init tolerante).
