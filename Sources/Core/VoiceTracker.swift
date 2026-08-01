import AVFoundation
import Foundation
import Speech

// Seguimiento por voz: el prompter escucha al orador (reconocimiento LOCAL de
// Apple) y avanza el karaoke al ritmo real. Si el orador improvisa o se salta
// una frase, el matcher espera hasta reencontrarlo dentro de la ventana.

// Matcher puro y testeable (ver SelfTest).
enum VoiceMatcher {
    static func normalize(_ w: String) -> String {
        w.lowercased()
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "es"))
            .filter { $0.isLetter || $0.isNumber }
    }

    // Busca las últimas palabras oídas dentro de la ventana del guion.
    // Devuelve el índice global de la ÚLTIMA palabra reconocida, o nil.
    static func findPosition(heard: [String], script: [String], current: Int,
                             windowAhead: Int = 40, windowBack: Int = 3) -> Int? {
        let cleaned = heard.map(normalize).filter { !$0.isEmpty }
        guard !cleaned.isEmpty, !script.isEmpty else { return nil }
        let needle = Array(cleaned.suffix(3))
        let start = max(0, current - windowBack)
        let end = min(script.count, current + windowAhead)
        guard start < end else { return nil }
        let n = needle.count
        if n >= 2 {
            var i = start
            while i <= end - n {
                var ok = true
                for j in 0..<n where script[i + j] != needle[j] { ok = false; break }
                if ok { return i + n - 1 }   // el match más cercano gana
                i += 1
            }
        }
        // Última palabra sola, solo si es distintiva (evita falsos con "de", "la"…).
        if let last = needle.last, last.count > 3 {
            for i in start..<end where script[i] == last { return i }
        }
        return nil
    }
}

final class VoiceTracker {
    static let shared = VoiceTracker()

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartWork: DispatchWorkItem?
    private(set) var running = false

    func start() {
        guard !running else { return }
        SFSpeechRecognizer.requestAuthorization { auth in
            DispatchQueue.main.async {
                guard auth == .authorized else {
                    PrompterModel.shared.voiceStatus = "Autoriza el reconocimiento de voz en Privacidad."
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        guard granted else {
                            PrompterModel.shared.voiceStatus = "Autoriza el micrófono en Privacidad."
                            return
                        }
                        self.begin()
                    }
                }
            }
        }
    }

    private func begin() {
        guard !running else { return }
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES")) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            PrompterModel.shared.voiceStatus = "Reconocimiento de voz no disponible."
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true   // privacidad: todo local
        }
        request = req
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            PrompterModel.shared.voiceStatus = "No se pudo abrir el micrófono: \(error.localizedDescription)"
            return
        }
        running = true
        PrompterModel.shared.voiceActive = true
        PrompterModel.shared.voiceStatus = nil
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                if let result {
                    let words = result.bestTranscription.formattedString
                        .split(whereSeparator: { $0.isWhitespace }).map(String.init)
                    PrompterModel.shared.voiceHeard(words)
                }
                if error != nil, self?.running == true {
                    self?.restartSoon()   // el sistema corta sesiones largas
                }
            }
        }
        // Refresco periódico: las sesiones de dictado pierden precisión con el tiempo.
        let work = DispatchWorkItem { [weak self] in self?.restartNow() }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: work)
    }

    private func restartSoon() {
        teardown()
        let work = DispatchWorkItem { [weak self] in self?.begin() }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func restartNow() {
        guard running else { return }
        teardown()
        begin()
    }

    func stop() {
        restartWork?.cancel()
        restartWork = nil
        teardown()
        PrompterModel.shared.voiceActive = false
    }

    private func teardown() {
        running = false
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
