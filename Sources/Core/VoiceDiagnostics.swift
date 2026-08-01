import AVFoundation
import Foundation

// Diagnóstico local y acotado. No transmite nada. Las sesiones detalladas y el
// audio solo se crean si el usuario activa sus respectivos parámetros.

final class VoiceDiagnostics {
    static let shared = VoiceDiagnostics()

    private let queue = DispatchQueue(label: "com.bto.btoprompter.diagnostics")
    private let fm = FileManager.default
    private var sessionURL: URL?
    private var eventsHandle: FileHandle?
    private var audioFile: AVAudioFile?
    private var sessionStartedAt: Date?
    private var sessionID: String?

    private var rootURL: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BtoPrompter", isDirectory: true)
        return base.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    var directoryURL: URL { rootURL }
    var currentSessionPath: String? { queue.sync { sessionURL?.path } }

    private var pruneTimer: DispatchSourceTimer?

    private init() {
        try? fm.createDirectory(at: rootURL, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        prune()
        startPeriodicPrune()
    }

    // La poda también corre en caliente: una sesión larga con audio podía
    // superar los límites de espacio sin que nadie los aplicara hasta cerrarla.
    private func startPeriodicPrune() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 300, repeating: 300)
        timer.setEventHandler { [weak self] in self?.prune() }
        timer.resume()
        pruneTimer = timer
    }

    func operational(_ level: String, _ message: String) {
        // Con el diagnóstico apagado no se escribe nada al disco: antes este
        // era el único método sin comprobación y el log crecía igualmente.
        guard Settings.bool(.diagnosticsEnabled, default: false) || level == "ERROR" else { return }
        let sanitized = redact(message)
        queue.async {
            self.rotateOperationalLogIfNeeded()
            let line = "\(ISO8601DateFormatter().string(from: Date())) [\(level)] \(sanitized)\n"
            let url = self.rootURL.appendingPathComponent("BtoPrompter.log")
            if !self.fm.fileExists(atPath: url.path) { self.fm.createFile(atPath: url.path, contents: nil) }
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(line.utf8))
            }
            try? self.fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func startSession(speechID: UUID?, title: String, script: String) {
        let detailed = Settings.bool(.diagnosticsEnabled, default: false)
        let record = Settings.bool(.diagnosticsRecordAudio, default: false)
        guard detailed || record else { return }

        queue.sync {
            finishLocked(summary: nil)
            let id = Self.timestampID()
            let dir = rootURL.appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                sessionURL = dir
                sessionID = id
                sessionStartedAt = Date()

                let manifest: [String: Any] = [
                    "schema": 1,
                    "session_id": id,
                    "speech_id": speechID?.uuidString ?? "",
                    "title": title,
                    "started_at": ISO8601DateFormatter().string(from: Date()),
                    "diagnostics": detailed,
                    "audio_recording": record,
                    "local_only": true,
                    "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
                ]
                writeJSON(manifest, to: dir.appendingPathComponent("manifest.json"))
                // El contenido de la sesión (guion y transcripciones) es privado:
                // permisos explícitos, porque el umask deja 0644 por defecto.
                if detailed, Settings.bool(.diagnosticsIncludeScript, default: true) {
                    let scriptURL = dir.appendingPathComponent("script.txt")
                    try script.data(using: .utf8)?.write(to: scriptURL, options: .atomic)
                    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scriptURL.path)
                }
                if detailed {
                    let events = dir.appendingPathComponent("events.jsonl")
                    fm.createFile(atPath: events.path, contents: nil,
                                  attributes: [.posixPermissions: 0o600])
                    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: events.path)
                    eventsHandle = try FileHandle(forWritingTo: events)
                }
            } catch {
                operational("ERROR", "No se pudo crear sesión de diagnóstico: \(error.localizedDescription)")
                sessionURL = nil
            }
        }
        event("session_started", fields: ["title": title])
    }

    func startAudio(format: AVAudioFormat) {
        guard Settings.bool(.diagnosticsRecordAudio, default: false) else { return }
        queue.sync {
            guard let sessionURL, audioFile == nil else { return }
            do {
                let url = sessionURL.appendingPathComponent("voice.caf")
                audioFile = try AVAudioFile(forWriting: url, settings: format.settings,
                                            commonFormat: format.commonFormat,
                                            interleaved: format.isInterleaved)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                operational("ERROR", "No se pudo iniciar la grabación local: \(error.localizedDescription)")
            }
        }
    }

    func appendAudio(_ buffer: AVAudioPCMBuffer) {
        guard Settings.bool(.diagnosticsRecordAudio, default: false),
              let copy = Self.copyBuffer(buffer) else { return }
        queue.async {
            do { try self.audioFile?.write(from: copy) }
            catch { self.operational("ERROR", "Error guardando audio local: \(error.localizedDescription)") }
        }
    }

    func event(_ name: String, fields: [String: Any] = [:]) {
        guard Settings.bool(.diagnosticsEnabled, default: false) else { return }
        let safeFields = fields.reduce(into: [String: Any]()) { result, pair in
            let lowered = pair.key.lowercased()
            if lowered.contains("key") || lowered.contains("token") || lowered.contains("secret") {
                result[pair.key] = "[oculto]"
            } else if let string = pair.value as? String {
                result[pair.key] = redact(string)
            } else {
                result[pair.key] = pair.value
            }
        }
        queue.async {
            guard let handle = self.eventsHandle else { return }
            var payload = safeFields
            payload["at"] = ISO8601DateFormatter().string(from: Date())
            payload["event"] = name
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload),
                  var line = String(data: data, encoding: .utf8) else { return }
            line += "\n"
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    func transcript(_ event: VoiceTranscriptEvent) {
        self.event("transcript", fields: [
            "provider": event.provider.rawValue,
            "final": event.isFinal,
            "text": event.text,
        ])
    }

    func alignment(_ decision: VoiceAlignmentDecision) {
        var fields: [String: Any] = [
            "kind": decision.kind.rawValue,
            "from": decision.from,
            "matched_words": decision.matchedWords,
            "reason": decision.reason,
        ]
        if let destination = decision.to { fields["to"] = destination }
        event("alignment", fields: fields)
    }

    func finishSession(finalTranscript: String? = nil, wordsReached: Int? = nil) {
        queue.sync {
            var summary: [String: Any] = [:]
            if let sessionStartedAt { summary["seconds"] = Date().timeIntervalSince(sessionStartedAt) }
            if Settings.bool(.diagnosticsEnabled, default: false), let finalTranscript {
                summary["transcript"] = finalTranscript
            }
            if let wordsReached { summary["words_reached"] = wordsReached }
            summary["finished_at"] = ISO8601DateFormatter().string(from: Date())
            finishLocked(summary: summary)
        }
        prune()
    }

    func deleteAllSessions() {
        queue.sync {
            finishLocked(summary: nil)
            let sessions = rootURL.appendingPathComponent("sessions", isDirectory: true)
            try? fm.removeItem(at: sessions)
            try? fm.createDirectory(at: sessions, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }
    }

    private func finishLocked(summary: [String: Any]?) {
        if let summary, let sessionURL { writeJSON(summary, to: sessionURL.appendingPathComponent("summary.json")) }
        try? eventsHandle?.synchronize()
        try? eventsHandle?.close()
        eventsHandle = nil
        audioFile = nil
        sessionURL = nil
        sessionID = nil
        sessionStartedAt = nil
    }

    private func prune() {
        queue.async {
            let sessions = self.rootURL.appendingPathComponent("sessions", isDirectory: true)
            guard let urls = try? self.fm.contentsOfDirectory(at: sessions,
                                                               includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                                                               options: [.skipsHiddenFiles]) else { return }
            let retention = max(1, Settings.int(.diagnosticsRetentionDays, default: 14))
            let cutoff = Date().addingTimeInterval(-Double(retention) * 86_400)
            for url in urls {
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                if created < cutoff { try? self.fm.removeItem(at: url) }
            }

            let maxBytes = Int64(max(50, Settings.int(.diagnosticsMaxMegabytes, default: 500))) * 1_048_576
            var remaining = (try? self.fm.contentsOfDirectory(at: sessions,
                                                               includingPropertiesForKeys: [.creationDateKey],
                                                               options: [.skipsHiddenFiles])) ?? []
            remaining.sort {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a < b
            }
            var total = remaining.reduce(Int64(0)) { $0 + self.directorySize($1) }
            for url in remaining where total > maxBytes {
                let size = self.directorySize(url)
                try? self.fm.removeItem(at: url)
                total -= size
            }
        }
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private func rotateOperationalLogIfNeeded() {
        let url = rootURL.appendingPathComponent("BtoPrompter.log")
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 2_000_000 else { return }
        let old = rootURL.appendingPathComponent("BtoPrompter.previous.log")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: url, to: old)
    }

    private func writeJSON(_ object: [String: Any], to url: URL) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func redact(_ text: String) -> String {
        var value = text
        let patterns = [
            "gsk_[A-Za-z0-9_-]+",
            "sk-[A-Za-z0-9_-]{12,}",
            "Bearer [A-Za-z0-9._-]+",
            "(?i)(?:api[_-]?key|token|secret)=[^&\\s]+",
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                value = regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value),
                                                       withTemplate: "[secreto oculto]")
            }
        }
        return value
    }

    private static func timestampID() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))"
    }

    private static func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let src = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(src.count, dst.count) {
            guard let sourceData = src[index].mData, let destinationData = dst[index].mData else { continue }
            memcpy(destinationData, sourceData, Int(src[index].mDataByteSize))
            dst[index].mDataByteSize = src[index].mDataByteSize
        }
        return copy
    }
}
