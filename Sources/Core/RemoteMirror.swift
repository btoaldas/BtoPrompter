import Foundation

// Espejo del guion en el teléfono. El móvil pide el guion una sola vez y
// después recibe solo la posición, varias veces por segundo, por una conexión
// que queda abierta. Así el karaoke va sincronizado sin gastar batería
// preguntando cada poco.

enum RemoteMirror {

    // El guion tal como lo necesita el móvil: una entrada por trozo, con las
    // mismas guías y estilos que se ven en el Mac.
    static func scriptJSON() -> String {
        let model = PrompterModel.shared
        // Fuera del prompter los trozos aún no existen: se calculan aquí para
        // que el teléfono pueda ver el guion aunque el Mac siga en el editor.
        let parsed: [Chunk]
        if !model.chunks.isEmpty {
            parsed = model.chunks
        } else if let doc = SpeechStore.shared.speech(model.selectedID) {
            parsed = ScriptParser.parse(doc.body, guideTitles: model.guideTitles)
        } else {
            parsed = []
        }
        let total = parsed.last?.range.upperBound ?? 0
        var chunks: [[String: Any]] = []
        for c in parsed {
            chunks.append([
                "id": c.id,
                "text": c.words.joined(separator: " "),
                "from": c.range.lowerBound,
                "to": c.range.upperBound,
                "guide": c.isGuide,
                "style": styleName(c.style),
                "words": c.words,
            ])
        }
        let payload: [String: Any] = [
            "total": total,
            "title": SpeechStore.shared.speech(model.selectedID)?.title ?? "",
            "chunks": chunks,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func styleName(_ s: ChunkStyle) -> String {
        switch s {
        case .h1: return "h1"
        case .h2: return "h2"
        case .bullet: return "bullet"
        case .normal: return "normal"
        }
    }

    // Estado ligero que viaja muchas veces por segundo.
    static func stateJSON() -> String {
        let m = PrompterModel.shared
        return """
        {"i":\(m.currentIndex),"playing":\(m.isPlaying),"wpm":\(m.wpm),\
        "total":\(m.totalWords),"voice":\(m.voiceActive),\
        "mode":"\(m.mode == .prompting ? "prompter" : "editor")",\
        "countdown":\(m.countdown.map(String.init) ?? "null"),\
        "rev":\(revision)}
        """
    }

    // Cambia cuando el guion deja de ser el mismo: así el móvil sabe que debe
    // volver a pedirlo en vez de resaltar palabras que ya no existen.
    private(set) static var revision = 0
    static func scriptChanged() {
        revision += 1
    }
}
