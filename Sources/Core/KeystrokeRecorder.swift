import AppKit
import Foundation

// Teclas en pantalla, lo clásico de los tutoriales: que se vea «⌘S» cuando
// alguien guarda. Se registran mientras se graba y el editor las pinta.
//
// REGLA DURA DE PRIVACIDAD: solo se apuntan los ATAJOS, es decir, teclas
// pulsadas junto a ⌘, ⌥ o ⌃, más las teclas sueltas que no escriben nada
// (Esc, Tab, flechas, Intro). El texto que se teclea NO se registra jamás:
// en una grabación de pantalla puede haber una contraseña, y un archivo con
// todo lo tecleado sería exactamente lo que nadie quiere que exista.

@MainActor
final class KeystrokeRecorder {
    static let shared = KeystrokeRecorder()

    private var monitor: Any?
    private var events: [(t: Double, keys: String)] = []
    private var startedAt: Date?

    static var enabled: Bool { Settings.bool(.recordKeystrokes, default: false) }

    // Necesita el permiso de Accesibilidad (el mismo del control remoto).
    static var hasPermission: Bool { AXIsProcessTrusted() }

    func start(at date: Date) {
        stop()
        guard Self.enabled, Self.hasPermission else { return }
        events = []
        startedAt = date
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in self?.record(event) }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    private func record(_ event: NSEvent) {
        guard let start = startedAt else { return }
        guard let label = Self.label(for: event) else { return }   // texto normal: fuera
        let t = Date().timeIntervalSince(start)
        guard t >= 0 else { return }
        // Repeticiones seguidas de la misma tecla no llenan la pantalla.
        if let last = events.last, last.keys == label, t - last.t < 0.4 { return }
        events.append((t, label))
    }

    // Devuelve la etiqueta a mostrar, o nil si es texto normal (no se apunta).
    static func label(for event: NSEvent) -> String? {
        let flags = event.modifierFlags
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        let hasModifier = !parts.isEmpty

        let special: [UInt16: String] = [
            53: "esc", 48: "⇥", 36: "↩", 76: "↩", 51: "⌫", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            116: "⇞", 121: "⇟", 115: "↖", 119: "↘", 49: "espacio",
        ]
        if let key = special[event.keyCode] {
            // Las teclas que no escriben se pueden mostrar siempre: no
            // revelan lo que alguien está redactando.
            parts.append(key)
            return parts.joined()
        }
        // Una letra o número SOLO se muestra si va con ⌘, ⌥ o ⌃: eso es un
        // atajo. Sin modificador es texto y no se toca.
        guard hasModifier, flags.contains(.command) || flags.contains(.control)
                || flags.contains(.option) else { return nil }
        let chars = (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !chars.isEmpty, chars.count <= 3 else { return nil }
        parts.append(chars)
        return parts.joined()
    }

    func write(toFolder folder: URL, anchor: Date?) {
        stop()
        guard !events.isEmpty else { return }
        let shift = anchor.flatMap { a in startedAt.map { a.timeIntervalSince($0) } } ?? 0
        let lines = events.compactMap { e -> String? in
            let t = e.t - shift
            guard t >= 0 else { return nil }
            let payload: [String: Any] = ["t": (t * 100).rounded() / 100, "k": e.keys]
            guard let d = try? JSONSerialization.data(withJSONObject: payload),
                  let s = String(data: d, encoding: .utf8) else { return nil }
            return s
        }
        try? lines.joined(separator: "\n")
            .write(to: folder.appendingPathComponent("teclas.jsonl"),
                   atomically: true, encoding: .utf8)
    }
}
