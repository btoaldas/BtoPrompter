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
│   ├── ScriptParser.swift    Texto/Markdown → [Chunk] (función pura, testeable)
│   ├── AIRehearsal.swift     Cliente de APIs estilo OpenAI + prompt de ritmo
│   ├── Importers.swift       txt/md, pptx (unzip + XML), audio (Speech)
│   └── GlobalHotKeys.swift   Atajos globales Carbon (sin permisos TCC)
│
├── Storage/        Datos y parámetros ("base de datos")
│   ├── SpeechStore.swift     Biblioteca de discursos → speeches.json
│   │                         (Application Support, guardado agrupado, atómico)
│   ├── Settings.swift        Parámetros globales tipados (UserDefaults)
│   │                         + límites/constantes del prompter
│   └── SecretsStore.swift    API keys → secrets.json con permisos 0600
│
└── UI/             Interfaz ("frontend", SwiftUI)
    ├── Theme.swift           Colores y métricas, un solo lugar
    ├── ContentView.swift     Raíz: editor ↔ prompter
    ├── SidebarView.swift     Biblioteca (carpetas, borradores, importar)
    ├── EditorPane.swift      Edición del discurso
    ├── AISheet.swift         Configuración del Ensayo IA
    ├── PrompterView.swift    Karaoke, progreso, controles
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

Antes de commitear: `./build.sh && dist/BtoPrompter.app/Contents/MacOS/BtoPrompter --selftest`
