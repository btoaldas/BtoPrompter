import Foundation

// Subtítulos del editor de composición. Dos orígenes:
// 1. El PROPIO teleprompter: la app sabe qué palabra se dijo en qué segundo
//    (el grabador escribe subtitulos.jsonl en cada grabación con el prompter
//    en marcha), y de ahí se arman frases con sus tiempos.
// 2. Un archivo SRT del usuario.
// Se QUEMAN en el vídeo (Core Image), activables por proyecto, con estilo
// parametrizable. Funciones puras: probadas en --selftest.

// MARK: - Modelo

struct SubtitleChunk: Codable, Equatable {
    var from: Double
    var to: Double
    var text: String
}

struct SubtitleStyle: Codable, Equatable {
    enum Position: String, Codable, CaseIterable {
        case top, middle, bottom
    }

    // Fracción de la altura del lienzo (0.045 ≈ 48 px en 1080p).
    var fontSize: Double = 0.045
    var color = RGBA(r: 1, g: 1, b: 1)
    // Sombra del texto (para leerse sin caja): color y si se usa.
    var shadow = true
    var shadowColor = RGBA(r: 0, g: 0, b: 0)
    // Caja de fondo tras el texto (0 = sin caja) y su color.
    var boxOpacity: Double = 0.55
    var boxColor = RGBA(r: 0, g: 0, b: 0)
    // Dónde: arriba, al medio o abajo, con su margen.
    var position: Position = .bottom
    var margin: Double = 0.06
    // Una o dos filas, y cuánto ancho del lienzo pueden usar (0.5–1.0).
    var maxLines: Int = 2
    var widthFraction: Double = 0.9

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 0.045
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? RGBA(r: 1, g: 1, b: 1)
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? true
        shadowColor = try c.decodeIfPresent(RGBA.self, forKey: .shadowColor) ?? RGBA(r: 0, g: 0, b: 0)
        boxOpacity = try c.decodeIfPresent(Double.self, forKey: .boxOpacity) ?? 0.55
        boxColor = try c.decodeIfPresent(RGBA.self, forKey: .boxColor) ?? RGBA(r: 0, g: 0, b: 0)
        position = try c.decodeIfPresent(Position.self, forKey: .position) ?? .bottom
        margin = try c.decodeIfPresent(Double.self, forKey: .margin) ?? 0.06
        maxLines = try c.decodeIfPresent(Int.self, forKey: .maxLines) ?? 2
        widthFraction = try c.decodeIfPresent(Double.self, forKey: .widthFraction) ?? 0.9
    }

    func sanitized() -> SubtitleStyle {
        var s = self
        s.fontSize = min(0.12, max(0.02, s.fontSize))
        s.boxOpacity = min(1, max(0, s.boxOpacity))
        s.margin = min(0.4, max(0, s.margin))
        s.maxLines = min(2, max(1, s.maxLines))
        s.widthFraction = min(1, max(0.5, s.widthFraction))
        return s
    }

    // Modelos con nombre: el usuario elige uno y ajusta encima.
    static let models: [(name: String, style: SubtitleStyle)] = [
        ("Clásico TV", {
            var s = SubtitleStyle()
            s.boxOpacity = 0.65
            s.shadow = false
            return s
        }()),
        ("Formal", {
            var s = SubtitleStyle()
            s.boxOpacity = 0
            s.shadow = true
            s.fontSize = 0.04
            return s
        }()),
        ("Juvenil", {
            var s = SubtitleStyle()
            s.color = RGBA(r: 1, g: 0.85, b: 0.1)
            s.boxOpacity = 0
            s.shadow = true
            s.fontSize = 0.055
            return s
        }()),
        ("Invertido", {
            var s = SubtitleStyle()
            s.color = RGBA(r: 0.05, g: 0.05, b: 0.05)
            s.shadowColor = RGBA(r: 1, g: 1, b: 1)
            s.boxOpacity = 0
            return s
        }()),
        ("Minimal", {
            var s = SubtitleStyle()
            s.boxOpacity = 0
            s.shadow = true
            s.fontSize = 0.035
            s.widthFraction = 0.5
            s.maxLines = 1
            return s
        }()),
    ]
}

struct SubtitleTrack: Codable, Equatable {
    var enabled = true
    // Por defecto los subtítulos NO se queman: van como archivo .srt separado
    // junto al MP4 exportado (para subirlos a YouTube como pista). Quemarlos
    // es la opción, no la norma. Decisión de Alberto, quinta tanda.
    var burnIn = false
    var chunks: [SubtitleChunk] = []
    var style = SubtitleStyle()

    init(enabled: Bool = true) {
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        burnIn = try c.decodeIfPresent(Bool.self, forKey: .burnIn) ?? false
        chunks = try c.decodeIfPresent([SubtitleChunk].self, forKey: .chunks) ?? []
        style = try c.decodeIfPresent(SubtitleStyle.self, forKey: .style) ?? SubtitleStyle()
    }

    func chunk(at seconds: Double) -> SubtitleChunk? {
        chunks.first { seconds >= $0.from && seconds < $0.to }
    }

    func sanitized() -> SubtitleTrack {
        var t = self
        t.chunks = t.chunks
            .filter { $0.to > $0.from && !$0.text.isEmpty }
            .sorted { $0.from < $1.from }
        t.style = t.style.sanitized()
        return t
    }
}

// MARK: - Construcción

enum SubtitleBuilder {

    struct TimedWord: Codable {
        let w: String
        let t: Double
    }

    // Palabras con tiempo → frases con [desde, hasta]. Se corta la frase al
    // terminar la oración (.?!), al superar las N palabras, o cuando el
    // orador calló más de `gap` segundos (la pausa manda: el subtítulo no
    // debe quedarse colgado mientras nadie habla).
    static func group(_ words: [TimedWord], maxWords: Int = 8,
                      gap: Double = 1.4, minDuration: Double = 0.8,
                      tail: Double = 1.2) -> [SubtitleChunk] {
        var result: [SubtitleChunk] = []
        var current: [TimedWord] = []

        func close(endedBy nextStart: Double?) {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.w).joined(separator: " ")
            // La frase se ve hasta que empieza la siguiente o un respiro después
            // de la última palabra, lo que llegue antes.
            var to = last.t + tail
            if let nextStart { to = min(to, nextStart) }
            to = max(to, first.t + minDuration)
            result.append(SubtitleChunk(from: first.t, to: to, text: text))
            current = []
        }

        for word in words {
            if let last = current.last, word.t - last.t > gap {
                close(endedBy: word.t)
            }
            current.append(word)
            let endsSentence = word.w.hasSuffix(".") || word.w.hasSuffix("?")
                || word.w.hasSuffix("!") || word.w.hasSuffix("…")
            if endsSentence || current.count >= maxWords {
                close(endedBy: nil)
            }
        }
        close(endedBy: nil)
        // Sin solapes: cada frase termina donde empieza la siguiente.
        for i in 0..<max(0, result.count - 1) where result[i].to > result[i + 1].from {
            result[i].to = result[i + 1].from
        }
        return result.filter { $0.to > $0.from }
    }

    // Lee el subtitulos.jsonl que el grabador deja en la carpeta.
    static func fromRecording(folder: URL) -> [SubtitleChunk] {
        let url = folder.appendingPathComponent("subtitulos.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        let words = text.split(separator: "\n").compactMap {
            try? decoder.decode(TimedWord.self, from: Data($0.utf8))
        }
        return group(words)
    }

    // MARK: SRT

    // Parser del formato SRT clásico:
    //   1
    //   00:00:01,500 --> 00:00:04,000
    //   Texto (una o dos líneas)
    static func parseSRT(_ content: String) -> [SubtitleChunk] {
        var result: [SubtitleChunk] = []
        let blocks = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n").map(String.init)
            guard let timeLine = lines.first(where: { $0.contains("-->") }) else { continue }
            let parts = timeLine.components(separatedBy: "-->")
            guard parts.count == 2,
                  let from = srtTime(parts[0]), let to = srtTime(parts[1]),
                  to > from else { continue }
            guard let timeIdx = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let text = lines[(timeIdx + 1)...].joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            result.append(SubtitleChunk(from: from, to: to, text: text))
        }
        return result.sorted { $0.from < $1.from }
    }

    // Chunks → texto SRT (el inverso del parser, para exportar separado).
    static func toSRT(_ chunks: [SubtitleChunk]) -> String {
        var blocks: [String] = []
        for (i, c) in chunks.enumerated() {
            blocks.append("\(i + 1)\n\(srtStamp(c.from)) --> \(srtStamp(c.to))\n\(c.text)")
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private static func srtStamp(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = Int(total) % 60
        let ms = Int((total - Double(Int(total))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    private static func srtTime(_ raw: String) -> Double? {
        // "00:01:02,345" (o con punto). Tolera espacios alrededor.
        let clean = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        let parts = clean.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]),
              let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }
}
