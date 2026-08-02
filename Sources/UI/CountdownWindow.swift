import AppKit
import SwiftUI

// Cuenta regresiva a pantalla completa antes de grabar: el 3, 2, 1 grande que
// da tiempo a colocarse, con teleprompter o sin él. Antes solo existía dentro
// del prompter, así que grabando a secas no avisaba de nada.
//
// Es una ventana de aviso, no contenido: NO sale en la grabación ni en las
// capturas, igual que el mando y el teleprompter.

@MainActor
final class CountdownWindowController {
    static let shared = CountdownWindowController()
    private var panel: NSPanel?

    func show(_ number: Int) {
        if panel == nil {
            let screen = NSScreen.main ?? NSScreen.screens.first
            let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
            let p = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .screenSaver           // por encima de todo, incluso a pantalla completa
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            p.ignoresMouseEvents = true      // no estorba: se puede seguir trabajando
            p.sharingType = .none            // jamás en la grabación
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel = p
        }
        panel?.contentView = NSHostingView(rootView: CountdownBigView(number: number))
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

private struct CountdownBigView: View {
    let number: Int

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
            VStack(spacing: 6) {
                Text("\(max(1, number))")
                    .font(.system(size: 220, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.7), radius: 24)
                Text("grabando en…")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.7), radius: 10)
            }
        }
        .ignoresSafeArea()
    }
}
