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

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    private var cancellables = Set<AnyCancellable>()
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        window.sharingType = model.spyMode ? .none : .readOnly
        window.contentView = NSHostingView(
            rootView: ContentView()
                .environmentObject(model)
                .environmentObject(store)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)

        model.$spyMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] spy in
                self?.window.sharingType = spy ? .none : .readOnly
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

        if CommandLine.arguments.contains("--autostart") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                model.startPrompter()
                model.play()
            }
        }
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
        } else if let saved = savedFrame {
            window.setFrame(saved, display: true, animate: false)
            savedFrame = nil
            for b in buttons { window.standardWindowButton(b)?.isHidden = false }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotKeys.shared.unregister()
        SpeechStore.shared.saveNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
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
