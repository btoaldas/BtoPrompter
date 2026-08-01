# Plan de producto — BtoPrompter v0.1 → v0.5

**Fecha:** 1 de agosto de 2026 · **Base:** v0.0.4 · **Autor del plan:** arquitectura de producto
**Alcance:** grabación de vídeo (cámara + pantalla), importación de documentos (Word/PDF/RTF/iWork), y vistas + espejo remoto del guion.

> **Estado de la evidencia.** Las áreas *grabación* e *importación* vienen de investigación **ejecutada y re-verificada en este Mac** (macOS 26.5, SDK MacOSX26.5): binarios de prueba compilados con el mismo `swiftc -target arm64-apple-macos13.0` de `build.sh`, cabeceras del SDK leídas con número de línea, y una segunda pasada adversarial que corrigió al diseño original. El área *vistas y espejo remoto* llegó **sin pasada de verificación independiente** y con el documento truncado en el apartado (d): todo lo que se dice de ella está marcado como **[SIN VERIFICAR]** o **[PARCIAL]** más abajo. No lo tapo: es la parte más débil de este plan.

---

## 1. Política de funciones independientes

Esta regla es normativa. Va a `ARCHITECTURE.md` como sección propia y es criterio de rechazo en revisión de código: si una función no la cumple, **no entra**, aunque funcione.

### 1.1 La regla (redacción para el repositorio)

> **Toda función nueva de BtoPrompter debe ser un módulo apagable, silencioso cuando está apagado, e incapaz de degradar cualquier otra función.**
>
> 1. **Activable.** Existe exactamente **una clave en `Storage/Settings.swift`** que la enciende y la apaga, y un control visible en Configuración. Nada se activa por detección automática del sistema, por versión de macOS ni por "estaba disponible".
> 2. **Apagada por defecto si toca permisos, red, disco pesado o CPU sostenida.** Concretamente: cualquier cosa que dispare TCC (cámara, pantalla, micrófono, automatización), abra un socket, escriba fuera de Application Support, o consuma CPU durante más de un segundo. Las funciones puramente locales, sin permisos y de coste despreciable (leer un `.docx`) pueden nacer encendidas.
> 3. **Coste cero cuando está apagada.** Con el interruptor en `false` **no se instancia el objeto**: ni `AVCaptureSession`, ni `SCStream`, ni `VNRecognizeTextRequest`, ni `NWListener`, ni timers, ni sinks de Combine, ni observadores de `NotificationCenter`. No se pide ningún permiso, no aparece ningún botón, no se ejecuta ni una línea en el bucle de dibujo. El coste de una función apagada debe ser una comparación booleana en el arranque.
> 4. **No interfiere.** Una función no puede: apropiarse de un recurso exclusivo que otra ya usa (micrófono, cámara, hilo principal), escribir en el estado persistente de otra, ni cambiar el comportamiento observable de otra. **Un recurso, un dueño.** Si dos funciones necesitan el mismo dispositivo, se arbitra explícitamente en un coordinador, nunca abriendo el dispositivo dos veces "a ver si macOS aguanta".
> 5. **Un escritor por propiedad crítica.** `window.sharingType`, `NSApp.activationPolicy`, las aserciones de `IOPMAssertion` y el micrófono tienen **un único punto de escritura** en todo el código. Quien quiera influir sobre ellos publica una intención; el dueño decide. Prohibido el segundo escritor.
> 6. **La invisibilidad es intocable.** Ninguna función puede dejar la ventana del prompter en un estado capturable sin una acción explícita, consciente y **transitoria** del usuario. Al terminar esa acción, y al arrancar la app, el estado se **recalcula desde `Settings`**, nunca se hereda.
> 7. **Degradación honesta.** Si falta un permiso, una app o una versión de macOS, la función se desactiva sola, lo dice con palabras claras, y **el resto de la app sigue igual de bien que antes**. Nunca un fallo silencioso.
> 8. **Sin sorpresas por versión del sistema.** Si una API nueva de macOS 26 hace algo mejor que la de macOS 13, va detrás de **su propia casilla**, no detrás de un `if #available` silencioso. Dos Macs con el mismo guion deben dar el mismo resultado salvo que el usuario haya pedido lo contrario.

### 1.2 Cómo se comprueba en la práctica

No es una declaración de intenciones: cada punto tiene una comprobación concreta y barata.

| # | Comprobación | Cómo se ejecuta |
|---|---|---|
| C1 | **Prueba del interruptor apagado** | Con TODAS las funciones nuevas en `false`, arrancar la app y verificar con `sample BtoPrompter` / `Instruments` que no aparecen hilos ni objetos de AVFoundation/ScreenCaptureKit/Vision/Network. Y con `log stream --predicate 'subsystem == "com.apple.TCC"'`: **cero** consultas de TCC. |
| C2 | **Prueba de invisibilidad (obligatoria antes de cada release)** | Ampliar el arnés que ya existe en `/tmp/scktest/test.swift` y convertirlo en `Sources/App/SelfTest.swift` + flag `--test-sharing`: ventana con `.none` + ventana de control con `.readOnly`, captura por `SCScreenshotManager`, comprobar el píxel. Ya está probado: la `.none` devuelve el escritorio, la de control devuelve su color. Se corre **después** de cualquier cambio que toque `AppDelegate`, `PrompterEngine` o grabación. |
| C3 | **Rejilla de convivencia** | Matriz de pares que se prueba a mano y se anota en `docs/`: {grabación} × {seguimiento por voz, TTS, diagnóstico de audio, control remoto, diapositivas, atajos}. Un par por fila, encendido/apagado, resultado esperado escrito antes de probar. Son ~12 casos; media hora. |
| C4 | **Auditoría de escritor único** | `grep -rn "sharingType\|setActivationPolicy\|IOPMAssertionCreate\|installTap" Sources/` debe devolver **una** asignación por propiedad. Si devuelve dos, la revisión se rechaza. Va como comprobación en la lista previa a release. |
| C5 | **Coste medido, no supuesto** | Toda función con CPU/memoria se mide con `getrusage`/RSS en un binario suelto antes de plegarse al repo, y el número entra en el manual. Ya hay precedente: OCR 0,38–0,54 s/página y pico de 250–350 MB; dos grabaciones HEVC simultáneas = 1 % de un núcleo. |
| C6 | **Funciones puras y `--selftest`** | Toda lógica sin efectos secundarios (`ScriptParser`, el nuevo `TextReflow`) se prueba desde `SelfTest.swift`. `./build.sh && ./dist/BtoPrompter.app/Contents/MacOS/BtoPrompter --selftest` debe imprimir `SELFTEST OK`. Línea base medida hoy: build 20,8 s, selftest OK. |
| C7 | **Prueba de arranque en frío tras caída** | Matar la app con `kill -9` durante una grabación / en modo solo-remota, y verificar al reabrir: `sharingType` correcto, política de activación `.regular`, ninguna aserción de energía huérfana (`pmset -g assertions`). |

**Regla de oro operativa:** ninguna función nueva se declara "hecha" sin C1, C2 y su fila de C3.

---

## 2. Tabla resumen de funciones

| # | Función | Viabilidad | Esfuerzo | Permisos nuevos | ¿Cuenta de desarrollador de pago? |
|---|---|---|---|---|---|
| 1 | **Grabar cámara** (AVCaptureSession + MovieFileOutput, cuenta atrás, preview) | **directo** | 3–4 días | Cámara (TCC) + `NSCameraUsageDescription` | **No** |
| 2 | **Grabar pantalla** (SCStream + SCRecordingOutput) | **con trabajo** | 3–4 días | Grabación de Pantalla (TCC, exige reiniciar la app) | **No** |
| 3 | **Audio de sistema en la grabación de pantalla** | directo (dentro de #2) | +0,5 día | Ninguno extra (mismo TCC de pantalla) | No |
| 4 | **Prompter visible en MI vídeo, opción A** (flip transitorio de `sharingType`) | **limitado** | 1 día | Ninguno | No |
| 5 | **Prompter quemado en el vídeo sin fuga, opción B** (AVAssetWriter + `cacheDisplay`) | **con trabajo** | 4–5 días | Ninguno | No |
| 6 | **Composición PiP offline** (cámara sobre pantalla al terminar) | directo | 2 días | Ninguno | No |
| 7 | **Biblioteca de grabaciones** (`~/Movies/BtoPrompter`, papelera, Finder, QuickTime) | directo | 1 día | Ninguno | No |
| 8 | **Importar `.rtf`** | **directo** | 1–2 h | Ninguno | No |
| 9 | **Importar `.docx`** (unzip -p + XMLParser) | **directo** | 0,5 día | Ninguno | No |
| 10 | **Importar PDF con capa de texto** + reflow geométrico | **directo** | 1–1,5 días | Ninguno | No |
| 11 | **OCR de respaldo** para PDF escaneado (Vision rev3) | **directo** | 1 día | **Ninguno** (Vision es local, sin TCC) | No |
| 12 | **OCR estructurado macOS 26** (`RecognizeDocumentsRequest`) | limitado (solo macOS 26+) | 0,5 día | Ninguno | No |
| 13 | **Importar iWork `.pages` / `.key`** (AppleScript) | **limitado** | 0,5 día | Automatización de Pages (Keynote ya está) | No |
| 14 | **Espejo del guion en el teléfono con karaoke** (SSE) | **con trabajo** [PARCIAL] | 3–4 días | Ninguno (usa el servidor y el token que ya existen) | No |
| 15 | **5 modos de vista** (normal / +remota / solo remota / mini / mini+remota) | **con trabajo** [PARCIAL] | 2–3 días | Ninguno | No |
| 16 | **Mantener la pantalla del móvil encendida** (Wake Lock) | **limitado** [SIN VERIFICAR] | 0,5 día | Ninguno | No |
| 17 | **Espejado horizontal** (teleprompter físico con espejo), en el móvil | **directo** | 1 h | Ninguno | No |
| 18 | Botón de grabar en el control remoto | directo | 0,5 día | Ninguno | No |

**Nada de este plan exige Apple Developer Program de pago.** La única puerta que sí lo exigiría —`com.apple.developer.persistent-content-capture`, para librarse de la alerta periódica de captura de pantalla— está **cerrada por diseño** y sustituida por `SCContentSharingPicker` (ver §4.6). Verificado además que una app **autofirmada sin Team ID** sí obtiene captura de pantalla en macOS 26.5: `/Applications/BetoDicta.app` (`Authority=BetoDicta Self Signed`, `TeamIdentifier=not set`) figura en `ScreenCaptureApprovals.plist` con 22 usos reales.

**Leyenda de viabilidad:** *directo* = APIs probadas, sin sorpresas · *con trabajo* = viable pero con un refactor o una mitigación seria de por medio · *limitado* = funciona con una pega estructural que el usuario debe aceptar · *inviable* = no se hace (§6).

---

## 3. Diseño por área, encajado en las capas actuales

Las reglas de dependencia no cambian: `UI` observa `Core` y lee `Theme`, nunca toca disco · `Core` usa `Storage`, no conoce vistas · `Storage` no conoce a nadie · `App` conecta. `build.sh` compila `Sources/**/*.swift`, así que **los archivos nuevos entran solos**: no hay que tocar el script ni el firmado (verificado: un binario que importa PDFKit + Vision + UniformTypeIdentifiers compila sin ningún `-framework`, el autolink de Swift los resuelve).

### 3.1 Grabación

**`Sources/Core/`**

| Archivo | Tipos | Responsabilidad |
|---|---|---|
| `RecordingCoordinator.swift` | `final class RecordingCoordinator: ObservableObject`, `enum RecordingState { idle, countdown(Int), recording, paused, stopping, failed(String) }`, `struct RecordingTargets { camera: Bool, screen: Bool }` | Único dueño de la grabación: cuenta atrás, arranque y parada conjunta, aserción de energía propia, guarda de disco, bandera `isStartingCapture` para el arbitraje del micrófono, publicación de `recordingVisibilityOverride`. |
| `CameraRecorder.swift` | `final class CameraRecorder: NSObject, AVCaptureFileOutputRecordingDelegate` | `AVCaptureSession` + `AVCaptureMovieFileOutput`. Enumeración de dispositivos, `activeFormat`, códec vía `outputSettings(for:)` → sobrescribir `AVVideoCodecKey` → `setOutputSettings(_:for:)`. Manejo de `AVCaptureSessionRuntimeError` y `.wasDisconnected` (Continuity Camera). |
| `ScreenRecorder.swift` | `@available(macOS 15.0, *) final class ScreenRecorder: NSObject, SCRecordingOutputDelegate, SCContentSharingPickerObserver` | `SCStream` + `SCRecordingOutput`. Dos rutas de filtro: `SCContentSharingPicker` (por defecto) y `SCContentFilter` directo (opcional, con aviso). |
| `RecordingComposer.swift` *(fase 5)* | `enum RecordingComposer` | Composición PiP **offline** con `AVMutableComposition` + `AVVideoComposition` + `AVAssetExportSession`. |
| `PrompterOverlayRenderer.swift` *(fase 6, opcional)* | `struct PrompterOverlayRenderer` | Render del prompter en proceso con `bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay(in:to:)` → `CIImage` sobre los buffers `.screen`. Verificado que funciona sobre una ventana `.none`: devolvió el color real, el dibujo en proceso no está sujeto a `sharingType` ni a TCC. |

**`Sources/Storage/`**

| Archivo | Tipos | Responsabilidad |
|---|---|---|
| `RecordingLibrary.swift` | `enum RecordingLibrary`, `struct RecordingSessionMeta: Codable` | Resolver `~/Movies/BtoPrompter/` vía `FileManager.url(for: .moviesDirectory,…)`, crear la carpeta de sesión, escribir `sesion.json`, listar, calcular tamaño, **borrar siempre con `FileManager.trashItem`**, y reportar espacio libre (`.volumeAvailableCapacityForImportantUsageKey`). |

**`Sources/UI/`**

| Archivo | Responsabilidad |
|---|---|
| `RecordingSettingsView.swift` | Panel de Configuración → Grabación: interruptores, selección de dispositivos, resolución/fps, códec, contenedor, cuenta atrás, audio, visibilidad del prompter, umbral de disco, y el botón **"Probar grabación (1 s)"**. |
| `CameraPreviewWindow.swift` | `NSPanel` **no activante**, `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, `sharingType = .none` por defecto, con `AVCaptureVideoPreviewLayer` dentro de un `NSViewRepresentable`. Copia exacta del patrón de `AppDelegate.swift:65-66`. |
| `RecordingsView.swift` | Sección "Grabaciones" en `SidebarView`: lista por sesión, duración, tamaño, botones Mostrar en Finder / Abrir / Componer PiP / Mover a la papelera. |
| `RecordingIndicator.swift` | Punto rojo + cronómetro + tamaño acumulado en `PrompterView` y `MiniPrompterView`. Es una vista pequeña; puede vivir en `Components.swift`. |

**`Sources/App/AppDelegate.swift` — el cambio delicado (una sola vez):**

Hoy hay un `sink` sobre `model.$spyMode` que escribe `window.sharingType` (líneas 82-87). Se sustituye por **un único** `Publishers.CombineLatest(model.$spyMode, recorder.$recordingVisibilityOverride)` que es el **único escritor** de `sharingType` en toda la app. Sin esto, la Opción A es una regresión de invisibilidad silenciosa esperando a ocurrir: `@Published` emite en cada `set`, aunque el valor no cambie, y `PrompterEngine.swift:180` recalcula `spy` en el arranque.

**`Sources/Storage/Settings.swift` — claves nuevas (todas `false`/neutras por defecto):**

```
recordingEnabled(false)              recordCamera(false)          recordScreen(false)
recordCameraDeviceID("")             recordMicDeviceID("")
recordWidth(1920)  recordHeight(1080)  recordFPS(30)
recordCodec("hevc")                  recordContainer("mov")
recordCountdownSeconds(3)            recordShowPreview(false)     recordPreviewSharingNone(true)
recordScreenSystemAudio(false)       recordScreenUsePicker(true)
recordPrompterInVideo("no")          // "no" | "flip" | "overlay"
recordAutoStopOnScriptEnd(false)     recordMinFreeGigabytes(5)
recordFolder("")                     recordSkipDiagnosticsAudio(true)
recordAllowFromRemote(false)
```

**Entitlements** (`BtoPrompter.entitlements`, runtime reforzado): **añadir solo** `com.apple.security.device.camera`. Apple lo confirma textualmente: *"first enable the App Sandbox or Hardened Runtime capability"* — aplica a runtime reforzado, igual que el `audio-input` que ya funciona. `audio-input` y `automation.apple-events` se quedan como están. **No** añadir `persistent-content-capture`. La grabación de pantalla **no necesita ningún entitlement**: es puro TCC.

**`Info.plist`:** añadir `NSCameraUsageDescription` (obligatorio desde macOS 10.14; hoy falta). Ampliar el texto de `NSMicrophoneUsageDescription` para mencionar la grabación de vídeo. `LSMinimumSystemVersion` **sigue en 13.0**: verificado que `swiftc -O -target arm64-apple-macos13.0` compila y ejecuta un binario con `@available(macOS 15.0, *)` sobre la clase que conforma `SCRecordingOutputDelegate`. La cámara funciona en 13; la pantalla se oculta bajo macOS 15.

### 3.2 Importación

**`Sources/Core/`**

| Archivo | Tipos | Responsabilidad |
|---|---|---|
| `ImportersDocs.swift` | `enum DocxImporter`, `enum RtfImporter`, `enum PdfImporter`, `final class OcrEngine` | Cada formato, una función. `docx`: `Process(/usr/bin/unzip -p)` por `Pipe` (sin materializar archivos → el ZIP-slip desaparece de raíz) + `XMLParser` en streaming con `shouldResolveExternalEntities = false`. `pdf`: `PDFDocument` + geometría (`selection(for:)` → `selectionsByLine()` → `bounds(for:)`). `ocr`: `VNRecognizeTextRequest` rev3. |
| `TextReflow.swift` | `enum TextReflow` — **función pura** | Normalización (NBSP, U+200B, FEFF, CRLF, `precomposedStringWithCanonicalMapping`), unión de guiones de corte, y reflow geométrico: altura de línea > 1,25× mediana → `##`, > 1,6× → `#`; hueco vertical > 1,7× → párrafo; `x` mayor que el cuerpo → viñeta; ancho < 80 % del máximo → cierre de párrafo; cabecera/pie **por posición** (bandas del 7 %) más repetición entre páginas. Testeable desde `SelfTest.swift`. |

`Importers.swift` **se queda solo con el despacho**: tres casos nuevos en el `switch` de `importFiles(urls:folder:)` (línea 9) + iWork opcional. **No se toca `extractPPTX`** (línea 46): funciona, tiene su defensa contra symlinks, y migrarlo al `XMLParser` es un cambio aparte con su propio selftest.

**`Sources/UI/`:** `ImportSettingsView.swift` (interruptores por formato, OCR, tope de páginas, iWork) y `ImportPreviewSheet.swift` (vista previa del texto antes de guardar, con el conmutador de detección de títulos). En `SidebarView.swift:226-239`, añadir los `UTType` al `NSOpenPanel` — los cinco verificados como `isDeclared=true`: `org.openxmlformats.wordprocessingml.document`, `public.rtf`, `com.adobe.pdf`, `com.apple.iwork.pages.sffpages`, `com.apple.iwork.keynote.sffkey`.

**Settings nuevos:** `importDocx(true)`, `importRtf(true)`, `importPdf(true)`, `importDetectHeadings(false)`, `importOcrEnabled(false)`, `importOcrMaxPages(50)`, `importOcrUseDocumentsAPI(false)`, `importIWorkEnabled(false)`, `importPdfTablesMode("bullets")`.

**Entitlements: ninguno nuevo.** Verificado firmando un binario de prueba con la identidad real `BtoPrompter Local Signing`, `--options runtime` y `BtoPrompter.entitlements` sin modificar: el OCR de Vision funcionó igual. La app no está en sandbox, así que tampoco aplica `files.user-selected.read-only`. **No añadir `app-sandbox`**: rompería el `Process(/usr/bin/unzip)` que ya usa el importador de `.pptx`.

### 3.3 Vistas y espejo remoto — **[PARCIAL / SIN VERIFICAR]**

**`Sources/Core/`**

| Archivo | Tipos | Responsabilidad |
|---|---|---|
| `LiveMirror.swift` | `final class LiveMirror` | Hub de Server-Sent Events sobre las `NWConnection` que ya crea `RemoteControl`. Mantiene N streams (tope 4, expulsa el más viejo), emite delta coalescido a ≤10 Hz, heartbeat `: ping` cada 15 s. |
| `RemoteMirrorPage.swift` | `enum RemoteMirrorPage` | El HTML/CSS/JS del espejo, como string, siguiendo el patrón de `RemoteControl.page(token:)` (línea 212). Fuera de `RemoteControl.swift` para no engordarlo. |
| `ViewModeController.swift` | `enum ViewMode { normal, normalRemota, soloRemota, mini, miniRemota }` | Único dueño de `window.setIsVisible`, `NSApp.setActivationPolicy` y del tipo de aserción de energía. Red de seguridad: vuelta automática a `normal` si el servidor muere. |

**Cambios en `RemoteControl.swift`:** dos rutas nuevas, `GET /script` (el guion troceado una vez) y `GET /live` (SSE). Y **un arreglo obligatorio**: `/status` hace hoy `DispatchQueue.main.sync` desde la cola de red (línea 154); con conexiones de vida larga eso es un bloqueo del hilo principal esperando a suceder. Se invierte: un sink de Combine construye el snapshot **en main**, lo guarda en una caja con lock, y la cola de red solo lee. **Nunca `main.sync`.**

**Settings nuevos:** `viewMode("normal")`, `mirrorEnabled(false)`, `mirrorFontSize(28)`, `mirrorHorizontalFlip(false)`, `soloRemotaHotkeyEnabled(false)`, `statusItemEnabled(false)`, `soloRemotaFailsafeSeconds(10)`.

**Entitlements y permisos: ninguno nuevo.** Reutiliza el `NWListener` y el token que ya existen.

---

## 4. La grabación en detalle (prioridad 1)

### 4.1 El hecho fundacional: ScreenCaptureKit respeta `sharingType = .none`

Confirmado a cuatro ángulos, y el ángulo principal **re-ejecutado de forma independiente** en este Mac. Salida literal de la segunda pasada:

```
SECRETO(.none)   esperado NO magenta en (300,628) -> RGB(30,30,30)
CONTROL(.readOnly) esperado CIAN      en (800,628) -> RGB(117,251,253)
```

Los otros tres ángulos (frame de un MP4 real grabado con `SCRecordingOutput`; filtro de ventana única `SCContentFilter(desktopIndependentWindow:)` apuntando **directo** a la ventana `.none`, que devolvió negro absoluto; y conmutación en caliente a mitad de grabación, frame-accurate) provienen de la primera pasada y **no fueron re-ejecutados**: quedan como plausibles con evidencia coherente, no como doblemente confirmados.

**Consecuencia de producto:** el teleprompter queda fuera de la grabación de pantalla **automáticamente y sin escribir una línea**, igual que ya queda fuera de Zoom. Ese es el estado por defecto y el que se documenta.

**Matiz de privacidad, verificado:** la ventana sigue apareciendo en `SCShareableContent.windows` con su **título** (`title=SECRETO-NONE` en la prueba). Los píxeles se redactan, el título no. Acción concreta: **el título de la ventana del prompter debe ser neutro**, jamás el nombre del discurso.

### 4.2 Flujo completo: de pulsar Grabar a tener los archivos

```
[0] PRE-VUELO (antes de que exista un botón)
    Configuración → Grabación → "Activar grabación de vídeo"
      · pide TCC de cámara: AVCaptureDevice.requestAccess(for: .video)
      · si se activa pantalla: CGPreflightScreenCaptureAccess()
          → si no: CGRequestScreenCaptureAccess() (NO bloquea: nada de polling)
          → UI explícita: "Concedido. Reinicia BtoPrompter para activarlo." + botón Reiniciar
      · botón "Probar grabación (1 s)": arranca y para una captura de un segundo
        → fuerza a que cualquier alerta del sistema caiga AQUÍ, en el ensayo,
          y no en el escenario. Es obligatorio, no un extra.

[1] EL BOTÓN
    Solo existe si recordingEnabled == true. Si está en false, RecordingCoordinator
    ni se instancia. Aparece en PrompterView, MiniPrompterView y (si
    recordAllowFromRemote) en la pestaña Teleprompter del móvil.

[2] AL PULSAR — comprobaciones previas, en este orden
    a. Espacio libre ≥ recordMinFreeGigabytes → si no, se niega con el número exacto.
    b. Dispositivos presentes (la Continuity Camera puede haberse ido).
    c. Crear ~/Movies/BtoPrompter/2026-08-01_14-32-05_Nombre-del-discurso/
    d. Aserción de energía PROPIA del coordinador:
       kIOPMAssertionTypePreventUserIdleSystemSleep + NoDisplaySleep.
       (La de PrompterEngine.swift:270 está atada a que el prompter esté corriendo:
        grabar sin prompter o en pausa dejaría dormir el Mac y truncar el archivo.)
    e. isStartingCapture = true  ← ventana de arbitraje del micrófono (§4.4)

[3] CUENTA ATRÁS 3-2-1
    Se dibuja en la ventana del prompter, que es .none → NO sale en el vídeo de
    pantalla. Decisión consciente: la cuenta atrás es para Alberto, no para el
    espectador. (Si se quisiera dentro del vídeo, tendría que salir también en
    Zoom: no compensa.)

[4] ARRANQUE CONJUNTO
    · CameraRecorder.start()  → camara.mov   (vídeo cámara + MICRÓFONO)
    · ScreenRecorder.start()  → pantalla.mov (vídeo pantalla + solo audio de SISTEMA,
                                              excludesCurrentProcessAudio = true)
    · Se anota CMClockGetTime(CMClockGetHostTimeClock()) en cada didStartRecording
      y el delta va a sesion.json. SCStream.synchronizationClock (SCStream.h:453)
      es el reloj de referencia del lado pantalla.
    · isStartingCapture = false tras ~300 ms.

[5] DURANTE
    · Indicador rojo + cronómetro + MB acumulados (recordedDuration / recordedFileSize,
      existen en ambos outputs).
    · Pausa del teleprompter → pauseRecording() / resumeRecording()
      (AVCaptureFileOutput.h:117/133, macOS 10.7+). SCRecordingOutput no tiene pausa:
      la pantalla sigue grabando, y eso se dice en el manual.
    · movieFragmentInterval fijado → si la app cae, el .mov sigue siendo reproducible.
    · Vigilancia de disco cada 10 s: por debajo del umbral → corte limpio + aviso.
    · Desconexión de Continuity Camera → se cierra camara.mov correctamente,
      pantalla.mov sigue, y se avisa. Nunca un archivo corrupto sin explicación.

[6] AL PARAR
    a. stopRecording() en ambos; esperar los delegados (no asumir sincronía).
    b. Escribir sesion.json: título, id del discurso, duración, dispositivos,
       WPM medio, marcas de tiempo, delta de sincronización, versión de la app.
    c. Liberar la aserción de energía.
    d. Restaurar recordingVisibilityOverride = false (y recalcularlo desde Settings
       al arrancar, por si la app cayó).
    e. Notificación con botón "Mostrar en Finder".

[7] DESPUÉS (opcional, offline)
    "Componer PiP" en la biblioteca → AVMutableComposition + AVVideoComposition
    + AVAssetExportSession → compuesto.mov junto a los originales. Nunca destruye
    los archivos de origen.
```

**Resultado en disco:**

```
~/Movies/BtoPrompter/2026-08-01_14-32-05_Presupuesto-2027/
    camara.mov      1080p30 HEVC + micrófono        ≈ 8–15 MB/min (medido)
    pantalla.mov    HEVC + audio de sistema          2,7–53 MB/min (medido; ~30 típico)
    sesion.json     metadatos + delta de sincronía
    compuesto.mov   (solo si se pide el PiP)
```

Presupuesto realista: **~1,8 GB/hora de pantalla** más la cámara. Una charla de 90 minutos con ambos: 4–6 GB. Por eso `recordMinFreeGigabytes` existe.

### 4.3 La decisión clave: ¿sale el teleprompter en la grabación de pantalla?

Tres opciones, y **la recomendación es implementar 1 y 3, y ofrecer 2 solo con la etiqueta correcta**.

| Opción | Qué hace | Coste | Fuga a Zoom | Recomendación |
|---|---|---|---|---|
| **1. `no` (por defecto)** | El prompter no sale. Es lo que ya pasa gratis con `.none`. | 0 | Ninguna | **Por defecto, siempre.** |
| **2. `flip`** | Override transitorio `sharingType → .readOnly` mientras graba. Verificado que funciona incluso a mitad de grabación, frame-accurate. | 1 día | **SÍ.** `sharingType` es global de la ventana, no por consumidor: mientras grabas, Zoom/Teams **también** ven el prompter. | Solo como elección **por grabación** (nunca persistente), con etiqueta literal: *"El prompter será visible TAMBIÉN para quien vea tu pantalla compartida."* Y **exige** el refactor de escritor único (§3.1). |
| **3. `overlay`** | El prompter se mantiene `.none` siempre y **lo componemos nosotros** dentro del vídeo: `cacheDisplay(in:to:)` sobre la vista → `CIImage` sobre los buffers `.screen` de `SCStream`, escribiendo con `AVAssetWriter`. Verificado que el render en proceso devuelve los píxeles reales aunque la ventana sea `.none`. | 4–5 días | **Ninguna, nunca** | **La respuesta correcta a largo plazo**, y la única que respeta la seña de identidad sin excepciones. Fase 6. |

Mi posición como arquitecto: **la Opción 2 es una trampa de producto**. Es barata y hace justo lo que rompe la promesa del producto —el prompter reapareciendo en Zoom— en el momento de máxima presión. Si entra, entra apagada, por grabación, con ese texto exacto, y con C2 corriendo antes de cada release.

### 4.4 Convivencia con la grabación de voz del diagnóstico (el conflicto real)

Este es el choque concreto, verificado en el código, no una preocupación teórica.

**El problema.** `VoiceTracker.swift:13` tiene un único `private let engine = AVAudioEngine()`, instala el tap en la línea 383 (`installTap(onBus: 0…)`) y **observa `.AVAudioEngineConfigurationChange` en la línea 188, respondiendo con `stop()/start()`**. `VoiceDiagnostics` escribe su `AVAudioFile` desde **ese mismo tap**. Y hay ya un **segundo** `AVAudioEngine` con su propio tap en `VoiceTracker.swift:93-101` (ruta de calibración).

Si `CameraRecorder` añade un `AVCaptureDeviceInput` de micrófono, macOS permite dos clientes del mismo dispositivo (a diferencia de iOS), **pero arrancar la `AVCaptureSession` dispara `AVAudioEngineConfigurationChange`** → el seguimiento por voz se reinicia **justo al pulsar Grabar**, en mitad de la presentación. Sería una tercera apertura del dispositivo.

**Las dos salidas, y qué elegir.**

| | Mitigación mínima | Mitigación limpia |
|---|---|---|
| **Cómo** | `MovieFileOutput` abre el micrófono, y el manejador de `AVAudioEngineConfigurationChange` consulta `RecordingCoordinator.isStartingCapture` para **suprimir el reinicio** durante los ~300 ms del arranque. | **No abrir el micrófono dos veces**: alimentar un `AVAssetWriterInput` de audio con los buffers PCM del tap que **ya existe**. Una sola apertura, cero pelea posible. |
| **Coste** | Horas | Obliga a `AVAssetWriter` en vez de `MovieFileOutput` → +2 días y se pierden `pauseRecording`/`resumeRecording` gratis |
| **Riesgo** | Frágil: depende de una ventana temporal | Ninguno estructural |

**Decisión propuesta:** **fase 1 con `MovieFileOutput` + `isStartingCapture`**, y en Configuración una casilla honesta: *"Seguimiento por voz durante la grabación"* — apagada por defecto, con la advertencia de que si está encendida el seguimiento se reinicia brevemente al empezar a grabar. Si la rejilla C3 muestra que el reinicio es visible y molesto, **la fase 6 lo resuelve de raíz** al migrar a `AVAssetWriter` para el overlay: el mismo refactor arregla las dos cosas.

**Audio duplicado en disco.** `Settings.diagnosticsRecordAudio` ya escribe un `.caf` del micrófono. Con vídeo activo se escribiría el mismo micrófono dos veces. Por eso existe `recordSkipDiagnosticsAudio(true)`: mientras la grabación de vídeo esté activa, el diagnóstico **reutiliza el audio del vídeo** y no escribe su `.caf`. La alineación palabra↔segundo sigue funcionando: el delta de relojes está en `sesion.json`.

**Realimentación del TTS — riesgo abierto.** `excludesCurrentProcessAudio = true` mantiene fuera el TTS de Piper (`TTSEngines.swift:113` lanza un `Process` solo para escribir un `.wav`; la reproducción vuelve al proceso). Pero `SpeechPlayback.swift:14` usa `AVSpeechSynthesizer`, y en macOS ese audio lo renderiza el **demonio de síntesis del sistema, fuera del proceso** → muy probablemente **sí se colará** en `pantalla.mov`. **No verificado**: haría falta grabar con TTS del sistema sonando y analizar la pista. Mitigación prevista: `AVSpeechSynthesizer.write(_:toBufferCallback:)` (macOS 10.15+) reproduciendo por el `AVAudioPlayer` que ya existe en `SpeechPlayback.swift:54`; alternativa barata: desactivar las voces del sistema mientras se graba audio de pantalla. **Esto se mide en la fase 3 antes de decidir.**

### 4.5 Modo "solo remota" y grabación — nota de energía

Si en el futuro se graba con el prompter oculto: la aserción del coordinador debe ser `PreventUserIdleSystemSleep`, no solo `NoDisplaySleep`. La pantalla puede apagarse; el sistema no.

### 4.6 La alerta periódica de macOS: el riesgo de producto número uno

Medido en `~/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist` de este Mac: la clave `kScreenCapturePrivacyHintPolicy` vale **2592000 s (30 días)** para apps autofirmadas como las de Alberto, frente a **7776000 s (90 días)** para las notarizadas con Developer ID.

Traducción: BtoPrompter recibirá **cada ~30 días**, al iniciar captura, un modal del sistema — *"…solicita omitir el selector de ventanas privado del sistema y acceder directamente a tu pantalla y audio"*, con botones "Permitir durante un mes" / "Abrir Ajustes". Un modal del sistema que aparece **por encima de todo**, incluido el prompter en vivo y la sesión de Zoom. En un teleprompter usado en directo, **eso es exactamente lo que la política de §1 prohíbe**.

**Mitigaciones, en este orden:**

1. **`SCContentSharingPicker` como ruta por defecto** (macOS 14.0+, presente en el SDK 26.5, `SCContentSharingPicker.h:33/63`). La alerta es el castigo por *saltarse* el selector privado; adoptándolo no debería haber recordatorio. Su `SCContentSharingPickerConfiguration` trae además `excludedWindowIDs` y `excludedBundleIDs` → **segunda capa** de exclusión del prompter, independiente de `sharingType`. **[NO VERIFICADO]** que suprima realmente el recordatorio para una app autofirmada sin Team ID: la guía de Apple y el propio texto de la alerta lo implican, pero no hay documento tajante. **Se comprueba en la fase 3 mirando si aparece entrada nueva en `ScreenCaptureApprovals.plist`.**
2. **Botón "Probar grabación (1 s)"** en Configuración. Imprescindible aunque el selector funcione: fuerza a que cualquier alerta caiga en el ensayo.
3. **Ruta `SCContentFilter` directa** (sin selector) como interruptor opcional, con el aviso del recordatorio mensual escrito en la propia casilla.
4. La vía del entitlement está cerrada sin cuenta de pago, y no se persigue.

### 4.7 Trampa en `build.sh`

Si el certificado `BtoPrompter Local Signing` no está, `build.sh` cae a `codesign -s -` (**ad-hoc**, que no es lo mismo que autofirmado). Hay reportes públicos de que macOS rechaza ScreenCaptureKit en apps ad-hoc sin Team ID (Cap #1722). En otra máquina o en CI, la grabación de pantalla no funcionaría **nunca y sin mensaje claro**. Acción: aviso explícito en `build.sh` cuando cae al fallback, y una comprobación en la UI de Configuración que diga *"esta compilación está firmada ad-hoc; la grabación de pantalla puede no funcionar"*.

---

## 5. Fases de entrega

Ordenadas por disfrute pronto ÷ esfuerzo. Cada fase termina en una app compilada e **instalada localmente** para probar; release solo al final y bajo pedido.

---

### Fase 1 — Importación de documentos, texto (0,5–1 día) · *la victoria rápida*

`.rtf` + `.docx`. Sin permisos, sin red, sin riesgo, y resuelve el 80 % de "tengo el discurso en Word".

- `Sources/Core/ImportersDocs.swift` (rtf + docx), tres casos nuevos en el `switch` de `Importers.swift:9`, UTIs en el `NSOpenPanel`.
- `--test-doc <archivo>` en `main.swift`, siguiendo el precedente de `--test-pptx`.

**Hecho cuando:**
- `--test-doc informe.docx` imprime el guion con `#`/`##`/`- ` derivados de `w:pStyle`, `w:outlineLvl` y `w:numPr`, y las entidades numéricas (`&#233;`) salen bien.
- Un `.rtf` de TextEdit importa con títulos; uno exportado de Word degrada a texto plano sin romperse.
- `--selftest` sigue en `SELFTEST OK` con casos nuevos de `TextReflow`.
- Un `.docx` bomba (476 KB → 206 MB, ratio 433:1) se **rechaza antes de extraer** por el tope de `unzip -l`; el legítimo pasa. Los ataques XXE y "billion laughs" devuelven 0 caracteres.
- **C1** limpio: ninguna consulta de TCC nueva.

---

### Fase 2 — Grabación de cámara (3–4 días) · *lo que Alberto va a usar el primer día*

- `RecordingCoordinator` + `CameraRecorder` + `RecordingLibrary` + `CameraPreviewWindow` + `RecordingSettingsView` + `RecordingsView`.
- `com.apple.security.device.camera` en el entitlements; `NSCameraUsageDescription` en el `Info.plist`.
- Cuenta atrás 3-2-1, indicador rojo, aserción de energía propia, guarda de disco, manejo de desconexión de Continuity Camera.

**Hecho cuando:**
- Pulsar Grabar produce `~/Movies/BtoPrompter/<sesión>/camara.mov` reproducible en QuickTime, con audio de micrófono y la duración esperada.
- HEVC confirmado por `ffprobe`/`mdls` (leer `outputSettings(for:)`, sobrescribir `AVVideoCodecKey`, volver a fijar — **no** se puede enumerar: `availableVideoCodecTypes` es `API_UNAVAILABLE(macos)`, comprobado con error de compilación).
- Bloquear el iPhone a mitad de grabación deja un archivo **válido** y un aviso, no un truncado silencioso.
- La ventana de preview **no roba el foco** sobre una app a pantalla completa y **no aparece** en una captura de pantalla de prueba.
- **C1**: con `recordingEnabled=false`, `sample` no muestra hilos de AVFoundation y no hay consultas de TCC.
- **C2**: prueba de invisibilidad en verde.
- **C3**: fila {grabación × seguimiento por voz} documentada, con el comportamiento real del reinicio anotado.
- `pmset -g assertions` limpio tras parar y tras un `kill -9`.

---

### Fase 3 — Grabación de pantalla (3–4 días) · *donde está el riesgo, y por eso va temprano*

- `ScreenRecorder` con `SCStream` + `SCRecordingOutput`, detrás de `if #available(macOS 15.0, *)`.
- **`SCContentSharingPicker` como ruta por defecto**; filtro directo como opción con aviso.
- Botón "Probar grabación (1 s)". Audio de sistema con `excludesCurrentProcessAudio`.
- **Refactor de escritor único de `sharingType`** en `AppDelegate` (aunque la Opción 2 aún no exista: es deuda que hay que pagar antes, no después).
- Medición del riesgo abierto: ¿se cuela `AVSpeechSynthesizer` en el audio de pantalla?

**Hecho cuando:**
- `pantalla.mov` grabado y reproducible; el prompter **no aparece** en ningún frame (comprobado extrayendo frames, no a ojo).
- Grabar cámara + pantalla a la vez: uso de CPU medido con `getrusage` y anotado. Referencia: dos grabaciones HEVC simultáneas dieron **0,08 s de CPU en 10,6 s de reloj ≈ 1 % de un núcleo**.
- Respuesta escrita a la pregunta del selector: tras N días de uso, ¿aparece o no entrada nueva en `ScreenCaptureApprovals.plist`? Sea cual sea, se documenta en el manual.
- Respuesta escrita a la pregunta del TTS: se graba con voces de macOS sonando y se **analiza la pista de audio**. Si se cuela, se conmuta a `AVSpeechSynthesizer.write(_:toBufferCallback:)`.
- `grep -rn "sharingType" Sources/` devuelve **una** sola asignación.
- La app **arranca y funciona sin la función** si se compila con `LSMinimumSystemVersion 13.0` en un Mac con macOS 13 (la opción de pantalla simplemente no aparece).

---

### Fase 4 — Importación de PDF con OCR (2–2,5 días)

- `PdfImporter` + `TextReflow` geométrico + `OcrEngine` con progreso, cancelación y tope de páginas.
- Manejo completo de los caminos de error: `PDFDocument(url:)` **puede devolver nil** (corregido respecto al diseño original: reproducido con un HTML de error renombrado a `.pdf` y con un archivo de 0 bytes en `~/Downloads`), `isLocked` con diálogo de contraseña, `allowsCopying`.
- **`isEncrypted` ≠ `isLocked`**: probado un PDF cifrado real que abre y se lee sin contraseña. La condición para pedir clave es `isLocked`.

**Hecho cuando:**
- Un PDF de texto de 564 páginas importa completo en pocos segundos (recorrer las 564 páginas cuesta 1,51 s medidos).
- **La regla de disparo del OCR promedia sobre TODAS las páginas y se aplica página a página.** Caso de prueba obligatorio: el PDOT de 564 páginas cuyas 8 primeras suman 34 caracteres pero cuyo total es 1,1 M — un muestreo de cabecera dispararía OCR sobre 564 páginas (~5 min de CPU) en un documento que ya tenía texto perfecto.
- Un PDF escaneado de 35 páginas se OCRea en ~13 s con confianza ≥0,9 en español, con barra de progreso y botón de cancelar que **funciona de verdad**.
- Pico de RSS medido y anotado (referencia: se estabiliza en 250–350 MB, no es fuga ilimitada — re-verificado con dos documentos).
- El OCR **se niega a arrancar** si el prompter está reproduciendo o `VoiceTracker` tiene el micrófono.
- Los diálogos (contraseña, archivo no válido) salen en la **ventana normal**, nunca en el panel no activante.

---

### Fase 5 — Composición PiP offline + pulido de la biblioteca (2 días)

- `RecordingComposer`, botón "Componer PiP" en `RecordingsView`, borrado siempre a la papelera.

**Hecho cuando:** de una sesión con dos archivos sale un `compuesto.mov` con la cámara sobre la pantalla, sincronizado usando el delta de `sesion.json`, sin tocar los originales; y "Mover a la papelera" deja el archivo **recuperable en Finder**.

---

### Fase 6 — Prompter dentro de MI vídeo, sin fuga (4–5 días) · *la joya diferenciadora*

Migración de la ruta de pantalla a `AVAssetWriter` con los buffers `.screen`, y overlay del prompter con `cacheDisplay(in:to:)`. Como regalo, este mismo refactor **resuelve de raíz** el conflicto del micrófono (una sola apertura, alimentando un `AVAssetWriterInput`) y **desbloquea el control de bitrate** que `SCRecordingOutput` no expone.

**Hecho cuando:** `pantalla.mov` contiene el prompter **y** una captura simultánea desde otra app (o desde el propio arnés C2) demuestra que el prompter **sigue invisible** para ella. Y el seguimiento por voz **ya no se reinicia** al pulsar Grabar.

---

### Fase 7 — Espejo remoto del guion + 5 modos de vista (5–7 días) **[PARCIAL]**

Va la última no porque valga poco, sino porque es la única área **sin verificación independiente** y con el documento de investigación truncado. Antes de codear hay que rehacer la pasada de verificación sobre `RemoteControl.swift` y sobre la parte de "solo remota" que llegó incompleta.

- SSE sobre las `NWConnection` existentes; `GET /script` (24 KB para 3.000 palabras, una vez) + `GET /live` (38 bytes por evento).
- Karaoke en el móvil actualizando **solo el rango `[índiceViejo, índiceNuevo]`** — O(delta), no O(n) — y desplazando **por chunk**, igual que hace `PrompterView` con `proxy.scrollTo(currentChunkID, anchor: .center)`. Desplazar por palabra a 6 Hz produce temblor.
- Modo oscuro forzado, tamaño de letra en `localStorage`, `env(safe-area-inset-*)`, y **espejado horizontal** con `transform: scaleX(-1)` — tres líneas de CSS que tachan una línea entera del backlog del README.
- "Solo remota": `window.setIsVisible(false)` (**nunca** cerrar la ventana ni `orderOut` a ciegas), `NSApp.setActivationPolicy(.accessory)`, aserción `NoIdleSleep`, y **cuatro puertas de vuelta**: botón en el móvil (`/cmd?do=show` ya existe), atajo global Carbon (funciona sin foco, a nivel de proceso), ítem de barra de menús (**apagado por defecto**: la barra de menús SÍ sale en pantalla compartida) y — la más importante — **vuelta automática a vista normal si el servidor cae o el Wi-Fi se corta**.

**Hecho cuando:**
- El guion aparece en el iPhone y el karaoke va sincronizado con el Mac, con retardo imperceptible en LAN.
- Bloquear y desbloquear el teléfono hace que el espejo **salte a la palabra correcta**, no que retome desde un índice viejo (`visibilitychange` → cerrar, reabrir, pedir `/status`).
- `main.sync` **eliminado** de la cola de red (`RemoteControl.swift:154`).
- Matar el servidor estando en "solo remota" devuelve la vista al Mac en menos de 15 s, sin intervención.
- Cuatro pestañas del navegador abiertas no ahogan al listener (tope de streams con expulsión del más viejo).
- **Advertencia honesta que hay que dar a Alberto:** `navigator.wakeLock` **no va a funcionar** con `http://192.168.x.x:8737`. La API está soportada en Safari iOS desde 16.4, pero exige *secure context*, y la especificación W3C solo considera confiables `127.0.0.0/8`, `::1/128` y `localhost` — una IP de LAN no lo es, y un nombre `.local` tampoco. El plan es: detectar y usarla si algún día hay HTTPS; fallback de vídeo mudo tipo NoSleep.js arrancado desde el primer toque (*best effort*, con reportes abiertos en iOS); y **siempre** una línea en la página: *"Ajustes → Pantalla y brillo → Bloqueo automático → Nunca"*, que es el único camino 100 % fiable y cuesta cero.

---

### Fase 8 — iWork y extras (0,5–1 día, opcional)

`.pages`/`.key` por AppleScript. Verificado en los `sdef` instalados: Pages exporta a *Unformatted Text / Microsoft Word / EPUB / PDF*; **Keynote expone `presenter notes` (rich text) y `slide number` por diapositiva** — que es literalmente lo que quiere un teleprompter. Reutiliza el `automation.apple-events` que ya está por `SlideSync`; Pages sería un consentimiento TCC nuevo, por eso va apagado.

**Hecho cuando:** un `.key` importa sus notas del presentador como guion, y un archivo `.key` que en realidad es **una clave privada TLS** (en este Mac los 8 encontrados lo son) se rechaza por **contenido** —magia ZIP `PK\x03\x04` / presencia de `Index.zip`—, jamás por extensión, y **nunca se pasa a Keynote**.

---

## 6. Lo que NO se debe hacer

| No hacer | Por qué |
|---|---|
| **`com.apple.developer.persistent-content-capture`** | Es exclusivo de apps tipo VNC, exige solicitud aprobada por Apple **y** perfil de aprovisionamiento, es decir, Apple Developer Program de pago. Rompería la firma local. La alerta periódica se ataca con `SCContentSharingPicker`, no con esto. |
| **`NSOfficeOpenXMLTextDocumentType` para leer `.docx`** | Tienta porque es una línea y sigue vivo sin deprecar (`NSAttributedString.h:268`). Pero devuelve `Converted=-1` y **aplana la estructura**: reproducido, un `.docx` con `Heading1/2/3` salió **todo** en 12,0 Times-Roman. Sin jerarquía, el guion importado es un bloque plano y la función pierde su sentido. |
| **Composición de vídeo PiP en vivo** | Cuesta CPU real, arriesga frames perdidos, y si algo falla se pierde **todo**. Dos archivos separados dan máxima calidad en ambos, coste de composición cero, edición posterior y aislamiento de fallos. El PiP es un paso offline de 30 segundos. |
| **Quitar cabeceras y pies por coincidencia de texto** | Reproducido: en un PDF a dos columnas **borró líneas de cuerpo legítimas** porque se repetían. Solo filtrado **posicional** (bandas del 7 %) más repetición entre páginas distintas. |
| **Detección de títulos por forma del texto (mayúsculas, numeración)** | Reproducido: convirtió en `##` el membrete de un oficio y una cita en mayúsculas a mitad de párrafo. La señal buena es geométrica. Y aun así, la casilla nace apagada. |
| **Disparar el OCR muestreando las primeras páginas** | El PDOT de 564 páginas con 34 caracteres en las 8 primeras y 1,1 M en total. Sería 5 minutos de CPU y cientos de MB en un documento que ya tenía texto. |
| **`RecognizeDocumentsRequest` como sustituto silencioso del OCR** | Existe (`@available(macOS 26.0)`) y es mejor en agrupación (22 párrafos vs 31 líneas sueltas, y algo más rápida), pero en la misma página devolvió `lists=0` habiendo viñetas y erró OCR ("T7"→"17"). El piso de la app es macOS 13. Va detrás de **su propia casilla** o no va: dos Macs no pueden dar guiones distintos del mismo PDF sin que el usuario lo haya pedido. |
| **`RecognizeTextRequest` (API Swift de macOS 15) "porque es más moderna"** | Medido: **mismo consumo de memoria y 27 % más lenta** que `VNRecognizeTextRequest` rev3 (17,0 s vs 13,4 s). No compensa. |
| **Polling de 200 ms para el espejo remoto** | 5 req/s = 18.000 conexiones/hora, y el servidor actual responde `Connection: close` (`RemoteControl.swift:206`) → TCP nuevo cada vez. Añade 0–200 ms de jitter sobre una palabra que a 400 ppm dura 150 ms: karaoke a saltos, visible. Apple lo dice en su guía de eficiencia energética: mantener las radios encendidas a ratos es lo que gasta. |
| **WebSocket a mano** | Verificado que **se puede** sin dependencias: `Insecure.SHA1` de CryptoKit devuelve exactamente el valor canónico del RFC 6455. Pero después vienen ~300 líneas de máquina de estados (framing, desenmascarado obligatorio cliente→servidor, fragmentación, ping/pong, cierre) para un canal que es 99 % unidireccional. SSE es una línea en el cliente y tiene reconexión incorporada. |
| **Cerrar o `orderOut` la ventana en modo solo-remota** | El motor, los atajos, el monitor de teclado, `VoiceTracker`, la aserción de energía y el layout mini asumen que el panel existe. `setIsVisible(false)` y punto. |
| **Ítem de barra de menús encendido por defecto** | La barra de menús **sí** sale en una pantalla compartida a pantalla completa. Encenderlo por defecto contradice la razón de ser del producto. |
| **Añadir `com.apple.security.app-sandbox`** | Rompería el `Process(/usr/bin/unzip)` del importador de `.pptx` que ya funciona. |
| **Formato JSON por palabra para el espejo** | Multiplica el tamaño por 4,6 (78,9 KB vs 17,0 KB de texto plano para 3.000 palabras). Se manda por chunks reutilizando la salida de `ScriptParser.parse()`: una sola fuente de verdad, sin re-parsear en JS. |
| **`.doc` antiguo y `.odt`** | Los conversores existen, pero dan **texto plano sin estructura**, igual que el de OOXML. Bajo valor, superficie nueva. Si alguien lo pide, que exporte a `.docx`. |
| **Avatar, cámara virtual, o "quemar" el prompter en la cámara** | Fuera de alcance. La cámara virtual exige extensión de sistema y firma con Team ID. El README ya lo lista como "módulo independiente", y ahí debe quedarse. |

---

## 7. Comparativa con la competencia

> **[VERIFICADO PARCIALMENTE, agosto 2026]** Los precios y funciones de abajo vienen de una búsqueda hecha hoy, pero **varias de las fuentes son comparativas escritas por los propios fabricantes** (CueNotch, Tellie, VoicePrompter, CursorClip, Screenforge y Screen Charm publican rankings donde ellos aparecen). Los precios de Screen Studio incluso **se contradicen entre fuentes** ($20/mes vs $29/mes). Trátalo como orientación de posicionamiento, no como hoja de precios.

### El mapa

**Categoría 1 — Teleprompters clásicos con grabación integrada.** Teleprompter App (Setapp), Teleprompter Pro (compatible con Elgato Prompter, 4,8 con 180 K+ valoraciones), PromptSmart Pro (con su `VoiceTrack` patentado), Riverside (plataforma de grabación con prompter dentro, hasta 8 participantes remotos). Precios desde ~$34,99/año hasta suscripciones de $7,49–$70/mes.

**Categoría 2 — Teleprompters de "notch", el segmento nuevo y barato.** CueNotch, Moody ($29 o $59 de pago único según la fuente), Notchie, NotchPrompter (**gratis y open source**), Textream, Tellie (gratis con Pro a $29 único, que añade seguimiento por voz), ShareSpeak, VoicePrompter. **Casi ninguno graba.** Varios anuncian explícitamente que el prompter queda oculto en pantalla compartida.

**Categoría 3 — Grabadores de pantalla, el vecino al que nos acercamos.** Screen Studio (pasó a suscripción, ~$20–29/mes o ~$9/mes anual; las licencias perpetuas de $89 ya no se venden), Loom ($18/usuario/mes, gratis hasta 5 min/25 vídeos), Descript ($24/mes). **Ninguna de las tres confirma tener teleprompter.**

### Qué copiar

- **La grabación integrada** (categoría 1): es la razón de que este plan exista. Sin ella, BtoPrompter obliga a montar OBS al lado.
- **El espejado horizontal como interruptor de primer nivel**, no enterrado en preferencias ni exigiendo reiniciar: es imprescindible con un divisor de haz y varias comparativas lo señalan como fallo recurrente.
- **La cuenta atrás y el indicador de grabación**: son estándar de categoría, y su ausencia se nota.
- **La biblioteca de tomas navegable**, no un cajón de archivos sueltos.
- **Pago único / gratis** como posicionamiento. Es el punto donde toda la categoría 2 gana: sobre cinco años, una compra de $12,50–$59 le saca entre 8 y 50 veces al plan de suscripción más barato. BtoPrompter es **MIT y gratis**: no hay que competir, hay que decirlo.

### Qué ignorar

- **La nube y las cuentas.** Loom, Riverside y Descript se apoyan en subir todo. BtoPrompter no debe tener servidor, ni cuenta, ni sincronización. La privacidad local ya es una promesa escrita en el README y sostenida por el código.
- **El editor de vídeo completo** (Descript, Screen Studio). Es un producto distinto, con un coste de mantenimiento que no se paga con un teleprompter.
- **El auto-zoom sobre el cursor** de Screen Studio. Precioso, irrelevante para leer un discurso.
- **Los subtítulos automáticos y la "edición con IA"** de las plataformas grandes. Ya hay `SessionAnalyzer` y el Ensayo IA, que atacan un problema mejor: **hablar mejor**, no editar mejor.
- **El hardware.** Rigs de $200–$2.000 y el Elgato Prompter a $299. BtoPrompter tiene que ser compatible con espejo (`scaleX(-1)`), no vender vidrio.

### Las ideas diferenciadoras (donde nadie más está)

1. **Invisible al compartir pantalla + grabación de esa misma pantalla, a la vez.** La categoría 2 es invisible pero no graba. La categoría 1 graba pero es una ventana normal. BtoPrompter puede grabar la pantalla **con el prompter fuera del vídeo por defecto** y —fase 6— **dentro del vídeo del autor sin filtrarse jamás a Zoom**. Eso, hasta donde alcanza esta búsqueda, no lo hace nadie.
2. **Seguimiento por voz multi-proveedor con failover.** PromptSmart tiene VoiceTrack patentado y cerrado. BtoPrompter tiene ocho proveedores, incluido Apple local, con caída ordenada entre ellos. Es más honesto y más resistente.
3. **Diagnóstico local con alineación palabra↔segundo + perfil del orador.** Nadie de esta lista mide *cómo hablaste* frente a *lo que escribiste*. Con la grabación de vídeo, ese análisis pasa de gráfico a evidencia audiovisual: "aquí te aceleraste" con el frame al lado.
4. **Control remoto del ordenador completo desde el teléfono**, no solo del prompter: teclas, clics, trackpad y teclado por `CGEvent`. Ningún teleprompter de la lista lo hace.
5. **Open source, MIT, sin cuenta, sin nube, sin suscripción**, en una categoría donde hasta las apps de notch cobran $29 y las de escritorio pasaron a $20/mes.

---

## 8. Preguntas abiertas para Alberto

Ordenadas por cuánto código condicionan.

### A. Grabación — impacto alto

1. **¿El prompter dentro del vídeo con la Opción A (flip de `sharingType`, 1 día, pero mientras grabas Zoom también lo ve) o con la Opción B (composición propia con `AVAssetWriter`, 4–5 días, nunca se filtra)?** Es la decisión que más código condiciona de todo el plan. Mi recomendación: **B, en la fase 6**, y ninguna A por el camino.
2. **¿Grabar y seguir por voz a la vez son modos que deben convivir, o pueden ser excluyentes?** Si deben convivir de verdad, hay que ir directo a `AVAssetWriter` en la fase 2 (+2 días) en vez de esperar a la fase 6.
3. **¿Dos archivos separados te sirven, o quieres el PiP ya compuesto?** Y si lo quieres compuesto, ¿aceptas que sea un paso de 30 segundos al terminar en vez de en vivo?
4. **¿Qué hacer si el disco se llena a mitad de una grabación larga: cortar limpio y avisar, o partir en tramos?**
5. **¿Botón de grabar en el control remoto del teléfono?** Es barato y aditivo, pero enciende la cámara: ¿el token en la URL te parece suficiente autorización para eso, o quieres una confirmación en el Mac?
6. **¿Mantener el `.caf` de audio del Diagnóstico cuando la grabación de vídeo está activa, o reutilizar el audio del vídeo?** (Mi propuesta por defecto: reutilizar.)

### B. Importación — impacto medio

7. **Tablas en `.docx`:** hoy cada celda sale como una viñeta suelta, que en una tabla de datos es ruido puro ("Concepto / Valor / Nota / USD 6.000", cada uno en su línea). ¿Unir las celdas de la fila con `·`, omitir las tablas, o dejarlo configurable?
8. **Detección de títulos:** ¿encendida o apagada por defecto? Mi recomendación es **apagada** y con vista previa antes de guardar, dado el índice de falsos positivos medido.
9. **OCR:** ¿que salte solo cuando la página no tiene capa de texto, o que pregunte antes? ¿Y qué tope de páginas por defecto? (Con 0,38–0,54 s/página y pico de 250–350 MB, **50 páginas** parece un techo prudente.)
10. **PDFs largos** (hay de 564 y 287 páginas en tu Descargas): ¿importar todo o pedir un rango de páginas?
11. **¿Un PDF con `allowsCopying = false`: rechazar la importación o extraer igual?** Es decisión de política, no técnica.
12. **¿`RecognizeDocumentsRequest` de macOS 26 como casilla propia, o lo dejamos fuera** para que dos Macs nunca den un guion distinto del mismo archivo?
13. **¿Entra iWork en esta tanda?** Añade un consentimiento TCC (Pages) y depende de que las apps estén instaladas.
14. **¿Aplicar el reflow también a los `.txt`/`.md` con saltos duros a 72 columnas,** o eso rompería guiones que escribiste a propósito con un salto por frase?

### C. Vistas y espejo remoto — impacto medio, información incompleta

15. **¿Confirmas que el espejo remoto va después de la grabación?** Es el área con la investigación más floja y merece una pasada de verificación propia antes de tocar código.
16. **¿"Solo remota" tiene que salir también del Dock y de ⌘-Tab** (`activationPolicy = .accessory`), o prefieres poder volver por ⌘-Tab aunque eso deje rastro?
17. **¿Aceptas el ítem de barra de menús como puerta de vuelta, sabiendo que la barra de menús sí sale en pantalla compartida?** Por defecto iría apagado.
18. **¿Cuántos segundos de red caída antes de que "solo remota" te devuelva la vista al Mac automáticamente?** (Propuesta: 10 s.)

### D. Transversales

19. **¿Vale la pena montar HTTPS local con certificado propio** para desbloquear `navigator.wakeLock` de verdad en el teléfono, o nos conformamos con el fallback de vídeo mudo más el aviso de "Bloqueo automático → Nunca"?
20. **¿Añadimos el aviso en `build.sh` cuando cae a firma ad-hoc**, y una comprobación visible en Configuración? (Yo diría que sí: sin eso, cualquiera que clone el repo tendrá la grabación de pantalla rota **sin ningún mensaje**.)

---

## Apéndice — Cosas que NO se pudieron verificar

Listadas aparte para que no se pierdan entre lo confirmado.

| # | Afirmación sin verificar | Cómo se cierra |
|---|---|---|
| 1 | **¿`SCContentSharingPicker` suprime realmente la alerta periódica en una app autofirmada sin Team ID?** La guía de Apple y el texto de la alerta lo implican; no hay documento tajante. | Fase 3: build real, uso durante >30 días, mirar si aparece entrada nueva en `ScreenCaptureApprovals.plist`. |
| 2 | **¿`AVSpeechSynthesizer` se cuela en el audio de pantalla pese a `excludesCurrentProcessAudio`?** Es muy probable que sí (lo renderiza el demonio del sistema, fuera del proceso), pero **no se comprobó**. Es la incógnita que más puede ensuciar el producto final. | Fase 3: grabar con voces de macOS sonando y analizar la pista. |
| 3 | **Cuatro de los cinco ángulos empíricos de la grabación** (frame extraído de un MP4 real, filtro de ventana única devolviendo negro, conmutación en caliente frame-accurate, conteo de buffers mic vs sistema, 1 % de CPU con dos grabaciones HEVC) vienen de la primera pasada y **no se re-ejecutaron**; los fuentes existen pero no quedaron artefactos. Solo el ángulo del screenshot fue confirmado de forma independiente, y coincidió exactamente. | Fases 2 y 3: se re-miden como criterio de "hecho". |
| 4 | **`setOutputSettings` con HEVC en `AVCaptureMovieFileOutput` en macOS.** Las cabeceras no dejan enumerar códecs (`availableVideoCodecTypes` es `API_UNAVAILABLE(macos)`, comprobado con error de compilación), así que hay que leer `outputSettings(for:)`, sobrescribir la clave y volver a fijarla. No se probó con una cámara real para no lanzar el diálogo de permiso sin permiso. | Fase 2, primer día. |
| 5 | **Toda el área de vistas y espejo remoto.** Llegó sin pasada de verificación independiente y con el documento **truncado** en el apartado (d) "modo solo remota". Los números de tamaño de payload, latencia y consumo son del diseño original, no re-medidos. | Pasada de verificación propia antes de la fase 7. |
| 6 | **Orden de lectura de PDFs a dos columnas de imprenta real.** Solo se probó con un PDF generado por el prototipo, donde salió bien. PDFKit sigue el flujo de contenido, no el visual; no está garantizado. Plan B: agrupar líneas por conglomerado de `x` antes de ordenar por `y`. | Prueba con un PDF real de dos columnas en la fase 4. |
| 7 | **`XMLParser` sobre un `.docx` patológico** (muchas etiquetas, entidades anidadas). `extractPPTX` ya sufrió un DoS cuadrático documentado en su propio comentario. | Caso de estrés en `SelfTest` durante la fase 1. |
| 8 | **Tamaños reales de vídeo con el contenido típico de Alberto** (diapositivas con vídeo, scroll de código). El rango medido, 2,7–53 MB/min, es demasiado ancho para presupuestar. | Fase 3, con material real. |
| 9 | **Precios y funciones de la competencia (§7).** Búsqueda de hoy, pero varias fuentes son comparativas escritas por fabricantes rivales y los precios de Screen Studio se contradicen entre sí. | Verificar en las páginas oficiales solo si alguna vez condiciona una decisión de producto. |

Fuentes de la comparativa competitiva: [Setapp — mejores teleprompters](https://setapp.com/app-reviews/best-teleprompter-apps) · [ShareSpeak — comparativa de precios 2026](https://sharespeak.co/teleprompter-pricing-comparison) · [Riverside — teleprompters para Mac](https://riverside.com/blog/best-teleprompter-apps-for-mac) · [CursorClip — grabadores de pantalla para Mac 2026](https://cursorclip.com/blog/13-top-screen-recording-mac-apps/) · [ngram — alternativas a Screen Studio](https://www.ngram.com/blog/screen-studio-alternatives-price-hike) · [Docsie — Screen Studio vs Loom](https://www.docsie.io/vs/screen-studio-vs-loom/)

Documentación oficial de Apple citada a lo largo del plan: [SCRecordingOutput](https://developer.apple.com/documentation/screencapturekit/screcordingoutput) · [Capturing screen content in macOS](https://developer.apple.com/documentation/ScreenCaptureKit/capturing-screen-content-in-macos) · [com.apple.security.device.camera](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.camera) · [persistent-content-capture](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture) · [NSWindow.sharingType](https://developer.apple.com/documentation/appkit/nswindow/sharingtype) · [AVCaptureMovieFileOutput](https://developer.apple.com/documentation/avfoundation/avcapturemoviefileoutput) · [CGRequestScreenCaptureAccess](https://developer.apple.com/documentation/coregraphics/cgrequestscreencaptureaccess()) · [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime) · [PDFDocument](https://developer.apple.com/documentation/pdfkit/pdfdocument) · [VNRecognizeTextRequest](https://developer.apple.com/documentation/vision/vnrecognizetextrequest) · [RecognizeDocumentsRequest](https://developer.apple.com/documentation/vision/recognizedocumentsrequest) · [XMLParser](https://developer.apple.com/documentation/foundation/xmlparser)
---

## Apéndice B — Decisiones cerradas por el autor (1 de agosto de 2026)

Estas respuestas fijan el diseño. Las preguntas correspondientes de la sección 8
quedan resueltas y no se vuelven a plantear.

| Tema | Decisión |
|---|---|
| El prompter en la grabación de pantalla | **Nunca aparece.** Se descarta la Opción A (invertir la invisibilidad) y también la Opción B (componer el prompter dentro del vídeo). El vídeo queda limpio. |
| Modos de grabación | **Tres, a elección:** solo cámara (con vista previa para verse), solo pantalla, o ambas a la vez. |
| Archivos | **Siempre separados**, uno por fuente, lo más sincronizados posible. El editor permitirá desplazar uno respecto al otro si hiciera falta. |
| Grabar mientras se sigue por voz | **Deben convivir.** Es el caso de uso principal: leer con el prompter mientras se graba. No son modos excluyentes. |
| Formato de salida | **Horizontal.** Vertical queda planificado para más adelante, sin prioridad. |
| Conservación de los vídeos | **Nunca se borran solos.** Viven en `~/Movies/BtoPrompter/`, accesible desde el Finder sin abrir la app, y también se pueden borrar desde la app. |
| PDFs largos | **Se importan enteros**, sin pedir rango. Solo un aviso cuando vaya a tardar. |
| Botón de grabar en el remoto | **Requiere confirmación en el Mac.** El código de la URL no basta para encender la cámara. |
| Capítulos automáticos desde el guion | Idea propuesta por el desarrollo, no pedida. Queda al final de la cola y solo si aporta valor real. |
| Control sin Wi-Fi | Ambas rutas quedan **planificadas sin implementar**: punto de acceso del iPhone (sin desarrollo) y app iOS con Bluetooth (exige cuenta de pago). |
