import AppKit
import Combine
import SwiftUI

// Ciclo de vida de la app: panel flotante, menú, monitor de teclado local.

// Panel no-activante: flota sobre TODO (incluidas apps en pantalla completa,
// como PowerPoint o Keynote presentando) y no roba el foco al hacer clic.
// Nota: una NSWindow normal con canJoinAllSpaces NO aparece sobre Spaces
// fullscreen; el NSPanel sí — no cambiar a NSWindow.
final class PrompterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        // Esc no cierra el panel; en modo prompter el monitor de teclado lo usa.
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    private var cancellables = Set<AnyCancellable>()
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Abrir directo el editor de composición (pruebas y acceso rápido).
        // Con ruta: esa carpeta; sin ruta: el selector de proyectos.
        if CommandLine.arguments.contains("--studio") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                StudioWindowController.shared.open()
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--editor") {
            let folder: URL? = CommandLine.arguments.count > i + 1
                && !CommandLine.arguments[i + 1].hasPrefix("--")
                ? URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
                : nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                VideoEditorWindowController.shared.open(folder: folder)
            }
        }
        // Una sola instancia: si ya hay una abierta, se trae al frente y esta
        // se retira. Evita ventanas duplicadas al abrir la app dos veces.
        if let id = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if let existing = others.first {
                existing.activate(options: [.activateAllWindows])
                // Salida inmediata: terminate() dentro del arranque se aplaza y
                // dejaría viva una segunda instancia con su propia ventana.
                exit(0)
            }
        }

        let model = PrompterModel.shared
        let store = SpeechStore.shared

        // Selección inicial coherente.
        if store.speech(model.selectedID) == nil {
            model.selectedID = store.library.speeches.first?.id
        }

        let panel = PrompterPanel(
            contentRect: NSRect(origin: .zero, size: Theme.panelSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        window = panel
        window.title = "BtoPrompter"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.minSize = Theme.panelMinSize
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        applySharingType()
        window.contentView = NSHostingView(
            rootView: ContentView()
                .environmentObject(model)
                .environmentObject(store)
        )
        window.delegate = self
        // Encuadre inicial proporcional a la pantalla: centrado y arriba.
        if let screen = window.screen ?? NSScreen.main {
            window.setFrame(Theme.normalFrame(for: screen), display: false)
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)

        model.$spyMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applySharingType()
            }
            .store(in: &cancellables)

        // Modo minimalista: barra a todo el ancho pegada arriba (debajo del
        // notch/barra de menú). El alto sigue al tamaño de letra. Al salir se
        // restaura el marco anterior.
        Publishers.CombineLatest3(model.$miniMode, model.$miniFontSize, model.$mode)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mini, fontSize, mode in
                self?.applyMiniLayout(active: mini && mode == .prompting, fontSize: fontSize)
            }
            .store(in: &cancellables)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            PrompterModel.shared.handleKey(event) ? nil : event
        }

        buildMenu()
        NSApp.activate(ignoringOtherApps: true)

        if Settings.bool(.remoteEnabled, default: false) {
            RemoteControl.shared.start()
        }

        // Mando flotante de grabación (si la grabación está activada).
        RecordingHUDController.shared.showIfNeeded()

        if CommandLine.arguments.contains("--autostart") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                model.startPrompter()
                model.play()
            }
        }
    }

    // ÚNICO punto del programa que escribe `sharingType`. La invisibilidad al
    // compartir pantalla es la seña de identidad de la app: si varias partes
    // pudieran tocarla, bastaría un olvido para que el guion apareciera en una
    // videollamada. Quien quiera cambiarla mueve `spyMode` y pasa por aquí.
    private func applySharingType() {
        window.sharingType = PrompterModel.shared.spyMode ? .none : .readOnly
    }

    private var savedFrame: NSRect?

    private func applyMiniLayout(active: Bool, fontSize: CGFloat) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        if active {
            if savedFrame == nil { savedFrame = window.frame }
            // visibleFrame ya excluye la barra de menú (y el notch en Macs que lo tienen).
            let vf = screen.visibleFrame
            // 2 renglones de fontSize*1.3 + progreso + padding: garantiza ambas líneas visibles.
            let height = ceil(fontSize * 1.3) * 2 + 2 + 4 + 12 + 8
            window.setFrame(NSRect(x: vf.minX, y: vf.maxY - height, width: vf.width, height: height),
                            display: true, animate: false)
            for b in buttons { window.standardWindowButton(b)?.isHidden = true }
            PrompterModel.shared.miniContentWidth = max(200, vf.width - 360)
            window.contentView?.needsDisplay = true
        } else {
            // Al volver del modo mini se reencuadra SIEMPRE con la medida
            // calculada. Reutilizar el marco anterior era frágil: si el aviso
            // llegaba a mitad del cambio se guardaba un marco intermedio y la
            // ventana volvía deformada, ocupando casi toda la pantalla.
            savedFrame = nil
            for b in buttons { window.standardWindowButton(b)?.isHidden = false }
            window.setFrame(Theme.normalFrame(for: screen), display: true, animate: false)
            window.contentView?.needsDisplay = true
        }
    }

    // Al redimensionar a mano, la ventana se recentra horizontalmente y
    // conserva su borde superior: crece y encoge hacia los dos lados y hacia
    // abajo, en vez de irse a una esquina.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard !PrompterModel.shared.miniMode,
              let screen = window.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let frame = window.frame
        let x = vf.minX + (vf.width - frame.width) / 2
        let top = min(vf.maxY, max(frame.maxY, vf.minY + frame.height))
        let target = NSRect(x: x, y: top - frame.height,
                            width: frame.width, height: frame.height)
        if abs(target.origin.x - frame.origin.x) > 1 || abs(target.origin.y - frame.origin.y) > 1 {
            window.setFrame(target, display: true, animate: true)
        }
    }

    // Vuelve a encuadrar la ventana en el tamaño y sitio recomendados.
    func resetWindowFrame() {
        guard let screen = window.screen ?? NSScreen.main else { return }
        window.setFrame(Theme.normalFrame(for: screen), display: true, animate: true)
    }

    @objc func openStudio() {
        MainActor.assumeIsolated {
            StudioWindowController.shared.open()
        }
    }

    @objc func toggleRecording() {
        MainActor.assumeIsolated {
            RecordingEngine.shared.toggle()
        }
    }

    @objc func togglePauseRecording() {
        MainActor.assumeIsolated {
            RecordingEngine.shared.togglePause()
        }
    }

    @objc func toggleRecordingHUD() {
        MainActor.assumeIsolated {
            RecordingHUDController.shared.toggleVisible()
        }
    }

    @objc func openVideoEditor() {
        MainActor.assumeIsolated {
            VideoEditorWindowController.shared.open()
        }
    }

    @objc private func openSettings() {
        window.makeKeyAndOrderFront(nil)
        PrompterModel.shared.showSettings = true
    }

    func applicationWillTerminate(_ notification: Notification) {
        VoiceTracker.shared.stop()
        PrompterModel.shared.finishSessionForTermination()
        GlobalHotKeys.shared.unregister()
        SpeechStore.shared.saveNow()
    }

    // La ventana nunca muere de verdad: cerrar = ocultar. La app solo termina
    // con Cmd+Q. Un clic en el ícono del Dock siempre la trae de vuelta.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Configuración…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(NSMenuItem.separator())
        // Grabar SIN teleprompter: para tutoriales y clases hablando libre,
        // sin pasar por el guion. Mismo motor y misma carpeta.
        if Settings.bool(.recordingEnabled, default: false) {
            appMenu.addItem(NSMenuItem(title: "Estudio…",
                                       action: #selector(openStudio), keyEquivalent: "0"))
            appMenu.addItem(NSMenuItem(title: "Grabar / Detener grabación",
                                       action: #selector(toggleRecording), keyEquivalent: "r"))
            let pauseItem = NSMenuItem(title: "Pausar / Reanudar grabación",
                                       action: #selector(togglePauseRecording), keyEquivalent: "R")
            appMenu.addItem(pauseItem)
            appMenu.addItem(NSMenuItem(title: "Mostrar / ocultar el mando de grabación",
                                       action: #selector(toggleRecordingHUD), keyEquivalent: ""))
            appMenu.addItem(NSMenuItem.separator())
        }
        // Solo existe con el editor activado en Ajustes; apagado = ni menú.
        if Settings.bool(.videoEditorEnabled, default: false) {
            appMenu.addItem(NSMenuItem(title: "Componer grabación…",
                                       action: #selector(openVideoEditor), keyEquivalent: "e"))
            appMenu.addItem(NSMenuItem.separator())
        }
        appMenu.addItem(NSMenuItem(title: "Salir de BtoPrompter",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edición")
        editMenu.addItem(NSMenuItem(title: "Deshacer", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Rehacer", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
