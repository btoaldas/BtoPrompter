import AppKit
import CoreGraphics
import Foundation

// Control del ordenador desde el remoto del teléfono: teclas, clics, rueda y
// movimiento del puntero. Se sintetizan eventos del sistema, así que funcionan
// en cualquier app —Keynote, PowerPoint, Vista Previa, un PDF, el navegador—
// sin necesitar un guion específico para cada una.
//
// Requiere permiso de Accesibilidad y está apagado por defecto: sin el
// interruptor explícito ninguna orden de este módulo se ejecuta.

enum RemoteInput {

    // MARK: Permisos

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static var enabled: Bool {
        Settings.bool(.remoteComputerControl, default: false)
    }

    // MARK: Teclas

    // Nombres estables que usa la página web del remoto.
    static let keyCodes: [String: CGKeyCode] = [
        "right": 124, "left": 123, "down": 125, "up": 126,
        "space": 49, "return": 36, "escape": 53, "tab": 48,
        "pagedown": 121, "pageup": 116, "home": 115, "end": 119,
        "b": 11, "w": 13, "f": 3, "delete": 51,
    ]

    @discardableResult
    static func key(_ name: String, shift: Bool = false, command: Bool = false) -> Bool {
        guard enabled, isTrusted, let code = keyCodes[name.lowercased()] else { return false }
        var flags: CGEventFlags = []
        if shift { flags.insert(.maskShift) }
        if command { flags.insert(.maskCommand) }
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    // Escribe texto tal cual, para el teclado virtual del remoto.
    @discardableResult
    static func type(_ text: String) -> Bool {
        guard enabled, isTrusted, !text.isEmpty else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        for chunk in Array(text.utf16).chunked(into: 20) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            var buffer = chunk
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }

    // MARK: Puntero

    static var pointerLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    @discardableResult
    static func movePointer(dx: Double, dy: Double) -> Bool {
        guard enabled, isTrusted else { return false }
        let current = pointerLocation
        // Se limita al área visible de todas las pantallas.
        let bounds = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let target = CGPoint(
            x: min(max(bounds.minX, current.x + dx), bounds.maxX - 1),
            y: min(max(0, current.y + dy), (bounds.height - 1))
        )
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                 mouseCursorPosition: target, mouseButton: .left) else { return false }
        move.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    static func click(_ button: String, double: Bool = false) -> Bool {
        guard enabled, isTrusted else { return false }
        let position = pointerLocation
        let isRight = button.lowercased() == "right"
        let source = CGEventSource(stateID: .combinedSessionState)
        let downType: CGEventType = isRight ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = isRight ? .rightMouseUp : .leftMouseUp
        let mouseButton: CGMouseButton = isRight ? .right : .left
        for clickCount in 1...(double ? 2 : 1) {
            guard let down = CGEvent(mouseEventSource: source, mouseType: downType,
                                     mouseCursorPosition: position, mouseButton: mouseButton),
                  let up = CGEvent(mouseEventSource: source, mouseType: upType,
                                   mouseCursorPosition: position, mouseButton: mouseButton) else { return false }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }

    @discardableResult
    static func scroll(dx: Int, dy: Int) -> Bool {
        guard enabled, isTrusted else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return false }
        event.post(tap: .cghidEventTap)
        return true
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
