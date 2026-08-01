import Foundation
import Speech

// Importadores de la biblioteca: texto/Markdown, PowerPoint y audio transcrito.
// Para añadir un formato nuevo: caso en importFiles + función privada aquí.

extension SpeechStore {

    func importFiles(urls: [URL], folder: String) {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            let title = url.deletingPathExtension().lastPathComponent
            switch ext {
            case "txt", "md", "markdown", "text":
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    addImported(title: title, body: text, folder: folder)
                } else if let text = try? String(contentsOf: url, encoding: .isoLatin1) {
                    addImported(title: title, body: text, folder: folder)
                } else {
                    importStatus = "No se pudo leer \(url.lastPathComponent)"
                }
            case "pptx":
                if let text = Self.extractPPTX(url) {
                    addImported(title: title, body: text, folder: folder)
                } else {
                    importStatus = "No se pudo leer \(url.lastPathComponent)"
                }
            case "m4a", "mp3", "wav", "aac", "aiff", "caf", "flac":
                transcribeAudio(url: url, title: title, folder: folder)
            default:
                importStatus = "Formato no soportado: .\(ext)"
            }
        }
    }

    private func addImported(title: String, body: String, folder: String) {
        let doc = newSpeech(title: title, body: body, folder: folder)
        PrompterModel.shared.selectedID = doc.id
        importStatus = nil
    }

    // MARK: PowerPoint

    // PPTX = ZIP con XML por diapositiva; extrae los runs de texto <a:t>.
    // El primer texto de cada diapositiva sale como título "## " (guía).
    static func extractPPTX(_ url: URL) -> String? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("btoprompter-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", "-q", url.path, "ppt/slides/*", "-d", tmp.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        do {
            try unzip.run()
            unzip.waitUntilExit()
        } catch { return nil }
        let slidesDir = tmp.appendingPathComponent("ppt/slides")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: slidesDir.path) else { return nil }
        let slideFiles = files
            .filter { $0.hasPrefix("slide") && $0.hasSuffix(".xml") }
            .sorted { a, b in
                let na = Int(a.dropFirst(5).dropLast(4)) ?? 0
                let nb = Int(b.dropFirst(5).dropLast(4)) ?? 0
                return na < nb
            }
        guard !slideFiles.isEmpty else { return nil }
        var sections: [String] = []
        let maxSlideBytes = 20 * 1024 * 1024
        for f in slideFiles {
            let fileURL = slidesDir.appendingPathComponent(f)
            // unzip materializa entradas de tipo symlink y String(contentsOf:) las
            // seguiría fuera del directorio temporal: solo archivos regulares y acotados.
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular,
                  (attrs[.size] as? Int ?? 0) <= maxSlideBytes else { continue }
            guard let xml = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            var texts: [String] = []
            for raw in Self.textRuns(in: xml) {
                let decoded = Self.decodeXMLEntities(raw).trimmingCharacters(in: .whitespaces)
                if !decoded.isEmpty { texts.append(decoded) }
            }
            guard !texts.isEmpty else { continue }
            var lines: [String] = ["## " + texts[0]]
            lines.append(contentsOf: texts.dropFirst())
            sections.append(lines.joined(separator: "\n"))
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    // Escaneo LINEAL de los runs <a:t …>…</a:t>. Sustituye al regex con
    // backtracking, cuyo coste cuadrático permitía un DoS con XML manipulado
    // (medido: 50 000 etiquetas sin cierre → ~51 s de CPU).
    static func textRuns(in xml: String) -> [String] {
        var out: [String] = []
        var cursor = xml.startIndex
        while let open = xml.range(of: "<a:t", range: cursor..<xml.endIndex) {
            cursor = open.upperBound
            // Debe ser exactamente <a:t> o <a:t atributos…> (no <a:tab/>).
            guard cursor < xml.endIndex else { break }
            let next = xml[cursor]
            guard next == ">" || next == " " else { continue }
            guard let openEnd = xml.range(of: ">", range: cursor..<xml.endIndex) else { break }
            guard let close = xml.range(of: "</a:t>", range: openEnd.upperBound..<xml.endIndex) else { break }
            out.append(String(xml[openEnd.upperBound..<close.lowerBound]))
            cursor = close.upperBound
        }
        return out
    }

    private static func decodeXMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: Audio

    // Transcripción con el motor de voz del sistema (autorización una sola vez).
    private func transcribeAudio(url: URL, title: String, folder: String) {
        importStatus = "Transcribiendo \(url.lastPathComponent)…"
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    self.importStatus = "Autoriza el reconocimiento de voz en Ajustes del Sistema → Privacidad."
                    return
                }
                let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
                    ?? SFSpeechRecognizer()
                guard let recognizer, recognizer.isAvailable else {
                    self.importStatus = "Reconocimiento de voz no disponible en este equipo."
                    return
                }
                let request = SFSpeechURLRecognitionRequest(url: url)
                request.shouldReportPartialResults = false
                if recognizer.supportsOnDeviceRecognition {
                    request.requiresOnDeviceRecognition = true
                }
                recognizer.recognitionTask(with: request) { result, error in
                    DispatchQueue.main.async {
                        if let result, result.isFinal {
                            self.addImported(title: title,
                                             body: result.bestTranscription.formattedString,
                                             folder: folder)
                        } else if let error {
                            self.importStatus = "Error al transcribir: \(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }
}
