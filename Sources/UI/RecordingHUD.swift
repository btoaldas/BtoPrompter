import AppKit
import SwiftUI

// Mando flotante de grabación: un panel pequeño que vive encima de todo, se
// arrastra a donde quieras y sirve para grabar, pausar y parar sin buscar la
// app. Abajo a la derecha por defecto; su posición se recuerda.
//
// Nace con la grabación activada en Ajustes y se puede ocultar. Como es una
// ventana de la propia app, la grabación de pantalla lo excluye igual que al
// teleprompter: no sale en el vídeo.

@MainActor
final class RecordingHUDController: NSObject, NSWindowDelegate {
    static let shared = RecordingHUDController()
    private var panel: NSPanel?

    static var enabled: Bool { Settings.bool(.recordHUD, default: true) }

    func showIfNeeded() {
        guard Settings.bool(.recordingEnabled, default: false), Self.enabled else {
            hide()
            return
        }
        show()
    }

    func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 168, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .statusBar
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.isMovableByWindowBackground = true      // se arrastra desde el fondo
            // El mando es un CONTROL, no contenido: jamás sale en una
            // grabación, una captura ni una pantalla compartida. Igual que el
            // teleprompter, y aquí no es opcional — no hay motivo para que
            // alguien vea los botones de quien graba.
            p.sharingType = .none
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.delegate = self
            p.contentView = NSHostingView(rootView: RecordingHUDView())
            panel = p
            restorePosition(p)
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func toggleVisible() {
        if panel?.isVisible == true {
            Settings.set(false, .recordHUD)
            hide()
        } else {
            Settings.set(true, .recordHUD)
            show()
        }
    }

    // Abajo a la derecha la primera vez; después, donde el usuario lo dejó.
    private func restorePosition(_ p: NSPanel) {
        let saved = Settings.string(.recordHUDPosition, default: "")
        let parts = saved.split(separator: ",").compactMap { Double($0) }
        if parts.count == 2 {
            let point = NSPoint(x: parts[0], y: parts[1])
            // Solo si sigue cayendo dentro de alguna pantalla (monitores que
            // van y vienen dejarían el mando fuera de la vista).
            if NSScreen.screens.contains(where: { $0.frame.contains(point) }) {
                p.setFrameOrigin(point)
                return
            }
        }
        if let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: vf.maxX - p.frame.width - 24, y: vf.minY + 24))
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard let p = panel else { return }
        Settings.set("\(p.frame.origin.x),\(p.frame.origin.y)", .recordHUDPosition)
    }
}

struct RecordingHUDView: View {
    @ObservedObject private var engine = RecordingEngine.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.35))
                .help("Arrastra desde aquí para mover el mando")

            switch engine.phase {
            case .idle:
                button("record.circle.fill", .red, "Grabar (⌘R)") { engine.start() }
            case .countdown(let n):
                Text("\(n)")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(.orange)
                    .frame(width: 26)
                button("xmark.circle.fill", .gray, "Cancelar") { engine.toggle() }
            case .recording, .paused:
                Circle()
                    .fill(engine.phase == .paused ? Color.orange : Color.red)
                    .frame(width: 9, height: 9)
                Text(engine.elapsedText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                button(engine.phase == .paused ? "play.circle.fill" : "pause.circle.fill",
                       .white, engine.phase == .paused ? "Reanudar (⌘⇧R)" : "Pausar (⌘⇧R)") {
                    engine.togglePause()
                }
                button("stop.circle.fill", .white, "Parar (⌘R)") { engine.stop() }
            case .stopping:
                ProgressView().controlSize(.small)
                Text("guardando…").font(.system(size: 11)).foregroundColor(.white)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.black.opacity(0.82)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.12), lineWidth: 1))
        .fixedSize()
    }

    private func button(_ symbol: String, _ color: Color, _ help: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundColor(color)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
