# Editor rápido de composición — BtoPrompter

*Diseño técnico. Base: dos verificaciones independientes con prototipos compilados y medidos en esta Mac (macOS 26.5, SDK 26.5, `swiftc -target arm64-apple-macos13.0`, igual que `build.sh`).*

---

## 1. Resumen honesto

### Lo que SÍ se puede lograr (verificado con vídeo real, no de memoria)

| Pedido de Alberto | Estado | Cómo |
|---|---|---|
| Webcam encima de la pantalla, posición y tamaño | **Verificado** | `AVMutableVideoCompositionLayerInstruction.setTransform(_:at:)` |
| Círculo, esquinas redondeadas, borde, sombra | **Verificado** | Compositor propio (`AVVideoCompositing`) con Core Image |
| Cambios por tramos de tiempo | **Verificado** | Una instrucción por tramo, con `timeRange` |
| Fondo de color a elección | **Verificado** | `CIImage(color:)` recortado al lienzo |
| Lado a lado (no solo superposición) | **Verificado** | `renderSize` independiente de las fuentes |
| Previsualizar sin exportar | **Verificado** | El **mismo** compositor en `AVPlayerItem.videoComposition` |
| Exportar listo para publicar | **Verificado** | `AVAssetExportSession.export(to:as:)` |
| Cero dependencias externas | **Sí** | AVFoundation + Core Image + AVKit son del sistema |

### Lo que NO se puede, y hay que decirlo

1. **Adornos con Core Animation (`CALayer`) están descartados.** macOS lanza una excepción ObjC **no capturable en Swift** que **mata la app** si esa composición se asigna a un `AVPlayerItem`: *"AVVideoCompositionCoreAnimationTool is for offline rendering only"*. Reproducido en vivo. Consecuencia: los adornos se dibujan con Core Image, no con capas.
2. **El desfase entre los dos ficheros NO se puede recuperar del archivo.** `AVAssetWriter` rebasa la sesión a cero: dos grabaciones con arranques reales de 0,00 s y 0,35 s reportan **ambas** `timeRange.start = 0.0000` y primer PTS = 0. **Esto no lo arregla el editor: lo tiene que resolver el grabador**, guardando el desfase en un *sidecar* JSON al grabar. Sin eso el editor nace roto.
3. **Passthrough no compone nada.** `AVAssetExportPresetPassthrough` ignora la `videoComposition` **en silencio** (exporta en 0,01 s copiando la pista). No se ofrece nunca en la interfaz.
4. **El editor SÍ se ve al compartir pantalla.** No hereda la invisibilidad del `PrompterPanel`; es una ventana normal que reproduce vídeo. Hay que decirlo en la interfaz, no es un fallo.
5. **No es Final Cut.** Sin multipista, sin transiciones, sin corrección de color, sin títulos, sin recorte de audio por regiones. Componer dos vídeos y exportar. Punto.

### Cuánto trabajo es

**MVP útil: 4–5 días.** **Editor completo con tramos: ~3 semanas** (6 fases entregables).
Total ~1.500–1.800 líneas Swift repartidas en 11 archivos nuevos. Cero archivos existentes reescritos; solo **3 adiciones puntuales** (una clave en `Settings.Key`, una fila en el menú, un `if` en `SettingsSheet`).

**Requisito duro previo, no negociable:** el *sidecar* de sincronía en el grabador (~50–80 líneas). Sin él no hay editor.

---

## 2. Arquitectura concreta

### Archivos nuevos

```
Sources/Storage/
├── VideoProjectStore.swift      Proyecto serializable → project.json (JSON atómico,
│                                mismo patrón que SpeechStore). Tramos, presets del
│                                usuario, rutas de los dos .mov, duración, desfase.
├── RecordingSidecar.swift       Lectura/escritura del sidecar de sincronía
│                                (desfase en segundos, relojes, fps, rutas, scriptTrack).
└── (Settings.swift)             +1 clave: videoEditorEnabled  [apagada por defecto]

Sources/Core/
├── CompositionGeometry.swift    LA PIEZA CRÍTICA. Único lugar donde viven los tres
│                                sistemas de coordenadas. Modelo normalizado 0..1
│                                origen arriba-izquierda (como CSS) → espacio de
│                                LayerInstruction (arriba-izquierda) → espacio Core
│                                Image (ABAJO-izquierda). Funciones puras, con pruebas
│                                en --selftest.
├── PiPCompositor.swift          El AVVideoCompositing propio. ~220 líneas. Máscara,
│                                aro y sombra pre-dibujados con CGContext y CACHEADOS
│                                por geometría; por fotograma solo 3 operaciones CI.
│                                Caja de parámetros compartida bajo NSLock (permite
│                                cambiar el dibujo SIN reasignar la composición).
├── FrameComposer.swift          La MISMA función de dibujo, versión congelada, para
│                                arrastre y para miniaturas del resultado.
│                                Un solo sitio donde tocar → WYSIWYG por construcción.
├── CompositionBuilder.swift     Modelo → AVMutableComposition + AVMutableVideoComposition
│                                + AVMutableAudioMix. Aquí y SOLO aquí vive la API
│                                obsoleta-en-26; el día que suba el piso se toca un
│                                archivo. Normaliza tramos y valida antes de devolver.
├── CompositionExporter.swift    Exportación con export(to:as:), progreso, comprobación
│                                de supportedFileTypes ANTES de asignar el contenedor.
└── ScriptTrack.swift            La idea diferenciadora: palabra ↔ segundo ↔ capítulo.
                                 Lee words.jsonl / el sidecar y produce capítulos,
                                 saltos por frase y cortes por sección.

Sources/UI/
├── VideoEditorWindow.swift      NSWindow propia + hosting SwiftUI. Se crea BAJO DEMANDA.
├── VideoEditorView.swift        Raíz del editor: previsualización + inspector + línea.
├── PreviewSurface.swift         NSViewRepresentable: NSView isFlipped=true + AVPlayerLayer.
│                                NO usar VideoPlayer (SwiftUI) ni AVPlayerView (AVKit):
│                                traen controles y gestos propios que estorban al arrastre.
│                                CATransaction.setDisableActions(true) o el recuadro
│                                "persigue" al ratón.
├── OverlayHandles.swift         Capa SwiftUI transparente: recuadro, 8 tiradores, imanes.
├── TimelineStrip.swift          Tramos, cursor, miniaturas, capítulos del guion.
└── PresetBar.swift              Fila de presets clicables + atajos 1–6.
```

### Cómo se integra sin tocar lo existente

- **`Storage/Settings.swift`**: una línea en el `enum Key` → `case videoEditorEnabled, videoExportPreset, videoPreviewScale`. Nada más.
- **`App/AppDelegate.swift`**: un ítem de menú *"Editar grabación…"*, **oculto** si `videoEditorEnabled == false`. La ventana se instancia en el `IBAction`, no antes.
- **`UI/SettingsSheet.swift`**: una sección nueva, colapsada, con el interruptor.
- **`App/SelfTest.swift`**: pruebas de `CompositionGeometry` (las conversiones de coordenadas) y de la normalización de tramos. Sin frameworks de vídeo, funciones puras.
- **`build.sh`**: **sin cambios**. `Sources/**/*.swift` ya los recoge; `import AVFoundation`/`CoreImage` los autoenlaza `swiftc`.
- **`BtoPrompter.entitlements`**: **sin cambios**. El editor solo lee ficheros que la propia app generó, y la app no está en *sandbox*. (Los *entitlements* de cámara y el TCC de grabación de pantalla son del **grabador**, no de esto.)
- **`PrompterPanel`**: intocado. `sharingType = .none` y el panel no-activante siguen exactamente igual.

**Reglas de dependencia (ARCHITECTURE.md) respetadas**: `UI` observa `Core`, `Core` usa `Storage`, `Storage` no conoce a nadie.

### Apagado significa apagado

Con `videoEditorEnabled == false`: sin ítem de menú, sin `AVPlayer` creado, sin `AVAssetImageGenerator`, sin `addPeriodicTimeObserver`, sin ventana, sin ficheros escritos, sin clase de compositor registrada. Comprobable: encender y apagar en caliente 5 veces y verificar que no queda ningún recurso abierto.

---

## 3. El modelo de tramos y los presets

### El modelo

```swift
struct VideoProject: Codable {            // → project.json
    var screenURL: URL, cameraURL: URL
    var offsetSeconds: Double             // del sidecar, EDITABLE en ms por si acaso
    var duration: Double                  // = la pista MÁS CORTA (ver regla dura abajo)
    var canvas: CGSize                    // 1920x1080 por defecto
    var background: RGBA
    var cuts: [Double]                    // SOLO los puntos de corte, en segundos
    var layouts: [Layout]                 // uno por tramo: cuts.count + 1 elementos
    var scriptTrack: ScriptTrack?         // palabra ↔ segundo (idea diferenciadora)
}

struct Layout: Codable, Equatable {       // un "tramo" es esto
    var mode: Mode                        // .overlay | .sideBySide | .onlyScreen | .onlyCamera
    var camRect: CGRect                   // NORMALIZADO 0..1, origen ARRIBA-IZQUIERDA
    var shape: Shape                      // .rect | .rounded(r) | .circle
    var border: Border?                   // color + grosor (% del lado menor)
    var shadow: Shadow?                   // radio + opacidad + desplazamiento
    var fit: Fit                          // .fill (recorta) | .fit (encaja)
    var transition: Transition            // .cut | .slide(ms) — rampa entre tramos
}
```

**Por qué se guardan solo los cortes y no los rangos**: es imposible crear un hueco. `CompositionBuilder` genera siempre instrucciones que **teselan** `[0, duration]` desde el array.

### La regla dura que revienta la exportación

Las instrucciones deben **cubrir toda la línea sin huecos ni solapes**. Está escrito en el header de Apple (`AVVideoComposition.h:103`): *"timeRange.start must be equal to the prior instruction's end time"*. Con un hueco, `isValid(...)` devuelve `false` y la exportación falla con **`AVError.invalidVideoComposition` (-11841)**.

Trampa asociada, ya diagnosticada: al alinear las dos grabaciones, las pistas quedan de distinta longitud (audio 10,00 s vs vídeo 9,65 s). La duración de la composición es el **máximo**, y sobra un hueco al final → error -11841. **Hay que recortar TODAS las pistas a la más corta.**

Red de seguridad, con doble rama por el piso macOS 13:
- macOS 15+: `isValid(for:assetDuration:timeRange:validationDelegate:)`
- macOS 13–14: `isValidForAsset:timeRange:validationDelegate:` (obsoleta pero presente)

### Qué se puede cambiar y cuándo

| Propiedad | ¿Por tramo? | Notas |
|---|---|---|
| Modo (superposición / lado a lado / solo uno) | Sí | |
| Posición y tamaño de la webcam | Sí | Con rampa opcional (`setTransformRamp`) para que se deslice |
| Forma, borde, sombra, márgenes | Sí | Coste ~0: la máscara se cachea por geometría |
| Fondo de color | Sí | |
| Volumen de cada fuente | Sí | Rampa medida: la pantalla cae 20 dB mientras el micro no se mueve |
| Lienzo (`renderSize`), preset de exportación, desfase | **Global** | No tiene sentido por tramo |

### Operaciones de la línea de tiempo (esto decide si se usa o se abandona)

1. **`S` = cortar aquí.** Parte el tramo bajo el cursor. Es el 90 % de los casos y elimina el diálogo de "desde/hasta".
2. **Se edita el tramo SELECCIONADO**, nunca escribiendo tiempos.
3. **Borrar un tramo = fusionarlo con el anterior.** Nunca deja hueco, por construcción.
4. **Arrastrar bordes con imán** a: cursor, bordes vecinos, segundos enteros y **límites de capítulo del guion**.
5. **Deshacer/rehacer** con `UndoManager` (ya hay `NSApplication`, sale gratis). Un arrastre completo = un solo undo.

### Presets rápidos

Un preset **es literalmente un `Layout` con nombre**. Es la funcionalidad más barata del proyecto y la que más se nota. Con `camRect` normalizado y márgenes en porcentaje, todos funcionan a cualquier resolución sin tocar nada.

| Tecla | Preset |
|---|---|
| `1` | Solo pantalla |
| `2` | Cara abajo-derecha, círculo pequeño |
| `3` | Cara arriba-izquierda, redondeada |
| `4` | Lado a lado (cámara izquierda, pantalla derecha, fondo azul) |
| `5` | Cara grande, pantalla pequeña (modo "explicación") |
| `6` | Solo cámara |

Los del usuario se guardan con el patrón que ya existe en `Storage/CustomStylesStore.swift`.

**Preset + un arrastre = resultado publicable en dos gestos.** Ese es el objetivo de agilidad.

---

## 4. La experiencia, contada como la vivirá Alberto

**0. Antes.** En Configuración enciende *"Editor de composición"*. Hasta ese momento la función no existe en la app.

**1. Termina de grabar.** El teleprompter para. Aparece una notificación discreta: *"Grabación lista — 8:42. Cámara y pantalla. ¿Componer ahora?"* Al pulsar, se abre el editor. Nada de buscar ficheros: los dos `.mov` y el sidecar están en la carpeta de la sesión.

**2. Al abrirse, ya se ve algo publicable.** No hay lienzo en blanco. La app aplica el preset por defecto (*Cara abajo-derecha, círculo pequeño*), el desfase del sidecar ya está aplicado y el vídeo está listo para reproducirse. **Si en este punto Alberto pulsa "Exportar", ya obtiene un vídeo correcto.** Todo lo demás es opcional.

**3. Prueba presets.** Pulsa `1`…`6`. La imagen cambia al instante (medido: 4,2 ms recomponer el fotograma congelado, 238 Hz). Encuentra el que le gusta.

**4. Ajusta con el ratón.** Arrastra el círculo de la webcam. Mientras el ratón está abajo **no se toca AVFoundation**: solo se dibuja el contorno en SwiftUI, a 120 Hz. En paralelo, la imagen se refresca ~25 veces por segundo. Al acercarse a una esquina, imán. Los tiradores de las esquinas cambian el tamaño; con Mayúsculas se mantiene la proporción. Al soltar, un solo *deshacer*.

**5. Reproduce para comprobar.** Botón Reproducir. Ve el resultado real, exactamente lo que se exportará — es el mismo motor de dibujo. Si arrastra mientras reproduce, el editor **pausa automáticamente** (medido: durante la reproducción un cambio tarda 0,194 s en verse por el buffer de adelanto de AVPlayer; en pausa es instantáneo).

**6. Divide por tramos.** Bajo la línea de tiempo ve **los capítulos de su propio guion** (sección 5). Pulsa el capítulo *"Resultados"* → el cursor salta ahí. Pulsa `S` → corte. Selecciona el tramo nuevo, pulsa `5` → *cara grande, pantalla pequeña*. Dos teclas y un clic. Repite para el resto. En ningún momento escribe "del minuto 1 al 2".

**7. Exporta.** Un botón, un diálogo corto: nombre, carpeta, calidad (*Alta / H.264* por defecto, *HEVC* para archivo más pequeño, *ProRes* para masterizar). Barra de progreso real. Un vídeo de 10 minutos sale en **1–2 minutos**. Al terminar, *"Mostrar en Finder"*.

**8. El proyecto queda guardado.** `project.json` junto a los dos `.mov`. Si mañana quiere retocar y reexportar, abre y sigue donde estaba. Los `.mov` originales **nunca se tocan**.

---

## 5. La idea diferenciadora: la app sabe qué palabra se decía en cada segundo

Ningún editor de vídeo del mundo sabe esto. **BtoPrompter sí**, porque él mismo iba pasando el guion mientras se grababa.

### La pieza ya existe

`Core/VoiceDiagnostics.swift:161` escribe `words.jsonl` con una línea por palabra: `{i, w, t_session, chunkID, src, wpm}`. `SessionAnalyzer.analyze(session:)` ya lo lee. Es exactamente palabra ↔ segundo.

**Pero está atado a los diagnósticos, que están apagados por defecto.** Por eso `ScriptTrack.swift` define una **pista de guion propia y mínima**, que el grabador escribe siempre que se grabe vídeo (es un JSON de unos pocos KB, sin audio, sin transcripción, sin datos personales), y que además **sabe leer `words.jsonl` si los diagnósticos estaban encendidos**.

```json
{ "startedAt": 1754... , "offsetSeconds": 0.35,
  "words": [ {"i":0,"t":0.00,"chunk":0}, {"i":1,"t":0.41,"chunk":0}, ... ],
  "chunks": [ {"id":0,"title":"Introducción","isGuide":true,"t":0.0}, ... ] }
```

Los títulos salen gratis: `ScriptParser` ya marca las **guías** (`isGuide`, chunks con rango de palabras vacío — títulos y `//`). Un título del guion **es** un capítulo del vídeo.

### Qué desbloquea, en concreto

1. **Capítulos automáticos en la línea de tiempo.** Bajo la tira de miniaturas, una segunda tira con los títulos del guion en su segundo exacto. Se navega el vídeo **por el discurso**, no por fotogramas.
2. **Saltar a una frase.** Un campo de búsqueda: escribe *"presupuesto"* → el cursor salta al segundo en que lo dijo. Buscar en el vídeo escribiendo lo que se dijo.
3. **Cortar por secciones, de un golpe.** Botón **"Un tramo por capítulo"**: genera todos los cortes en los límites de los capítulos. De un discurso de 9 minutos con 6 secciones salen 6 tramos listos para asignarles preset. Esto es lo que convierte "editar" en "elegir seis presets".
4. **Capítulos incrustados en el archivo exportado** (YouTube y QuickTime los leen). Se añade una pista de texto de tipo capítulo a la composición. Es la diferencia entre subir un vídeo y subir un vídeo **profesional**, sin trabajo humano.
5. **Reglas por sección, más adelante.** *"En todas las secciones marcadas como `//demo`, solo pantalla."* Una regla, aplicada a todo el vídeo.

### La honestidad sobre esto

- Si el avance fue **por tiempo** (`src: "tiempo"`), los tiempos son la estimación del motor: buenos para navegar, no exactos al fotograma. Se marca con un icono distinto.
- Si el avance fue **por voz** (`src: "voz"`), los tiempos son reales.
- Si Alberto improvisó fuera del guion, esos segundos no tienen palabra. El capítulo anterior se extiende. No se inventa nada.
- **Sin pista de guion el editor funciona igual**, solo sin capítulos. Degradación honesta, como manda la política del proyecto.

---

## 6. Fases de entrega

### Fase 0 — Sidecar de sincronía *(en el grabador, 1 día)* — **BLOQUEANTE**

Capturar `AVCaptureSession.synchronizationClock` (macOS 12.3+) y `SCStream.synchronizationClock` (macOS 13+), tomar el PTS del primer sample de cada fuente, convertir con `CMSyncConvertTime`, escribir `sidecar.json`. **Sin esto no se escribe una línea del editor.** Verificación: la prueba del destello — un flash en el mismo instante real en ambas fuentes debe caer en el mismo fotograma compuesto (verificado: t = 4,6667 s = 5,0 − 0,35, ±1 fotograma).

### Fase 1 — MVP verdaderamente útil *(3–4 días)*

`RecordingSidecar` + `VideoProject` + `CompositionGeometry` + `CompositionBuilder` + `CompositionExporter` + una ventana con previsualización y **una fila de presets**.

**Un preset. Posición fija. Exportar.** Se abre, se ve el vídeo compuesto, se elige entre 6 presets, se exporta. Sin arrastre, sin tramos, sin miniaturas. **Esto ya resuelve el 70 % de lo que Alberto hace.** Interruptor apagado por defecto y `--selftest` en verde.

*Con solo LayerInstruction: rectángulos, posición, tamaño, fondo, lado a lado, solo-pantalla, solo-cámara. Sin círculos todavía.*

### Fase 2 — Las formas bonitas *(4–5 días)*

`PiPCompositor` + `FrameComposer`. Círculo, esquinas redondeadas, borde, sombra. El mismo motor para previsualizar y exportar. **Bonus medido: la ruta bonita es un 30 % MÁS RÁPIDA** que el compositor interno de Apple (64,7 s vs 94,6 s en un vídeo de 10 min).

### Fase 3 — Arrastre directo *(4–5 días)*

`OverlayHandles` + mapeo de coordenadas vía `AVPlayerLayer.videoRect` + 8 tiradores + imanes + `UndoManager`. Refresco en pausa con el empujón subfotograma.

### Fase 4 — Tramos y línea de tiempo *(4–5 días)*

`TimelineStrip` + cortar/borrar/fusionar + cursor + miniaturas con `NSCache`. Aquí llega el *"del minuto 1 al 2 abajo, del 2 al 3 arriba"*.

### Fase 5 — La idea diferenciadora *(3–4 días)*

`ScriptTrack` + capítulos + búsqueda por frase + *"un tramo por capítulo"* + capítulos incrustados en el archivo exportado.

### Fase 6 — Gobernanza *(2–3 días)*

Presets del usuario, gestión de color con material real, pruebas de la política (apagado/encendido en caliente sin recursos abiertos), manual y README, revisión de código y de seguridad. *(Gate obligatorio antes de cualquier release.)*

---

## 7. Riesgos y límites de rendimiento, con cifras

### Rendimiento medido (Apple M5 Pro, 18 núcleos, macOS 26.5, binario `-O`)

**Exportación de 10 minutos a 1920×1080 / 30 fps, composición real de las dos fuentes:**

| Ruta | Material sintético (0,6 Mbps) | Material pesado (2560×1440@60 + 1080@30, ~210 Mbps) |
|---|---|---|
| **Core Image (elegida), H.264** | 64,7 s → **×9,3** tiempo real | **×5,3** → ~113 s |
| Core Image, HEVC | 67,9 s → ×8,8 | ×5,3 |
| Solo LayerInstruction | 94,6 s → ×6,3 | ×4,5 |

**Cifra honesta para Alberto: en un M5 Pro, entre ×5 y ×9 tiempo real. Diez minutos de vídeo se exportan en 1 a 2 minutos.**

**Edición y previsualización:**

| Operación | Medido |
|---|---|
| Compositor por fotograma (1280×720, círculo + aro + sombra) | 1,17–2,15 ms (sobra factor 15 sobre los 33 ms de 30 fps) |
| Recomponer fotograma congelado (el camino del arrastre) | 4,20 ms a 720p / 5,12 ms a 1080p → **195–238 Hz** |
| Decodificar el fotograma exacto de las dos fuentes | 27,8 ms — **el verdadero cuello de botella**, se cachea |
| Refresco en pausa (empujón subfotograma) | 744 Hz de capacidad, 30/30 recomposiciones |
| Reconstruir la composición entera desde el modelo | 0,0055 s (181 Hz) |
| Miniatura 160 px desde 1440p, tolerancia 0,5 s | 3,4 ms (297/s) |
| Miniatura **a través de la videoComposition** | 24 ms — **23× más caro** |
| Cambio en caliente durante la reproducción | 0,194 s de retardo (buffer de AVPlayer) |

**Límite no medido:** un Mac base (M1/M2 Air). La estimación de "la mitad de velocidad" es plausible pero **no verificada**; con material pesado y sin `allowsParallelizedExport` (que **no existe en macOS 13**) podría irse a 4–6 minutos por cada 10 de vídeo. Hay que probarlo antes de prometer tiempos.

### Riesgos, ordenados por lo que cuestan

| # | Riesgo | Evidencia | Mitigación |
|---|---|---|---|
| 1 | **Sincronía.** `AVAssetWriter` rebasa a cero; ambos ficheros mienten idénticamente | Reproducido: `timeRange.start = 0` y primer PTS = 0 en los dos | Sidecar JSON en el grabador. **Fase 0, bloqueante.** Plan B (correlación de audio) no verificado |
| 2 | **Excepciones ObjC no capturables que MATAN la app**: (a) preset ProRes con contenedor `.mp4`; (b) Core Animation tool en `AVPlayerItem` | Ambas reproducidas en vivo | Consultar `supportedFileTypes` (síncrono) **antes** de asignar el contenedor. Nunca la ruta Core Animation |
| 3 | **Huecos entre tramos** → `-11841` en la exportación, aunque la reproducción "parezca ir bien" | Regla explícita del header de Apple | Modelo de solo-cortes (imposible crear hueco) + validador. **Ojo: el validador bueno es macOS 15+**, en 13–14 hay que usar el antiguo |
| 4 | **Pistas de distinta longitud** (audio 10,00 s vs vídeo 9,65 s) → hueco al final → `-11841` | Diagnosticado con el validador de Apple | Recortar TODAS las pistas a la más corta |
| 5 | **`videoComposition` es `@NSCopying`**: mutar en sitio no hace nada y no da error | Verificado: la identidad tras asignar es distinta | Reasignar SIEMPRE. O mejor: usar la caja de parámetros del compositor vivo (`AVPlayerItem.customVideoCompositor` conserva la instancia) |
| 6 | **Tres sistemas de coordenadas** (modelo, LayerInstruction arriba-izq, Core Image abajo-izq) | Demostrado con imágenes: la cámara sale "reflejada en vertical" | Todo en `CompositionGeometry.swift`, con pruebas en `--selftest` |
| 7 | **`seek(to: tiempoActual)` NO refresca nada** (0/30 recomposiciones): parece un bug propio y no lo es | Medido | Desplazamiento de ±1/600 s con tolerancia cero → 30/30 |
| 8 | **Gestión de color.** El prototipo usa `DeviceRGB` sin espacio declarado. ScreenCaptureKit captura en Display P3, la webcam en BT.709 | **No verificable sin grabaciones reales** | Fijar `workingColorSpace`/`outputColorSpace` del `CIContext`. Forzar SDR desde el grabador y dejarlo por escrito |
| 9 | **Memoria de la caché de adornos**: ~8 MB por geometría a 1080p | No medido con muchos tramos ni a 4K | Caché LRU acotada; cachear solo el rect de la webcam, no el lienzo entero |
| 10 | **Fuga por `addPeriodicTimeObserver`** sin quitar al cerrar: retiene el AVPlayer y con él los ficheros | Fallo clásico | Quitarlo en `windowWillClose`. Comprobar en la prueba de encender/apagar |
| 11 | **Miniaturas a través de la composición**: 23× más caras, hunden el desplazamiento | Medido: 24 ms vs 1 ms | Miniaturas del asset de pantalla **en crudo**, con `maximumSize` y tolerancia 0,5 s |
| 12 | **Obsolescencia macOS 26** de toda la familia `AVMutable*` de composición | Real y literal en los headers | **Inofensiva hoy**: con `-target macos13.0` no se emite ni un aviso (comprobado). Aislada en `CompositionBuilder.swift` para migrar de un solo sitio |

### Dos correcciones a lo que se creía

- **`export(to:as:)` NO es macOS 15+.** Es `@backDeployed(before: macOS 26.0)` sobre una extensión de macOS 10.15. Compila con `-target arm64-apple-macos13.0` sin un error ni un aviso. **Se puede usar la API moderna directamente, sin `#available`.**
- **`states(updateInterval:)` SÍ es macOS 15+** y **lanza** (`for try await`). La barra de progreso necesita `if #available(macOS 15.0, *)` con respaldo en 13–14 sondeando la propiedad `progress`.

### Palanca gratis que no estaba en el plan

`AVVideoComposition.renderScale = 0.5` **en la composición de previsualización** (el header: *"May only be other than 1.0 for a video composition set on an AVPlayerItem"*). Baja a la mitad el coste de rascar la línea de tiempo. Se pone desde el día uno.

---

## 8. Preguntas para Alberto

**Sobre el alcance del MVP**

1. Si en la Fase 1 solo puedes elegir entre **6 presets y exportar** — sin arrastrar el recuadro, sin tramos — ¿te sirve ya para publicar, o para ti el mínimo aceptable incluye arrastrar la cámara con el ratón?
2. ¿Cuál de los seis presets tiene que ser **el que se aplica solo al abrirse**? (Mi apuesta: cara abajo-derecha en círculo pequeño.)

**Sobre el formato de salida**

3. ¿Adónde va el vídeo: **YouTube, WhatsApp, la web de la UEA, presentaciones**? Eso decide el lienzo por defecto (1920×1080 horizontal vs 1080×1920 vertical) y el códec.
4. ¿Quieres **vertical** para redes desde el principio, o solo horizontal? Lado a lado en vertical es cámara arriba / pantalla abajo, no izquierda/derecha: es un preset distinto.
5. Los `.mov` originales pueden pesar **varios GB**. ¿Se **borran automáticamente** tras exportar, se preguntan, o se guardan siempre? ¿Y dónde: junto al proyecto, en Películas, o eliges cada vez?

**Sobre el audio**

6. En la grabación de pantalla, ¿quieres que se capture también **el audio del sistema** (para vídeos donde suena algo en pantalla), o solo tu micrófono? Si son los dos, la mezcla por tramos gana sentido; si es solo el micro, ese control sobra en el MVP.

**Sobre la idea diferenciadora**

7. Los **capítulos automáticos desde tu guion** — ¿los ves como algo que usarías de verdad, o es adorno? Si los usarías, subo la Fase 5 por delante de la 4 (tramos manuales), porque *"un tramo por capítulo"* hace innecesario cortar a mano en la mayoría de casos.
8. ¿Te sirve que los capítulos vayan **incrustados en el fichero exportado** (YouTube los muestra como marcadores en la barra)?

**Sobre el rendimiento**

9. ¿En qué Mac vas a editar? Las cifras (10 min → 1-2 min) son de un M5 Pro. Si vas a componer en un Air, hay que medirlo antes de prometer nada.

**Sobre la política del proyecto**

10. El editor **se ve al compartir pantalla** (a diferencia del teleprompter). ¿Basta con un aviso en la interfaz, o quieres que el editor **se niegue a abrirse** si detecta que hay una captura de pantalla activa?
11. ¿El interruptor del editor va **junto al de grabación** (un solo "Grabación de vídeo" que enciende las dos cosas) o **separado** (por si alguien quiere componer vídeos ya grabados sin activar la cámara)?