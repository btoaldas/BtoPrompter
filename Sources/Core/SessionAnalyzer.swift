import Foundation

// Analiza una sesión grabada (words.jsonl + events.jsonl + script.txt) y saca
// un informe de cómo se leyó realmente: ritmo por tramos, pausas, dónde se
// improvisó y dónde el reconocedor se quedó atrás. Todo el cálculo es local.

struct SessionReport {
    struct Pause {
        let afterWord: String
        let index: Int
        let seconds: Double
    }
    struct Segment {
        let label: String
        let wpm: Int
        let words: Int
    }

    let sessionID: String
    let title: String
    let words: Int
    let seconds: Double
    let averageWPM: Int
    let voiceDrivenRatio: Double     // proporción avanzada por voz
    let longestPauses: [Pause]
    let slowestSegments: [Segment]
    let fastestSegments: [Segment]
    let manualCorrections: Int
    let transcriptSample: String

    var summaryText: String {
        var lines: [String] = []
        lines.append("Sesión «\(title)» · \(words) palabras en \(Self.time(seconds)) · ritmo medio \(averageWPM) ppm")
        lines.append(String(format: "Avance por voz: %.0f %% del guion", voiceDrivenRatio * 100))
        if manualCorrections > 0 {
            lines.append("Correcciones manuales durante la lectura: \(manualCorrections)")
        }
        if !longestPauses.isEmpty {
            let list = longestPauses.prefix(5).map {
                String(format: "«%@» (%.1f s)", $0.afterWord, $0.seconds)
            }.joined(separator: ", ")
            lines.append("Pausas más largas después de: \(list)")
        }
        if !slowestSegments.isEmpty {
            lines.append("Tramos más lentos: " + slowestSegments.prefix(3)
                .map { "\($0.label) (\($0.wpm) ppm)" }.joined(separator: ", "))
        }
        if !fastestSegments.isEmpty {
            lines.append("Tramos más rápidos: " + fastestSegments.prefix(3)
                .map { "\($0.label) (\($0.wpm) ppm)" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    static func time(_ s: Double) -> String {
        let total = Int(s.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

enum SessionAnalyzer {

    static var sessionsDirectory: URL {
        VoiceDiagnostics.shared.directoryURL.appendingPathComponent("sessions", isDirectory: true)
    }

    static func availableSessions() -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: sessionsDirectory,
                                                        includingPropertiesForKeys: nil) else { return [] }
        return entries
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func analyze(session dir: URL) -> SessionReport? {
        let manifest = (try? Data(contentsOf: dir.appendingPathComponent("manifest.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let title = (manifest["title"] as? String) ?? dir.lastPathComponent

        guard let wordsRaw = try? String(contentsOf: dir.appendingPathComponent("words.jsonl"),
                                         encoding: .utf8) else { return nil }
        struct Row { let i: Int; let w: String; let t: Double; let src: String }
        var rows: [Row] = []
        for line in wordsRaw.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let i = o["i"] as? Int, let w = o["w"] as? String else { continue }
            let t = (o["t_session"] as? Double) ?? 0
            rows.append(Row(i: i, w: w, t: t, src: (o["src"] as? String) ?? "tiempo"))
        }
        guard rows.count >= 2 else { return nil }

        let seconds = max(0.001, (rows.last!.t - rows.first!.t))
        let advanced = rows.count
        let averageWPM = Int((Double(advanced) / seconds * 60).rounded())
        let voiceCount = rows.filter { $0.src == "voz" }.count
        let voiceRatio = Double(voiceCount) / Double(rows.count)

        // Pausas: hueco entre palabras consecutivas muy por encima del ritmo.
        let expected = seconds / Double(rows.count)
        var pauses: [SessionReport.Pause] = []
        for k in 1..<rows.count {
            let gap = rows[k].t - rows[k - 1].t
            if gap > max(1.2, expected * 4) {
                pauses.append(.init(afterWord: rows[k - 1].w, index: rows[k - 1].i, seconds: gap))
            }
        }
        pauses.sort { $0.seconds > $1.seconds }

        // Ritmo por tramos de 25 palabras.
        var segments: [SessionReport.Segment] = []
        let step = 25
        var k = 0
        while k + step < rows.count {
            let a = rows[k], b = rows[k + step]
            let dt = max(0.001, b.t - a.t)
            let wpm = Int((Double(step) / dt * 60).rounded())
            segments.append(.init(label: "«\(a.w) …»", wpm: wpm, words: step))
            k += step
        }
        let slowest = segments.sorted { $0.wpm < $1.wpm }
        let fastest = segments.sorted { $0.wpm > $1.wpm }

        // Correcciones manuales y muestra de transcripción desde events.jsonl.
        var manual = 0
        var transcripts: [String] = []
        if let eventsRaw = try? String(contentsOf: dir.appendingPathComponent("events.jsonl"),
                                       encoding: .utf8) {
            for line in eventsRaw.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let name = (o["event"] as? String) ?? ""
                if name == "manual_skip" || name == "manual_jump" { manual += 1 }
                if name == "transcript", let text = o["text"] as? String, !text.isEmpty {
                    transcripts.append(text)
                }
            }
        }

        return SessionReport(
            sessionID: dir.lastPathComponent,
            title: title,
            words: advanced,
            seconds: seconds,
            averageWPM: averageWPM,
            voiceDrivenRatio: voiceRatio,
            longestPauses: Array(pauses.prefix(8)),
            slowestSegments: Array(slowest.prefix(3)),
            fastestSegments: Array(fastest.prefix(3)),
            manualCorrections: manual,
            transcriptSample: transcripts.suffix(8).joined(separator: " ")
        )
    }

    // Informe combinado de las últimas sesiones, base del perfil.
    static func combinedReport(limit: Int = 5) -> (text: String, reports: [SessionReport]) {
        let reports = availableSessions().prefix(limit).compactMap { analyze(session: $0) }
        guard !reports.isEmpty else {
            return ("Todavía no hay sesiones analizables. Activa el diagnóstico y haz un ensayo.", [])
        }
        let text = reports.map(\.summaryText).joined(separator: "\n\n")
        return (text, reports)
    }
}
