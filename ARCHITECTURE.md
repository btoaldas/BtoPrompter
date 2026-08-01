# Arquitectura de BtoPrompter

Una app macOS en Swift puro (AppKit + SwiftUI), compilada con `swiftc` desde
`build.sh` — sin proyecto de Xcode ni dependencias externas. Un solo módulo,
organizado por capas para crecer sin que un cambio dañe el resto.

```
Sources/
├── App/            Ciclo de vida y punto de entrada
│   ├── main.swift          Flags CLI (--selftest, --test-pptx, --test-ai,
│   │                       --capturable, --autostart) y arranque
│   ├── AppDelegate.swift   PrompterPanel (NSPanel no-activante), menú,
│   │                       monitor de teclado local
│   └── SelfTest.swift      Pruebas del parser sin frameworks
│
├── Core/           Lógica de negocio ("backend")
│   ├── PrompterEngine.swift  PrompterModel: estado, transporte, karaoke,
│   │                         orquestación del Ensayo IA
│   ├── RemoteControl.swift   Servidor HTTP local del remoto (token 128 bits,
│   │                         comparación en tiempo constante) + canal SSE
│   ├── RemoteMirror.swift    El guion y el estado en JSON para el teléfono
│   ├── RemoteInput.swift     Teclas/ratón sintéticos (control del ordenador)
│   ├── RecordingEngine.swift Grabación cámara+pantalla sincronizadas
│   │                         (centinela de primer fotograma, sidecar sync.json)
│   ├── VideoProjectModel.swift  Proyecto del editor: tramos, recortes, fondos.
│   │                         Funciones puras probadas en --selftest
│   ├── VideoComposer.swift   PiPCompositor (AVVideoCompositing + Core Image),
│   │                         FrameComposer (dibujo único preview=export),
│   │                         CompositionBuilder y CompositionExporter
│   ├── ScriptParser.swift    Texto/Markdown → [Chunk] (función pura, testeable)
│   ├── AIRehearsal.swift     Cliente de APIs estilo OpenAI + prompt de ritmo
│   ├── Importers.swift       txt/md, pptx (unzip + XML), audio (Speech)
│   ├── VoiceTracker.swift    Captura única, permisos y failover STT
│   ├── VoiceAlignment.swift  Alineación monotónica y conservadora
│   ├── VoiceTypes.swift      Contratos y catálogo de proveedores
│   ├── AppleSpeechProviders.swift  Dictado Apple local/nube + modelos
│   ├── CloudSpeechProvider.swift   Adaptadores STT externos en vivo
│   ├── VoiceDiagnostics.swift      Logs/eventos/audio local acotado
│   ├── SpeechPlayback.swift  Lectura TTS local de macOS
│   └── GlobalHotKeys.swift   Atajos globales Carbon (sin permisos TCC)
│
├── Storage/        Datos y parámetros ("base de datos")
│   ├── SpeechStore.swift     Biblioteca de discursos → speeches.json
│   │                         (Application Support, guardado agrupado, atómico)
│   ├── Settings.swift        Parámetros globales tipados (UserDefaults)
│   │                         + límites/constantes del prompter
│   ├── SpeakingProfileStore.swift  Estadísticas locales del orador
│   └── SecretsStore.swift    API keys → secrets.json con permisos 0600
│
└── UI/             Interfaz ("frontend", SwiftUI)
    ├── Theme.swift           Colores y métricas, un solo lugar
    ├── ContentView.swift     Raíz: editor ↔ prompter
    ├── SidebarView.swift     Biblioteca (carpetas, borradores, importar)
    ├── EditorPane.swift      Edición del discurso
    ├── AISheet.swift         Configuración del Ensayo IA
    ├── PrompterView.swift    Karaoke, progreso, controles
    ├── VideoEditorWindow.swift  Editor de composición: timeline de tramos,
    │                         inspector por componentes, exportación
    ├── RecordingSettingsTab.swift  Ajustes de grabación y editor
    └── Components.swift      Piezas reutilizables
```

## Reglas de dependencia

- `UI` observa `Core` (PrompterModel/SpeechStore) y lee `Theme`; nunca toca disco.
- `Core` usa `Storage`; no conoce vistas.
- `Storage` no conoce a nadie: solo modelos y disco.
- `App` conecta todo.

## Decisiones clave

- **NSPanel no-activante** (no NSWindow): es lo que permite flotar sobre apps
  en pantalla completa y no robar el foco de la presentación. No cambiar.
- **`sharingType = .none`**: la invisibilidad al compartir pantalla. El toggle
  del ojo lo conmuta en caliente.
- **Secretos en `secrets.json` (0600)** y no en el Llavero: la firma ad-hoc de
  desarrollo cambia en cada build y el Llavero pediría autorización cada vez.
  Nunca en UserDefaults (hay migración automática desde versiones previas).
- **El resaltado del karaoke nunca cambia peso ni tamaño de fuente**: evita
  reflow del texto (requisito de usabilidad). Solo color y subrayado.
- **Guías** (`//`, títulos): chunks con rango de palabras vacío — el motor de
  avance jamás las pisa y no cuentan para tiempo ni progreso.

## Cómo extender

| Quiero…                        | Toco…                                      |
|--------------------------------|--------------------------------------------|
| Nuevo formato de importación   | `Core/Importers.swift` (un caso + función) |
| Nuevo proveedor de IA          | `AIRehearsal.providers` (una línea)        |
| Nuevo estilo de ensayo         | `AIRehearsal.styles` (una línea)           |
| Nuevo parámetro global         | `Storage/Settings.swift` (clave + default) |
| Nueva marca de sintaxis        | `Core/ScriptParser.swift` + SelfTest       |
| Nueva vista o control          | `UI/` (usar `Theme` y `Components`)        |
| Nuevo modo de composición      | `SegmentLayout.Mode` + un caso en `FrameComposer.compose` |
| Nuevo tipo de fondo del editor | `BackgroundStyle` + un caso en `FrameComposer.backgroundImage` |
| Nuevo control por tramo        | Una sección en `SegmentInspector` (no toca el reproductor) |

Antes de commitear: `./build.sh && dist/BtoPrompter.app/Contents/MacOS/BtoPrompter --selftest`

## Política de funciones independientes

Regla del proyecto para TODA función nueva. Sin excepciones.

1. **Activable.** Cada función tiene su propio interruptor en Configuración. El
   usuario decide, la app no impone.
2. **Apagada por defecto** si pide un permiso del sistema, usa la red, gasta
   dinero (APIs de pago) o graba algo. Encendida por defecto solo si es inocua.
3. **Inerte cuando está apagada.** No abre dispositivos, no escucha, no crea
   temporizadores, no escribe en disco y no monta servidores. Apagada significa
   que no existe, no que está esperando.
4. **Sin interferencias.** Ninguna función puede alterar el comportamiento de
   otra. Casos que ya se cuidan: un solo micrófono compartido y jamás dos
   motores de voz a la vez; el avance por tiempo y el avance por voz se
   excluyen; el modo minimalista no rompe el encuadre normal.
5. **La invisibilidad al compartir pantalla es intocable.** Ninguna función
   puede hacer que el teleprompter aparezca en una llamada o una captura sin
   que el usuario lo haya pedido de forma explícita.
6. **Degradación honesta.** Si falta un permiso, una clave o la red, la función
   lo dice con claridad y el resto de la app sigue funcionando igual. Nunca se
   queda el prompter congelado por un fallo de una función accesoria.

Cómo se comprueba antes de dar una función por terminada:

- Con el interruptor apagado, el comportamiento previo es idéntico: mismo
  arranque, mismos permisos pedidos, mismos archivos escritos.
- Con la función encendida y su permiso denegado, la app avisa y sigue usable.
- Encender y apagar en caliente, varias veces, sin dejar recursos abiertos.
- `--selftest` en verde y prueba real de la función con evidencia reproducible.
