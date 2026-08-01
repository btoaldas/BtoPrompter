import Foundation

// Alineación conservadora voz ↔ guion. La regla de seguridad es absoluta:
// este componente nunca devuelve una posición anterior a la ya confirmada.
// Los saltos grandes o las frases repetidas necesitan confirmación adicional.

struct VoiceMatchCandidate: Equatable {
    let position: Int          // índice de la última palabra reconocida
    let matchedWords: Int
    let score: Double
    let occurrences: Int
    let jump: Int

    var needsConfirmation: Bool {
        jump > 6 || occurrences > 1 || matchedWords < 3
    }
}

struct VoiceAlignmentDecision {
    enum Kind: String {
        case advanced, pending, ignored, ambiguous
    }
    let kind: Kind
    let from: Int
    let to: Int?
    let matchedWords: Int
    let reason: String
}

enum VoiceMatcher {
    static func normalize(_ word: String) -> String {
        word.lowercased()
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "es"))
            .filter { $0.isLetter || $0.isNumber }
    }

    static func normalizedWords(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func nearEqual(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        guard lhs.count >= 5, rhs.count >= 5, abs(lhs.count - rhs.count) <= 1 else { return false }
        // Una sola sustitución/inserción/eliminación para errores típicos del STT.
        let a = Array(lhs), b = Array(rhs)
        var i = 0, j = 0, edits = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count > b.count { i += 1 }
            else if b.count > a.count { j += 1 }
            else { i += 1; j += 1 }
        }
        if i < a.count || j < b.count { edits += 1 }
        return edits <= 1
    }

    private static func phraseOccurrences(_ needle: ArraySlice<String>, in script: [String]) -> Int {
        guard !needle.isEmpty, script.count >= needle.count else { return 0 }
        var count = 0
        for start in 0...(script.count - needle.count) {
            var ok = true
            for offset in 0..<needle.count where !nearEqual(script[start + offset], needle[needle.startIndex + offset]) {
                ok = false
                break
            }
            if ok { count += 1 }
        }
        return count
    }

    static func candidate(heard: [String], script: [String], current: Int,
                          maxJump: Int = 60, sensitivity: Double = 0.72) -> VoiceMatchCandidate? {
        let cleaned = heard.map(normalize).filter { !$0.isEmpty }
        guard cleaned.count >= 2, !script.isEmpty, current < script.count else { return nil }

        let searchStart = max(0, current - 6)
        let searchEnd = min(script.count, current + max(4, maxJump) + 8)
        guard searchStart < searchEnd else { return nil }

        var ranked: [VoiceMatchCandidate] = []
        let maximumLength = min(8, cleaned.count)
        for length in stride(from: maximumLength, through: 2, by: -1) {
            let needle = cleaned.suffix(length)
            guard searchEnd - searchStart >= length else { continue }
            let globalOccurrences = phraseOccurrences(needle, in: script)

            for start in searchStart...(searchEnd - length) {
                var exact = 0
                var fuzzy = 0
                for offset in 0..<length {
                    let a = script[start + offset]
                    let b = needle[needle.startIndex + offset]
                    if a == b { exact += 1 }
                    else if nearEqual(a, b) { fuzzy += 1 }
                }
                let quality = (Double(exact) + Double(fuzzy) * 0.72) / Double(length)
                let unmatched = length - exact - fuzzy
                // Una palabra completamente distinta puede apuntar a otra
                // aparición. Los errores ortográficos cercanos sí se toleran,
                // pero una sustitución completa hace que esperemos más contexto.
                guard unmatched == 0,
                      quality >= sensitivity,
                      exact >= min(2, length) else { continue }
                let end = start + length - 1
                let next = end + 1
                guard next > current else { continue }
                let jump = next - current
                guard jump <= maxJump else { continue }
                let proximityPenalty = Double(max(0, start - current)) * 0.18
                let duplicatePenalty = globalOccurrences > 1 ? Double(globalOccurrences - 1) * 1.2 : 0
                let score = Double(length) * 4 + quality * 5 - proximityPenalty - duplicatePenalty
                ranked.append(VoiceMatchCandidate(position: end, matchedWords: length,
                                                  score: score, occurrences: globalOccurrences,
                                                  jump: jump))
            }
            // Una frase larga y clara es mejor que cualquier coincidencia corta.
            if ranked.contains(where: { $0.matchedWords == length }) && length >= 4 { break }
        }

        let sorted = ranked.sorted {
            if abs($0.score - $1.score) > 0.001 { return $0.score > $1.score }
            if $0.jump != $1.jump { return $0.jump < $1.jump }
            return $0.position < $1.position
        }
        guard let best = sorted.first else { return nil }
        if sorted.count > 1 {
            let second = sorted[1]
            // Dos apariciones casi igual de probables y alejadas: no adivinar.
            if abs(best.score - second.score) < 1.0,
               abs(best.position - second.position) > 3,
               best.matchedWords < 5 {
                return nil
            }
        }
        return best
    }

    // Compatibilidad con pruebas y llamadas antiguas.
    static func findPosition(heard: [String], script: [String], current: Int,
                             windowAhead: Int = 40, windowBack: Int = 3) -> Int? {
        candidate(heard: heard, script: script, current: current,
                  maxJump: windowAhead, sensitivity: 0.72)?.position
    }
}

final class VoiceAlignmentGuard {
    private var confirmedIndex = 0
    private var pendingPosition: Int?
    private var pendingHits = 0
    private var lastHeard: [String] = []

    func reset(at index: Int = 0) {
        confirmedIndex = max(0, index)
        pendingPosition = nil
        pendingHits = 0
        lastHeard = []
    }

    func synchronize(to index: Int) {
        confirmedIndex = max(confirmedIndex, index)
        if let pendingPosition, pendingPosition < confirmedIndex {
            self.pendingPosition = nil
            pendingHits = 0
        }
    }

    func evaluate(text: String, isFinal: Bool, script: [String], current: Int,
                  maxJump: Int, sensitivity: Double,
                  confirmLargeJumps: Bool) -> VoiceAlignmentDecision {
        confirmedIndex = max(confirmedIndex, current)
        let heard = VoiceMatcher.normalizedWords(text)
        guard heard != lastHeard else {
            return VoiceAlignmentDecision(kind: .ignored, from: current, to: nil,
                                          matchedWords: 0,
                                          reason: "resultado duplicado sin palabras nuevas")
        }
        lastHeard = heard
        guard let match = VoiceMatcher.candidate(heard: heard, script: script,
                                                  current: confirmedIndex,
                                                  maxJump: maxJump,
                                                  sensitivity: sensitivity) else {
            return VoiceAlignmentDecision(kind: .ignored, from: current, to: nil,
                                          matchedWords: 0,
                                          reason: "sin coincidencia suficientemente segura")
        }
        let proposed = min(script.count - 1, match.position + 1)
        guard proposed > confirmedIndex else {
            return VoiceAlignmentDecision(kind: .ignored, from: current, to: nil,
                                          matchedWords: match.matchedWords,
                                          reason: "posición antigua descartada")
        }

        // Si la misma frase existe en varios lugares, no elegir una aparición
        // por proximidad. Esperamos una palabra posterior que haga único el
        // contexto; esto sacrifica un instante de avance para impedir saltos.
        if match.occurrences > 1 {
            pendingPosition = nil
            pendingHits = 0
            return VoiceAlignmentDecision(kind: .ambiguous, from: current, to: proposed,
                                          matchedWords: match.matchedWords,
                                          reason: "frase repetida; esperando contexto único")
        }

        let mustConfirm = confirmLargeJumps && match.needsConfirmation && !isFinal
        if mustConfirm {
            if let pendingPosition, abs(pendingPosition - proposed) <= 2 {
                pendingHits += 1
                self.pendingPosition = max(pendingPosition, proposed)
            } else {
                pendingPosition = proposed
                pendingHits = 1
            }
            guard pendingHits >= 2 else {
                return VoiceAlignmentDecision(kind: .pending, from: current, to: proposed,
                                              matchedWords: match.matchedWords,
                                              reason: "salto o frase repetida pendiente de confirmación")
            }
        }

        // Un resultado final puede confirmar un salto solo con contexto fuerte.
        if isFinal, match.needsConfirmation, match.matchedWords < 4 {
            return VoiceAlignmentDecision(kind: .pending, from: current, to: proposed,
                                          matchedWords: match.matchedWords,
                                          reason: "resultado final con contexto insuficiente")
        }

        confirmedIndex = proposed
        pendingPosition = nil
        pendingHits = 0
        return VoiceAlignmentDecision(kind: .advanced, from: current, to: proposed,
                                      matchedWords: match.matchedWords,
                                      reason: "coincidencia monotónica confirmada")
    }
}
