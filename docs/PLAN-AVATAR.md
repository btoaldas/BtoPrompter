# Plan de implementación — Avatar digital de Alberto en BtoPrompter

**Fecha:** 1 de agosto de 2026 · **Repo:** `<repo>` · **Estado del repo:** 38 archivos Swift, ~7.300 líneas, 4 capas (`App` / `Core` / `Storage` / `UI`), compilación con `swiftc` desde `build.sh`, firma ad-hoc.

---

## 0. Resumen ejecutivo en 10 líneas

1. **No hay hoy ninguna opción, ni de nube ni local, que cumpla los cinco requisitos duros a la vez.** El que más duele es el 4 ("a más recursos, mejor resultado"): HeyGen, Tavus, D-ID, Beyond Presence y Simli tienen **techo fijo** — piden entre 1 foto y 5 minutos de video y no aceptan más material para mejorar la fidelidad.
2. La ruta que **sí** escala con recursos y **sí** deja los datos en su Mac es la local, y es más trabajo.
3. La jugada de mayor realismo por unidad de esfuerzo no es "generar un humano": es **re-sincronizar los labios sobre video real de Alberto**. Cabeza, pelo, piel, iluminación y fondo son literalmente él, grabado por él. Solo se regenera la boca. Es lo más cerca de "idéntico" que se puede llegar en 2026, y de paso es lo más barato y lo más honesto.
4. **Recomendación principal (nube, máxima fidelidad, tiempo real):** HeyGen LiveAvatar en **modo LITE** con la voz clonada de ElevenLabs de Alberto (~$0,099/min con plan Pro).
5. **Recomendación alternativa (100 % local):** motor propio de re-labializado sobre metraje real, tipo MuseTalk (inpainting latente de un paso, no difusión) corriendo en el Apple Silicon, con ruta de escalado a modelo person-specific 3DGS entrenado en GPU alquilada.
6. Ambas rutas se seleccionan **por parámetro**, con el mismo patrón que ya usan STT y TTS: enum de proveedor + API key en `secrets.json` + modelo elegible + consentimiento **por proveedor**.
7. La salida a Zoom/Teams/Meet: **MVP con OBS Virtual Camera + BlackHole (cero firma, cero riesgo)**, y cámara virtual propia (`CMIOExtension`) solo en una fase posterior, porque obliga a abandonar la firma ad-hoc y pagar el Apple Developer Program.
8. La función arranca **desactivada por defecto** y vive en una pestaña "Avanzadas", como se hizo en BtoStats.
9. Ninguna cara, ningún video y ninguna clave entra jamás al repo.
10. Divulgación de IA: obligatoria en el flujo, no opcional, y en algunas plataformas es forzada por el proveedor (Anam pone un sufijo `(AI)` que no se puede quitar).

---

## 1. Recomendación principal y ruta alternativa

### 1.A — Ruta NUBE de máxima fidelidad en tiempo real: **HeyGen LiveAvatar, modo LITE**

**Por qué esta y no otra:**

- Es la única de las verificadas donde la doc oficial dice explícitamente que, para idiomas o acentos que no cubre de fábrica, se usa **modo LITE con tu propio ASR y tu propio TTS** ([FAQ LiveAvatar](https://help.heygen.com/en/articles/12758866-liveavatar-faq), [docs.liveavatar.com](https://docs.liveavatar.com/)). Eso significa que el **acento ecuatoriano de Alberto no depende del catálogo de HeyGen**: entra su clon de ElevenLabs y HeyGen solo renderiza labios y cara sobre ese audio.
- Precio confirmado en fuente primaria: plan **Pro $99/mes = 1.000 créditos**, LITE consume **1 crédito/minuto** → **$0,099/min (~$6/hora)** ([docs.liveavatar.com/docs/faq/credits](https://docs.liveavatar.com/docs/faq/credits)).
- **Sandbox Mode** permite probar el pipeline completo **sin consumir créditos**. Se valida antes de pagar un centavo.
- En modo teleprompter no hay conversación: hay un guion. Toda la capa cara (STT + LLM + turn-taking) sobra, y LITE es exactamente eso.

**Alternativas de nube, en orden, y cuándo usar cada una:**

| Proveedor | Cuándo tiene sentido | Coste real verificado | Pega principal |
|---|---|---|---|
| **HeyGen LiveAvatar LITE** | Recomendado. Tiempo real + BYO voz | $0,099/min (Pro $99) | Precio del slot de avatar custom **no publicado**; inconsistencia de nombre de plan ("Essential" vs Starter/Pro/Scale) sin resolver |
| **Tavus (Phoenix-4)** | Si se quiere la mejor conducta facial y `background_green_screen` para componer sobre fondo propio | Starter $59/mes, overage $0,37/min, **$65 por reentrenamiento** | Réplica se entrena con ~1 min fijo; latencia "sub-600 ms" es marketing sin respaldo |
| **D-ID (Agents Streams V2 / LiveKit)** | Si pesa tener **SDK Swift nativo** (LiveKit `client-sdk-swift` soporta macOS) y **BYO ElevenLabs** vía `x-api-key-external` | Build $18/mes → ~$0,56/min streaming | Resolución tope 1280×1280 (no 4K); bolsa de créditos compartida con Studio y redondeo a 15 s; **sin verificar que un avatar propio sirva en vivo** |
| **Beyond Presence** | Si pesa RGPD/EU y proveedor europeo | €49–€349/mes, overage €0,0875–0,175/min | Avatar custom puede exigir email a soporte, no autoservicio; el "unirse a Zoom" del plan Scale **no está documentado** |
| **Simli (Trinity)** | **Banco de pruebas barato** del puente cámara virtual | $10/mes, **$0,009–0,01/min** | Clona desde **una sola foto**; resolución no publicada; su política dice que usa el contenido del usuario **para entrenar sus modelos** |

**Regla dura de la ruta nube:** la cara y la voz de Alberto viven en servidores de terceros. HeyGen puede usar el material para mejorar sus modelos salvo que se **rechace explícitamente el consentimiento** ([aviso biométrico](https://www.heygen.com/biometric-privacy-notice)); Tavus declara uso para "anonymized training data"; Simli lo dice sin rodeos. Antes de subir un solo frame hay que declinar por escrito.

### 1.B — Ruta 100 % LOCAL: **re-labializado sobre metraje real (`local_retalk`)**

Concepto: Alberto graba **un video base** suyo (bucle idle de 60–120 s, encuadre fijo, mirando a cámara, micro-gestos naturales, respirando). En vivo, el motor toma el audio (su voz real por micrófono, o su clon TTS leyendo el guion) y **regenera únicamente la región de la boca/mandíbula** dentro de ese metraje real, frame a frame.

**Por qué esto gana en el requisito "que sea idéntico":** no hay síntesis de identidad. El 90 % de los píxeles son fotograma real de Alberto. Los modelos generativos de nube tienen que *inventar* su cara y por eso caen en el valle inquietante; aquí no hay nada que inventar salvo 40×40 píxeles de boca.

**Motor:** familia **MuseTalk** — inpainting en espacio latente de **un solo paso** (no difusión iterativa), VAE congelado + whisper-tiny para audio, 30+ FPS a 256×256 en V100 ([arXiv 2410.10122](https://arxiv.org/html/2410.10122v2), [TMElyralab/MuseTalk](https://github.com/TMElyralab/MuseTalk)). Corre sobre **PyTorch MPS** en Apple Silicon; hay proyectos que ya lo declaran para Mac, pero **no existe ninguna cifra publicada de FPS en M4 Max** — es lo primero que hay que medir, y es criterio de "hecho" de la Fase 1.

**Escalones locales de más calidad (ver §4):**
- `local_retalk_hd`: misma técnica a 512×512 + super-resolución facial (GFPGAN/CodeFormer) y compositado alfa sobre el frame original.
- `local_3dgs`: modelo **person-specific** tipo **SyncTalk++** / GaussianTalker, entrenado con **minutos de video de Alberto**, hasta 101 FPS de inferencia ([arXiv 2506.14742](https://arxiv.org/abs/2506.14742), [proyecto](https://ziqiaopeng.github.io/synctalk++/)). **Este es el único camino verificado que cumple el requisito 4 de verdad.** Entrenamiento CUDA-céntrico → GPU alquilada; inferencia potencialmente portable, pero **asumir que hará falta una caja Linux/NVIDIA**.
- `local_offline_hq`: para video pregrabado, no en vivo — HunyuanVideo-Avatar (pesos abiertos, [HF tencent/HunyuanVideo-Avatar](https://huggingface.co/tencent/HunyuanVideo-Avatar)) o Hallo3. **Mínimo 24 GB VRAM y "muy lento"; recomendado 96 GB.** No corre en su Mac en tiempo real. Se ejecuta en GPU alquilada, de noche, para piezas grabadas.

### 1.C — El modo que probablemente resuelve el 80 % del caso real

Dos modos de operación, ambos parametrizables:

- **Modo Espejo (`.mirror`) — el que recomiendo como MVP.** Alberto **habla de verdad**; su voz real sale por el micrófono real; el avatar solo pone su cara sincronizada a **su propio audio**. Cero coste de TTS, cero problema de acento, cero riesgo de que "diga" algo que él no dijo. Sirve para el caso real y frecuente: cámara mala, mala luz, no está presentable, ancho de banda pobre, o quiere leer el teleprompter sin que se le note la mirada.
- **Modo Guion (`.script`).** TTS con su voz clonada lee el guion del prompter. Aquí el avatar sí habla solo. Exige divulgación explícita y una confirmación distinta en la UI.

---

## 2. Arquitectura concreta, encajada en las capas actuales

Se respeta la regla existente (`UI` observa `Core`; `Core` usa `Storage`; `Storage` no conoce a nadie; `App` conecta) y el patrón de proveedores ya probado dos veces (`VoiceTypes.swift` para STT, `TTSTypes.swift` para TTS). **El avatar es el tercer catálogo de proveedores, calcado.**

### 2.1 `Sources/Core/` — archivos nuevos

| Archivo | Contenido | Espejo de |
|---|---|---|
| `AvatarTypes.swift` | `enum AvatarProviderID` + contratos + errores + estado | `VoiceTypes.swift` |
| `CloudAvatarProvider.swift` | Adaptadores en vivo: HeyGen LITE, Tavus, D-ID/LiveKit, Beyond Presence, Simli. `validateCredentials(provider:apiKey:completion:)` | `CloudSpeechProvider.swift` |
| `LocalAvatarEngine.swift` | Lanza y habla con el proceso hijo del motor local (venv Python), autodetección de ruta ejecutable, protocolo por socket UNIX | `TTSEngines.swift` (patrón `piperPath` / `autodetectPiper()`) |
| `AvatarSession.swift` | Orquestador: fuente de audio → renderer → sinks. Failover y reintentos | `VoiceTracker.swift` |
| `VideoSink.swift` | Destino de frames: previsualización, ventana limpia para OBS, cámara virtual propia | nuevo |
| `AudioSink.swift` | Enruta el audio a un `AudioDeviceID` elegible (BlackHole) con `AVAudioEngine` | `SpeechPlayback.swift` |
| `AvatarDiagnostics.swift` | Log acotado, retención en días y MB, sin grabar frames por defecto | `VoiceDiagnostics.swift` |

**`AvatarTypes.swift` — la pieza central.** Copia literal del contrato de `VoiceProviderID`, que ya funciona:

```swift
enum AvatarProviderID: String, CaseIterable, Codable, Identifiable {
    case localRetalk    = "local_retalk"       // MuseTalk sobre video real  (LOCAL)
    case local3DGS      = "local_3dgs"         // person-specific entrenado  (LOCAL)
    case localOfflineHQ = "local_offline_hq"   // Hunyuan/Hallo3, no en vivo (LOCAL)
    case heygenLive     = "heygen_live"
    case tavus
    case didAgents      = "did_agents"
    case beyondPresence = "beyond_presence"
    case simli

    var name: String { … }
    var isLocal: Bool { self == .localRetalk || self == .local3DGS || self == .localOfflineHQ }
    var isRealtime: Bool { self != .localOfflineHQ }

    // Idéntico al patrón STT/TTS: clave en secrets.json, nunca en UserDefaults.
    var secretName: String? {         // "avatarKey_heygen", "avatarKey_tavus", …
    var defaultModel: String { … }    // "avatar_iii_live", "phoenix-4", "trinity", "musetalk_v1_5"
    var availableModels: [String] { … }
    var modelSettingKey: String { "avatarModel_\(rawValue)" }

    // Consentimiento POR PROVEEDOR: autorizar uno no autoriza a los demás.
    var consentKey: String { "avatarConsent_\(rawValue)" }
    var hasCloudConsent: Bool { … }
    func setCloudConsent(_ v: Bool) { … }

    var docsURL: URL? { … }
    var privacyNote: String { … }     // texto explícito de qué sale del Mac
    var costNote: String { … }        // NUEVO respecto a STT/TTS: $/min visible en la UI
    var trainingRecipe: TrainingRecipe { … }  // NUEVO: qué material pide y si escala
}

struct TrainingRecipe {
    let minVideoSeconds: Int
    let maxUsefulVideoSeconds: Int?   // nil = escala sin techo (solo rutas locales)
    let minResolution: String
    let needsConsentVideo: Bool
    let scalesWithMoreMaterial: Bool  // false en TODOS los proveedores de nube
    let notes: String
}
```

`scalesWithMoreMaterial` no es decoración: es el campo que la UI usa para decirle a Alberto, en la propia tarjeta del proveedor, *"este proveedor no mejora aunque le des más video"*. Es su requisito 4 hecho dato.

**Protocolos:**

```swift
struct AvatarFrame { let pixelBuffer: CVPixelBuffer; let pts: CMTime }

protocol AvatarRenderer: AnyObject {
    var id: AvatarProviderID { get }
    var onFrame: ((AvatarFrame) -> Void)? { get set }
    var onAudio: ((AVAudioPCMBuffer) -> Void)? { get set }   // nil en modo espejo
    var onError: ((Error) -> Void)? { get set }
    func start(identity: AvatarIdentity, config: AvatarRenderConfig,
               completion: @escaping (Result<Void, Error>) -> Void)
    func push(audio pcm16: Data)          // modo espejo: audio real del micrófono
    func speak(text: String)              // modo guion: el proveedor sintetiza o recibe TTS propio
    func stop()
}

protocol AvatarSinkProtocol: AnyObject {
    func attach() throws
    func write(_ frame: AvatarFrame)
    func detach()
}

enum AvatarState: Equatable { case idle, preparing(AvatarProviderID),
                              live(AvatarProviderID), degraded(String), failed(String) }
```

Nótese que `push(audio:)` acepta exactamente el mismo `pcm16: Data` que ya produce el capturador único de `VoiceTracker.swift`. **No se abre un segundo micrófono**: el audio que ya se captura para el seguimiento por voz alimenta también el labial. Eso es reutilización real, no acoplamiento nuevo.

### 2.2 `Sources/Storage/` — archivos nuevos y cambios

| Archivo | Contenido |
|---|---|
| `AvatarStore.swift` (nuevo) | Biblioteca de **identidades de avatar**, misma mecánica de `SpeechStore.swift` (JSON + escritura atómica + guardado agrupado). Carpeta `~/Library/Application Support/BtoPrompter/Avatars/<uuid>/` con `base.mov`, `poster.jpg`, `meta.json`, `consent.json`. Permisos `0700` en la carpeta, `0600` en `meta.json`. |
| `SecretsStore.swift` (sin cambios) | Ya acepta cualquier nombre de clave: `avatarKey_heygen`, `avatarKey_tavus`, … |
| `Settings.swift` (añadir claves) | ver abajo |

```swift
// Settings.Key — nuevas entradas
case avatarEnabled, avatarMode, avatarProvider, avatarIdentityID
case avatarResolution, avatarFPS, avatarQualityPreset
case avatarSink, avatarAudioDeviceUID
case avatarDisclosure, avatarDisclosureText
case avatarBudgetCapUSD, avatarSpentThisMonthUSD
case avatarLocalEnginePath, avatarLocalSteps, avatarLocalUpscale
```

`AvatarIdentity` (en `Storage`, sin lógica):

```swift
struct AvatarIdentity: Identifiable, Codable {
    let id: UUID
    var name: String                       // "Alberto — oficina, camisa azul"
    var provider: AvatarProviderID
    var remoteAvatarID: String?            // id del avatar en HeyGen/Tavus/D-ID
    var baseVideoRelativePath: String?     // ruta local, NUNCA absoluta en el JSON
    var trainingSeconds: Int
    var captureResolution: String
    var voiceProviderID: String?           // reutiliza TTSProviderID + voiceKey ya existentes
    var consentSignedAt: Date?
    var trainingOptOutConfirmed: Bool      // se declinó el uso del material para entrenar
    var createdAt: Date
}
```

### 2.3 `Sources/UI/` — archivos nuevos

| Archivo | Contenido | Espejo de |
|---|---|---|
| `AvatarSettingsView.swift` | Pestaña "Avatar" dentro de Ajustes → **sección Avanzadas, apagada por defecto**. Selector de modo, proveedor, identidad, resolución, fps, destino de video y de audio, tope de gasto | `TTSSettingsView.swift` |
| `AvatarProviderCard.swift` | Tarjeta por proveedor: consentimiento → API key → modelo → **Probar clave** → nota de privacidad → **nota de coste** → aviso "no mejora con más material" cuando `scalesWithMoreMaterial == false` | `ExternalProviderCard.swift` (calcado) |
| `AvatarStudioView.swift` | Estudio de identidad: checklist de grabación, importar/grabar video base, firmar consentimiento, entrenar/subir, ver progreso y estado | `LocalModelsView.swift` (descarga reanudable) |
| `AvatarStageWindow.swift` | Ventana de escenario del avatar. **Ojo:** `NSWindow` normal con `sharingType = .readWrite` — es lo **contrario** del `PrompterPanel` | nuevo |

**Aviso de arquitectura que no se puede pasar por alto:** el `PrompterPanel` de `AppDelegate.swift` es un `NSPanel` no-activante con `sharingType = .none`, y ARCHITECTURE.md dice explícitamente "No cambiar". El avatar necesita justo lo opuesto: una ventana que **sí** se comparta y **sí** se capture. Son dos ventanas distintas, con dos responsabilidades opuestas. Mezclarlas rompería la invisibilidad, que es la característica insignia de la app.

### 2.4 `Sources/App/` y `build.sh`

- `AppDelegate.swift`: item de menú "Avatar → Iniciar escenario / Detener", atajo global opcional en `GlobalHotKeys.swift`.
- `main.swift`: nuevos flags `--test-avatar` (ping al proveedor configurado, sin render) y `--avatar-bench` (mide FPS y latencia del motor local, imprime tabla y sale). Es el criterio de "hecho" automatizable de varias fases.
- `SelfTest.swift`: pruebas puras del catálogo (que cada proveedor tenga `secretName` coherente, que ningún local exija consentimiento de nube, que `TrainingRecipe` sea consistente).
- `build.sh`: **sin cambios hasta la Fase 4**. En la Fase 4 la firma ad-hoc deja de servir (ver §3).

### 2.5 Actualización de `ARCHITECTURE.md`

Añadir a la tabla "Cómo extender": *"Nuevo proveedor de avatar → `Core/AvatarTypes.swift` (un caso + `TrainingRecipe`) y aparece solo en la UI"*.

---

## 3. Cómo llega el video a Zoom — decisión concreta

### 3.1 Los tres caminos, con el esfuerzo real

**Camino 1 (MVP, recomendado para empezar): reutilizar cámara y micrófono virtuales que ya existen y ya están firmados por otros.**

- Video: `AvatarStageWindow` renderiza a 1280×720 exactos, sin sombra ni bordes → **OBS Studio → Window Capture → Start Virtual Camera** → en Zoom se elige "OBS Virtual Camera".
- Audio: **BlackHole 16ch** ([existentialaudio/BlackHole](https://github.com/ExistentialAudio/BlackHole)) como dispositivo de salida del `AudioSink`; en Zoom el micrófono se pone en "BlackHole". Reportado funcionando en macOS 26.5.
- **Esfuerzo: 1–2 días.** **Firma requerida: ninguna.** Riesgo técnico: casi nulo.
- Coste para Alberto: instalar dos apps gratuitas. Es una dependencia externa declarada, no un defecto.

**Camino 2 (Fase 4): cámara virtual propia con `CMIOExtension`.**

Requisitos reales, verificados en los foros de Apple:

- Entitlement **`com.apple.developer.system-extension.install`** en la app contenedora ([hilo Apple](https://developer.apple.com/forums/thread/793731)).
- La extensión vive en `Contents/Library/SystemExtensions/`, con clave `CMIOExtension` en su Info.plist ([guía de Halle Winkler](https://theoffcuts.org/posts/core-media-io-camera-extensions-part-one/)).
- **Team ID de la extensión y de la app deben coincidir.** La app debe estar en `/Applications`.
- **Adiós a `codesign -s -`**: hace falta **Apple Developer Program ($99/año)**, certificado **Developer ID Application**, perfil de aprovisionamiento con la capacidad System Extension **realmente embebida**, y **notarización**. El fallo típico es `OSSystemExtensionErrorDomain error 8: Code Signature Invalid`, y es un error genérico que cuesta días.
- Para iterar en local: `sudo systemextensionsctl developer on` (se resetea al reiniciar).
- **Bandera roja actual:** hay un reporte de macOS 26.2 / Xcode 26.1 donde la cámara virtual aparece en Zoom y Meet pero los frames tiemblan y se llenan de color sólido, con `Invalid display 0x00000000` en Consola — se sospecha de dibujo `CGContext`/`NSImage` en modo headless. **Mitigación de diseño: no dibujar con AppKit en la extensión; escribir `CVPixelBuffer` directo desde IOSurface.**
- **Esfuerzo real: 2–3 semanas** contando la pelea de firma, más $99/año recurrentes.

**Camino 3 (micrófono virtual propio): no hacerlo.**

- El camino soportado sigue siendo **`AudioServerPlugIn`** (estilo BlackHole), no deprecado. `AudioDriverKit` está orientado a familias de dispositivos **con hardware** y además exige el entitlement `com.apple.developer.driverkit`, que Apple concede caso por caso ([WWDC21 10190](https://developer.apple.com/videos/play/wwdc2021/10190/)).
- Un `.driver` no firmado simplemente **no carga**; hay que firmar con Developer ID, notarizar y grapar el instalador.
- **Escribir un driver de audio propio para no depender de BlackHole no vale la pena.** BlackHole es MIT, gratuito, firmado, mantenido y ya funciona en macOS 26.5. **Decisión: BlackHole como dependencia declarada y detectada automáticamente por la app, con instrucciones de instalación en la UI.** Se ahorra un mes de trabajo y una superficie de fallo permanente.

### 3.2 Decisión

| Fase | Video a Zoom | Audio a Zoom | Firma |
|---|---|---|---|
| 1–3 | OBS Virtual Camera (captura de `AvatarStageWindow`) | BlackHole | ad-hoc, sin cambios |
| 4+ | `CMIOExtension` propia, opcional y seleccionable | BlackHole (siempre) | Developer ID + notarización |

El destino es un **parámetro** (`Settings.avatarSink`): `.previewOnly`, `.obsWindow`, `.virtualCamera`. Nunca se fuerza uno.

### 3.3 Riesgo de plataforma

Zoom, Teams y Meet han bloqueado o degradado cámaras virtuales en el pasado y pueden volver a hacerlo. **Hay que probar en las tres antes de invertir en el Camino 2.** Además, Zoom en macOS puede requerir que el usuario habilite explícitamente cámaras de terceros.

---

## 4. Escalado de calidad — qué palanca da qué

Esta es la sección donde la honestidad importa más, porque **la mitad de las palancas que Alberto espera no existen en la nube**.

### 4.1 Palancas que NO funcionan en la nube (verificado)

| Palanca esperada | HeyGen | Tavus | D-ID | Beyond Presence | Simli |
|---|---|---|---|---|---|
| Más minutos de video de entrenamiento → mejor avatar | **No** (receta fija ~2 min) | **No** (30 s + 30 s) | **No** (≥1 min) | **No** (4–5 min fijos) | **No** (una sola foto) |
| Más audio de entrenamiento → mejor voz | Vía ElevenLabs, no vía ellos | igual | igual | igual | igual |
| Más GPU / más tiempo de cómputo | No expuesto | No expuesto | No expuesto | No expuesto | No expuesto |
| Más resolución | 1080p tope, **4K no soportado** | 4K solo en modo cuerpo entero vertical | **1280×1280 tope** | 1080p @ 35 fps | **no publicada** |

**Traducción:** en la nube, la única palanca real es **la calidad de la grabación de esos 2 minutos** (luz, encuadre, 1080p limpio, fondo estático, sin gafas ni ropa brillante) y **la calidad del TTS que traigas**. Comprar un plan más caro da **más minutos y más concurrencia, no más realismo**.

### 4.2 Palancas que SÍ funcionan (ruta local, y por eso existe la ruta local)

| Palanca | Efecto | Coste | Fase |
|---|---|---|---|
| **Resolución de la región regenerada** 256→512→768 px | Impacto grande y directo en el realismo de dientes y labios | cuadrático en cómputo | 1 → 4 |
| **Super-resolución facial** (GFPGAN/CodeFormer) sobre la región compuesta | Recupera textura de piel y dientes; el mayor salto por euro | +8–20 ms/frame | 4 |
| **FPS del render** 15 → 25 → 30 → 60 | 25 fps es el suelo de credibilidad; 30 es cómodo; más de 30 apenas se nota en Zoom (que recomprime a ~25) | lineal | 1 → 4 |
| **Calidad del video base** (cámara, luz de 3 puntos, fondo, 4K downscaleado a 1080p) | **La palanca más barata y más potente de todas.** Un buen video base vale más que cualquier modelo | tiempo de grabación | 0 |
| **Duración y variedad del video base** (60 s → 5 min con varias poses e intensidades) | En re-labializado permite bucles largos sin repetición perceptible; en 3DGS mejora el modelo de verdad | almacenamiento | 1 y 5 |
| **Entrenamiento person-specific 3DGS** (SyncTalk++/GaussianTalker) con minutos de su video | **El único escalado real de fidelidad con más material.** Hasta 101 FPS de inferencia | GPU alquilada + horas de entrenamiento | 5 |
| **Pasos de muestreo del modelo** | Aplica solo a la ruta de difusión offline (Hunyuan/Hallo3), no a MuseTalk (que es de un paso) | lineal en tiempo | 6 |
| **Voz: IVC → PVC de ElevenLabs** (~30 min de audio limpio) | Salto notable en estabilidad y timbre en lecturas largas; PVC requiere plan **Creator $22/mes o superior** | $22–99/mes | 2 |
| **Bitrate/códec de salida** a la cámara virtual | Evita que el compositado se vea "sucio" antes de que Zoom lo recomprima | nulo | 3 |

`Settings.avatarQualityPreset` expone esto como `.ligero` / `.equilibrado` / `.máximo` con los valores concretos por debajo, y cada preset muestra el FPS medido en **su** Mac, no un número de folleto.

---

## 5. Fases de entrega, con criterio de "hecho" verificable

### Fase 0 — Decisión, consentimiento y material base
**Trabajo:** Alberto responde §8. Se graba el video base con checklist (1080p mínimo, 25+ fps, luz frontal suave, fondo liso, pecho arriba, mirada a cámara, 15 s en silencio + 90 s hablando + 15 s idle). Se graba también el audio de 30 min para PVC si se va por voz clonada. Se firma y archiva el consentimiento propio.
**Hecho cuando:** existe `~/Library/Application Support/BtoPrompter/Avatars/<uuid>/base.mov` con `meta.json` válido, `ffprobe` confirma ≥1080p y ≥25 fps, y `consent.json` tiene fecha y firma. Cero material en el repo (`git status` limpio).

### Fase 1 — MVP: **Espejo local, sin nube, sin firma**
**Trabajo:** `AvatarTypes.swift`, `LocalAvatarEngine.swift` (venv + MuseTalk sobre MPS), `AvatarSession` en modo `.mirror` alimentado por el PCM que ya produce `VoiceTracker`, `AvatarStageWindow`, `AudioSink` a BlackHole, `--avatar-bench`.
**Hecho cuando, todo junto y grabado en video de pantalla:**
1. `BtoPrompter --avatar-bench` imprime ≥ **18 fps sostenidos** y **latencia audio→frame < 400 ms** en su Mac.
2. En una llamada de Zoom real, un tercero ve la cara de Alberto sincronizada con su voz real durante **10 minutos sin caídas ni deriva**.
3. `--selftest` sigue verde y `./build.sh` sigue firmando ad-hoc.
4. **Segundo ángulo de verificación:** repetir en Teams y en Google Meet.

*Si en la Fase 1 el motor local no pasa de ~10 fps en el Mac de Alberto, se para y se escala la decisión: o se compra una caja NVIDIA, o el MVP pasa a ser la ruta nube. Es el único punto donde el plan puede morir por hardware, y hay que descubrirlo en la semana 1, no en el mes 3.*

### Fase 2 — Ruta nube seleccionable por parámetro
**Trabajo:** `CloudAvatarProvider.swift` con HeyGen LiveAvatar LITE + Simli (el barato, para probar el puente) + `AvatarProviderCard.swift` con consentimiento por proveedor, `Probar clave`, coste por minuto visible y tope de gasto mensual duro.
**Hecho cuando:** (a) todo el flujo HeyGen se prueba en **Sandbox Mode con 0 créditos consumidos**; (b) cambiar el proveedor en Ajustes cambia el render sin reiniciar la app; (c) al llegar al tope de gasto la sesión se corta sola y lo dice; (d) con la clave borrada, la app cae a la ruta local sin crashear.

### Fase 3 — Modo Guion + voz clonada + divulgación
**Trabajo:** `.script` conectado al `PrompterModel` (el chunk actual alimenta al TTS ya existente, que ya tiene ElevenLabs), overlay de divulgación configurable, confirmación explícita distinta al entrar en modo guion.
**Hecho cuando:** el avatar lee un discurso de 5 minutos del prompter con su voz clonada, en español de Ecuador, y un oyente que no sabe el guion no detecta cortes entre chunks. El overlay de divulgación aparece en el video que llega a Zoom, no solo en la pantalla local.

### Fase 4 — Cámara virtual propia (opcional, solo si la Fase 1–3 se usa de verdad)
**Trabajo:** Apple Developer Program, target de extensión CMIO, entitlements, `build.sh` con Developer ID + notarización + `xcrun notarytool`, escritura de `CVPixelBuffer` sin AppKit.
**Hecho cuando:** en un Mac **limpio** (usuario distinto o VM), instalar el .app desde `/Applications`, aprobar la extensión, y que "BtoPrompter Camera" aparezca y funcione en Zoom, Teams y Meet durante 10 minutos sin el artefacto de color sólido de macOS 26.2.

### Fase 5 — Escalado real de calidad (el requisito 4, en serio)
**Trabajo:** 512 px + super-resolución facial; entrenamiento person-specific 3DGS (SyncTalk++/GaussianTalker) con 5–15 min de video de Alberto en GPU alquilada; empaquetado del modelo entrenado como una `AvatarIdentity` más.
**Hecho cuando:** comparativa ciega A/B/C (nube HeyGen vs. re-labializado vs. 3DGS entrenado) juzgada por 5 personas que conocen a Alberto, con resultados anotados. **Si el 3DGS no gana claramente, se documenta y se descarta** — no se mantiene código que no gana.

### Fase 6 — Endurecimiento y cierre
Diagnóstico acotado, contador de gasto, manual y README completos, code review y security review (sus puertas de pre-release), datos genéricos en todo el código y en los tests.
**Hecho cuando:** manual con capturas, `--selftest` verde, review de seguridad sin hallazgos abiertos, y **cero datos personales en el repo**.

---

## 6. Costes estimados 2026

### Setup (una sola vez)

| Concepto | Ruta nube | Ruta local |
|---|---|---|
| Apple Developer Program (solo si Fase 4) | $99/año | $99/año |
| Grabación del video base (luz + trípode, si no los tiene) | $0–200 | $0–200 |
| Slot de avatar custom HeyGen | **precio no publicado — preguntar a ventas** | — |
| Entrenamiento de réplica Tavus (si se elige Tavus) | $65 por reentrenamiento en Starter | — |
| GPU alquilada para entrenar 3DGS (Fase 5) | — | ~$1,5–4/hora × 6–20 h, verificar tarifas al contratar |
| Tiempo de ingeniería | ~3 semanas | ~5–7 semanas |

### Mensual recurrente

| Escenario | Coste/mes | Detalle |
|---|---|---|
| **Local puro** (Fases 1, 3, 5) | **$0** + electricidad | Sin API, sin cuota. Si usa su clon de voz: + ElevenLabs |
| **Nube HeyGen LITE, uso ligero** (2 h/mes) | ~$99 | Plan Pro $99 cubre 1.000 min; 2 h = 120 créditos |
| **Nube HeyGen LITE, uso real** (10 h/mes) | ~$99 | 600 min de 1.000 disponibles |
| **Nube HeyGen LITE, uso intensivo** (25 h/mes) | ~$149 | 1.500 min → 500 min de excedente a $0,10 |
| **Nube Tavus** (5 h/mes) | ~$110 | Starter $59 + 200 min de overage a $0,37 |
| **Nube D-ID** (5 h/mes) | ~$50 | Launch $50/mes ≈ 90 min streaming + excedente; ojo bolsa compartida |
| **Simli Trinity** (banco de pruebas, 10 h/mes) | ~$10 | Hobby $10, 1.000 min incluidos |
| **ElevenLabs con voz clonada profesional** | **$22** (Creator, PVC) o **$99** (Pro, 44,1 kHz) | Precios de agregadores 2026 — **verificar en elevenlabs.io antes de contratar** |

**Combo recomendado, año 1:** local en Fases 1 y 3 ($0/mes) + ElevenLabs Creator ($22/mes) + HeyGen Pro **solo los meses que haga falta la nube** ($99/mes, cancelable). Presupuesto realista: **$264–$1.450/año**, según cuánto se use la nube.

---

## 7. Riesgos, límites honestos y salvaguardas

### 7.1 Qué NO se va a ver idéntico, y por qué

- **Las manos y el cuerpo.** HeyGen no soporta cuerpo entero; Tavus solo en modo vertical 4K; el re-labializado local solo toca la boca. Alberto gesticula al hablar: en modo guion, el avatar **no** gesticulará como él. Es la delación número uno.
- **La mirada.** En el video base la mirada es fija. Diez minutos de mirada perfectamente estable a cámara es *más* raro que una mirada imperfecta. Mitigación: grabar dos tomas (una quieta, una con 4–5 micro-gestos) y alternar bucles.
- **Reacciones espontáneas.** Si alguien hace un chiste, el avatar no se ríe. En modo espejo esto se mitiga (es su audio real, con sus risas), pero la cara no reacciona salvo por la boca.
- **Dientes y lengua** en primer plano: es donde todos los modelos fallan. A 256 px es visible; a 512 px + super-resolución mejora mucho; nunca es perfecto.
- **Barba y pelo largo.** La doc de Beyond Presence advierte explícitamente que "pelo largo y barbas típicamente producen malos resultados". Si Alberto lleva barba, hay que probarlo antes de comprometer nada.
- **Resolución.** Nadie ofrece 4K en vivo. D-ID topa en 1280×1280. En una ventana de Zoom no se nota; en pantalla completa sí.
- **Latencia.** Nadie publica cifras verificadas: HeyGen no da número, Tavus dice "world's lowest" sin ms, Anam declara 180 ms autoreportados, Simli declara <300 ms de speech-to-video, Beyond Presence ~250 ms end-to-end. Sumado al render local, al encoder y a Zoom, hay que **medirlo, no creerlo**.

### 7.2 Riesgos técnicos

| Riesgo | Probabilidad | Mitigación |
|---|---|---|
| MuseTalk en MPS no llega a fps usables en su Mac | **Media-alta** — no existe ningún benchmark publicado en Apple Silicon | Se descubre en la Fase 1, semana 1. Plan B: ruta nube o caja NVIDIA |
| Bug de render headless en macOS 26.2 con CMIOExtension | Media | No usar AppKit en la extensión; escribir CVPixelBuffer directo. Y Fase 4 es opcional |
| Zoom/Teams bloquean cámaras virtuales | Baja-media | Probar en las tres antes de Fase 4; la Fase 3 sigue sirviendo para grabar |
| Notarización rompe el flujo de build ad-hoc | Alta si se hace Fase 4 | Mantener dos targets de build: `dev` ad-hoc y `release` notarizado |
| HeyGen cambia precios o planes (ya hay inconsistencia "Essential" vs "Pro") | Media | Confirmar por escrito con ventas antes de contratar |
| El avatar de nube entrenado para render offline **no sirve en vivo** (HeyGen lo confirma; en D-ID está sin verificar) | Confirmada en HeyGen | Presupuestar **dos** avatares y dos pagos, o quedarse solo en vivo |
| El proveedor usa su cara para entrenar sus modelos | Alta si no se declina | Declinar explícitamente; exigir DPA; preferir ruta local |

### 7.3 Salvaguardas éticas y legales — no negociables

1. **Divulgación obligatoria en reuniones.** El **artículo 50 del EU AI Act es exigible desde el 2 de agosto de 2026** — mañana. Anam ya lo aplica de forma forzada: añade el sufijo `(AI)` al nombre y una marca persistente en el video, **y no se puede desactivar**. Aunque Alberto use su propia cara con su propio consentimiento, si el avatar habla solo (modo guion), hay que decirlo.
2. **La app lo implementa por diseño, no por confianza:** en modo `.script`, el `VideoSink` compone un overlay de divulgación configurable en texto pero **no desactivable**, y el modo guion exige una confirmación distinta cada sesión. En modo `.mirror` (su voz real, en vivo) el overlay puede ser opcional, porque no hay suplantación: es él hablando.
3. **Consentimiento archivado.** `consent.json` con fecha, texto firmado y hash del video base. Es su cara y su consentimiento; conviene que quede documentado por si algún día hay que demostrarlo.
4. **Solo Alberto.** El `AvatarStudio` rechaza crear identidades sin consentimiento firmado, y la documentación dice explícitamente que la herramienta es para uso propio. **No se implementa importación masiva de caras de terceros.**
5. **Nada de esquivar marcas de agua.** Si un proveedor impone divulgación, no se saca el video por cámara virtual para quitarla: eso violaría sus términos y el espíritu del requisito.
6. **Consentimiento de nube por proveedor**, como ya se hace con STT: autorizar HeyGen no autoriza a Tavus.
7. **Cero material personal en el repo.** El video base, las claves y `meta.json` viven en Application Support con permisos restrictivos, nunca en git. Los tests usan datos genéricos.
8. **Contexto UEA:** usar un avatar en una reunión institucional sin avisar tiene un coste reputacional muy superior al beneficio. Recomendación explícita: en reuniones de la UEA, modo espejo con su voz real, y avisar al inicio.

---

## 8. Preguntas que Alberto debe responder antes de empezar

1. **¿Cuál es el caso de uso número uno?** ¿"Estoy en la reunión pero no presentable / mala cámara" (→ modo espejo, Fase 1 y listo) o "no estoy y el avatar habla por mí" (→ modo guion, mucho más trabajo y mucho más delicado)? **Esta respuesta cambia la mitad del plan.**
2. **¿Qué Mac exactamente?** Chip (M1/M2/M3/M4/M5, Pro/Max/Ultra) y **RAM unificada**. De esto depende si la Fase 1 es viable en local; sin este dato el plan no puede prometer fps.
3. **¿Tiene o está dispuesto a conseguir una GPU NVIDIA** (caja propia o alquiler tipo RunPod/Vast) para la Fase 5? Sin ella, el requisito 4 ("más recursos → mejor") **no se puede cumplir de verdad** y hay que decirlo ahora.
4. **¿Barba?** ¿Gafas? ¿Pelo suelto? Afecta directamente a la fidelidad y hay proveedores que lo advierten por escrito.
5. **¿Acepta instalar OBS Studio y BlackHole**, o quiere sí o sí una cámara virtual propia dentro de BtoPrompter? Lo segundo cuesta $99/año y ~2–3 semanas más, y obliga a abandonar la firma ad-hoc.
6. **¿Está dispuesto a pagar el Apple Developer Program ($99/año)?** Sin él no hay cámara virtual propia ni notarización, y BtoPrompter es open source: la firma cambia también cómo se distribuyen las releases públicas.
7. **Presupuesto mensual tope para nube.** ¿$0, $25, $100, $250? El tope se codifica como `avatarBudgetCapUSD` y corta las sesiones. Necesito el número, no un rango.
8. **¿Autoriza subir su cara y su voz a un servidor de EE. UU.** (HeyGen/Tavus/D-ID/Simli) o solo a la UE (Beyond Presence), o **a ninguno**? Si la respuesta es "a ninguno", se elimina toda la §1.A y el plan pasa a ser local puro.
9. **¿Qué plan de ElevenLabs tiene hoy?** ¿Tiene ya un **Professional Voice Clone** (los ~30 min de audio) o solo Instant? Afecta a qué se puede enchufar en modo LITE y a la calidad del español ecuatoriano.
10. **¿En qué reuniones piensa usarlo?** ¿UEA, EZTIC/clientes, personales? Determina el nivel de divulgación y si esto debería salir en el BtoPrompter público o quedarse en una build privada.
11. **¿Se publica en el repo open source o queda privado?** Un avatar fotorrealista en un proyecto público atrae un tipo de uso que probablemente no quiere apadrinar.
12. **¿Qué es "hecho" para él?** ¿Que su hermano no lo note en Zoom? ¿Que un colega de la UEA no lo note? Necesito un juez y un umbral concretos, o la Fase 5 no tiene criterio de aceptación.

---

## 9. Lo que recomiendo hacer esta semana, si me deja elegir

1. Responder las preguntas 1, 2, 3 y 8 (30 minutos).
2. Grabar el video base con el checklist de la Fase 0 (1 hora). Sirve para **todas** las rutas, nube y local, y es la palanca de calidad más barata que existe.
3. Montar el spike de la Fase 1 y correr `--avatar-bench` en su Mac. **Un número de fps real en su hardware vale más que todo este documento.**
4. En paralelo, y sin gastar créditos, probar HeyGen en **Sandbox Mode** con su clon de ElevenLabs para tener una referencia visual de "el estándar comercial" contra la cual juzgar lo local.

Con esos dos resultados —fps local medido y captura de HeyGen en sandbox— la decisión de arquitectura se toma con evidencia y no con folletos.