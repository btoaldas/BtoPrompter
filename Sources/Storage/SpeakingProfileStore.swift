import Combine
import Foundation

// Perfil estadístico local del orador. No contiene audio ni API keys y nunca se
// transmite por sí solo. Resume ensayos válidos para producir recomendaciones
// de ritmo y un contexto opcional para Ensayo con IA.

struct SpeakingProfile: Codable, Equatable {
    var schema = 1
    var sessionCount = 0
    var totalWords = 0
    var totalSeconds: Double = 0
    var totalPhrases = 0
    var connectorCounts: [String: Int] = [:]
    var fillerCounts: [String: Int] = [:]
    var updatedAt: Date?

    var averageWPM: Int {
        guard totalSeconds > 0 else { return 0 }
        return Int((Double(totalWords) / (totalSeconds / 60)).rounded())
    }

    var averagePhraseWords: Int {
        guard totalPhrases > 0 else { return 0 }
        return Int((Double(totalWords) / Double(totalPhrases)).rounded())
    }
}

final class SpeakingProfileStore: ObservableObject {
    static let shared = SpeakingProfileStore()

    @Published private(set) var profile: SpeakingProfile

    private let fileURL: URL
    private let connectors = ["ademas", "entonces", "tambien", "claro", "realmente",
                              "finalmente", "primero", "luego", "porque", "por tanto"]
    private let fillers = ["eh", "este", "bueno", "pues", "digamos"]

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask)[0]
            .appendingPathComponent("BtoPrompter", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        fileURL = directory.appendingPathComponent("speaking-profile.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(SpeakingProfile.self, from: data) {
            profile = saved
        } else {
            profile = SpeakingProfile()
        }
    }

    func record(transcript: String, seconds: Double) {
        guard Settings.bool(.speechProfileEnabled, default: false), seconds >= 10 else { return }
        let words = VoiceMatcher.normalizedWords(transcript)
        guard words.count >= 20 else { return }

        var next = profile
        next.sessionCount += 1
        next.totalWords += words.count
        next.totalSeconds += seconds
        let punctuation = transcript.reduce(0) { count, char in
            count + (".!?;:…".contains(char) ? 1 : 0)
        }
        next.totalPhrases += max(1, punctuation)
        for word in words where connectors.contains(word) {
            next.connectorCounts[word, default: 0] += 1
        }
        for word in words where fillers.contains(word) {
            next.fillerCounts[word, default: 0] += 1
        }
        next.updatedAt = Date()
        profile = next
        save()
    }

    func reset() {
        profile = SpeakingProfile()
        try? FileManager.default.removeItem(at: fileURL)
    }

    var summary: String {
        let p = profile
        guard p.sessionCount > 0 else { return "Aún no hay ensayos suficientes." }
        return "\(p.sessionCount) ensayo(s) · \(p.averageWPM) ppm · frases de ~\(p.averagePhraseWords) palabras"
    }

    var stylePrompt: String {
        let p = profile
        guard p.sessionCount > 0 else { return "" }
        let connectors = top(p.connectorCounts).joined(separator: ", ")
        let fillers = top(p.fillerCounts).joined(separator: ", ")
        var lines = [
            "Perfil local del orador basado en \(p.sessionCount) ensayos:",
            "- Ritmo habitual: aproximadamente \(p.averageWPM) palabras por minuto.",
            "- Longitud habitual de frase: aproximadamente \(p.averagePhraseWords) palabras.",
        ]
        if !connectors.isEmpty { lines.append("- Conectores frecuentes: \(connectors).") }
        if !fillers.isEmpty { lines.append("- Muletillas observadas que conviene no añadir al guion: \(fillers).") }
        lines.append("Marca respiraciones y énfasis de forma compatible con este ritmo, sin inventar palabras ni cambiar la voz del autor.")
        return lines.joined(separator: "\n")
    }

    private func top(_ counts: [String: Int]) -> [String] {
        counts.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key
        }.prefix(4).map(\.key)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: fileURL.path)
    }
}
