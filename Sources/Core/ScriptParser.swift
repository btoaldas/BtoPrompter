import Foundation
import NaturalLanguage

// Parser del guion: texto plano/Markdown ligero → [Chunk] listos para el karaoke.
// Función pura y testeable (ver SelfTest.swift). Sintaxis soportada:
//   # / ## / ###   títulos (guía opcional según `guideTitles`)
//   - / * / •      viñetas
//   // texto       guía: se ve pero no se lee
//   [v+N] [v-N] [v=]  marca de velocidad del tramo, al inicio de línea
//   **x** *x* `x` _x_  marcadores inline (se limpian para lectura)

enum ChunkStyle { case normal, h1, h2, bullet }

struct Chunk: Identifiable {
    let id: Int
    let words: [String]
    let range: Range<Int>
    let isParagraphEnd: Bool
    let style: ChunkStyle
    var isGuide: Bool = false   // se ve pero no se lee: el karaoke la salta
    var speedDelta: Int = 0     // ajuste de ppm para este tramo (marcas [v+N]/[v-N])
}

enum ScriptParser {

    static func parse(_ text: String, guideTitles: Bool) -> [Chunk] {
        var result: [Chunk] = []
        var offset = 0
        var cid = 0
        var currentDelta = 0
        let tokenizer = NLTokenizer(unit: .sentence)
        let speedMark = try! NSRegularExpression(pattern: "^\\[v([+-]\\d{1,2}|=)\\]\\s*")

        func stripInline(_ s: String) -> String {
            var out = s
            for marker in ["**", "__", "*", "_", "`"] {
                out = out.replacingOccurrences(of: marker, with: "")
            }
            return out
        }

        func appendChunk(_ sentence: String, style: ChunkStyle, paragraphEnd: Bool, guide: Bool = false) {
            let words = sentence.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !words.isEmpty else { return }
            // Las guías no aportan palabras leíbles: rango vacío, el karaoke las salta.
            let range = guide ? offset..<offset : offset..<(offset + words.count)
            result.append(Chunk(id: cid, words: words, range: range,
                                isParagraphEnd: paragraphEnd, style: style, isGuide: guide,
                                speedDelta: guide ? 0 : currentDelta))
            cid += 1
            if !guide { offset += words.count }
        }

        // Marcas [v+N]/[v-N]/[v=] al inicio de línea: ajustan la velocidad del tramo.
        func consumeSpeedMarks(_ line: String) -> String {
            var out = line
            while let m = speedMark.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
                  let full = Range(m.range, in: out), let val = Range(m.range(at: 1), in: out) {
                let v = String(out[val])
                let limits = Settings.Limits.speedDeltaRange
                currentDelta = v == "=" ? 0 : min(max(Int(v) ?? 0, limits.lowerBound), limits.upperBound)
                out.removeSubrange(full)
            }
            return out.trimmingCharacters(in: .whitespaces)
        }

        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for rawLine in lines {
            let line = consumeSpeedMarks(rawLine)
            if line.isEmpty { continue }
            if line.hasPrefix("//") {
                let text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                appendChunk(stripInline(text), style: .normal, paragraphEnd: true, guide: true)
            } else if line.hasPrefix("# ") {
                appendChunk(stripInline(String(line.dropFirst(2))), style: .h1, paragraphEnd: true, guide: guideTitles)
            } else if line.hasPrefix("## ") {
                appendChunk(stripInline(String(line.dropFirst(3))), style: .h2, paragraphEnd: true, guide: guideTitles)
            } else if line.hasPrefix("### ") {
                appendChunk(stripInline(String(line.dropFirst(4))), style: .h2, paragraphEnd: true, guide: guideTitles)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                appendChunk("• " + stripInline(String(line.dropFirst(2))), style: .bullet, paragraphEnd: true)
            } else {
                let clean = stripInline(line)
                tokenizer.string = clean
                var sentences: [String] = []
                tokenizer.enumerateTokens(in: clean.startIndex..<clean.endIndex) { r, _ in
                    let s = String(clean[r]).trimmingCharacters(in: .whitespaces)
                    if !s.isEmpty { sentences.append(s) }
                    return true
                }
                if sentences.isEmpty { sentences = [clean] }
                for (si, sentence) in sentences.enumerated() {
                    appendChunk(sentence, style: .normal, paragraphEnd: si == sentences.count - 1)
                }
            }
        }
        return result
    }
}
