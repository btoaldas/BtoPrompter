import AppKit
import Foundation

// Cambio de diapositiva automático: al cruzar una guía tipo "// Diapositiva N",
// avanza PowerPoint o Keynote por AppleScript. Requiere permiso de Automation
// la primera vez. Solo avanza hacia adelante.
final class SlideSync: ObservableObject {
    static let shared = SlideSync()

    @Published var status: String? = nil

    var enabled: Bool {
        get { Settings.bool(.slideSyncEnabled, default: false) }
        set { Settings.set(newValue, .slideSyncEnabled) }
    }

    var targetApp: String {
        get { Settings.string(.slideSyncApp, default: "keynote") }
        set { Settings.set(newValue, .slideSyncApp) }
    }

    static let targets: [(id: String, name: String)] = [
        ("keynote", "Keynote"),
        ("powerpoint", "PowerPoint"),
        ("tecla", "Cualquier app (flecha derecha)"),
    ]

    func advanceSlide() {
        guard enabled else { return }
        // Modo genérico: manda la flecha derecha a la app que tenga el foco.
        // Funciona en Vista Previa, visores de PDF, navegadores y presentaciones.
        if targetApp == "tecla" {
            DispatchQueue.main.async {
                guard RemoteInput.isTrusted else {
                    self.status = "Para avanzar con la flecha hace falta el permiso de Accesibilidad."
                    return
                }
                let previous = Settings.bool(.remoteComputerControl, default: false)
                Settings.set(true, .remoteComputerControl)
                RemoteInput.key("right")
                Settings.set(previous, .remoteComputerControl)
                self.status = nil
            }
            return
        }
        let source: String
        switch targetApp {
        case "powerpoint":
            source = """
            tell application "Microsoft PowerPoint"
                go to next slide (slide show view of slide show window 1)
            end tell
            """
        default:
            source = """
            tell application "Keynote"
                show next of front document
            end tell
            """
        }
        DispatchQueue.main.async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error {
                let message = error[NSAppleScript.errorMessage] as? String ?? "error desconocido"
                self.status = "No se pudo avanzar la diapositiva: \(message)"
            } else {
                self.status = nil
            }
        }
    }
}
