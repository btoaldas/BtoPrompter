import AVFoundation
import Foundation
import Speech

// Subtítulos SIN teleprompter: se transcribe el audio de la propia grabación
// y se arman las frases con sus tiempos. Apple devuelve el instante de cada
// palabra (`segments`), así que los subtítulos quedan sincronizados de verdad
// sin que nadie haya leído un guion.
//
// Es el camino para grabar tutoriales y clases hablando libre: grabas, pulsas
// «Transcribir el audio» y ya tienes los subtítulos (y de ahí las
// traducciones y el doblaje, que ya existen).

@MainActor
final class SubtitleTranscriber: ObservableObject {
    static let shared = SubtitleTranscriber()

    @Published var running = false
    @Published var progress = ""

    // Busca el mejor audio de la carpeta: la copia suelta si existe, si no el
    // archivo de cámara (que lleva el micrófono), si no el de pantalla.
    // Solo mira el disco: se puede llamar desde cualquier hilo.
    nonisolated static func bestAudioSource(inFolder folder: URL) -> URL? {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        // Con cortes hay varias partes por pieza: siempre la parte 1, elegida
        // determinísticamente (el orden de carpeta no lo es).
        let preferred: [(prefix: String, ext: String)] = [
            ("audio-webcam-", "m4a"), ("camara-", "mov"),
            ("audio-sistema-", "m4a"), ("pantalla-", "mov"),
        ]
        for p in preferred {
            if let hit = CompositionBuilder.primaryFile(prefix: p.prefix, in: files,
                                                        ext: p.ext) {
                return hit
            }
        }
        return nil
    }

    func transcribe(url: URL, locale: String = "es-ES",
                    completion: @escaping (Result<[SubtitleChunk], Error>) -> Void) {
        guard !running else { return }
        running = true
        progress = "Pidiendo permiso de reconocimiento…"

        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else {
                    self.finish(completion, .failure(NSError(domain: "Transcriber", code: 1, userInfo: [
                        NSLocalizedDescriptionKey:
                            "Autoriza el reconocimiento de voz en Ajustes del Sistema → Privacidad"])))
                    return
                }
                guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
                        ?? SFSpeechRecognizer(), recognizer.isAvailable else {
                    self.finish(completion, .failure(NSError(domain: "Transcriber", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "Reconocimiento de voz no disponible"])))
                    return
                }
                self.progress = "Transcribiendo \(url.lastPathComponent)…"
                let request = SFSpeechURLRecognitionRequest(url: url)
                request.shouldReportPartialResults = false
                // En local no sale nada del equipo; si el modelo no está,
                // Apple usa su servicio (y el usuario ya autorizó el dictado).
                if recognizer.supportsOnDeviceRecognition {
                    request.requiresOnDeviceRecognition = true
                }
                recognizer.recognitionTask(with: request) { result, error in
                    Task { @MainActor in
                        if let error {
                            self.finish(completion, .failure(error))
                            return
                        }
                        guard let result, result.isFinal else { return }
                        let words = result.bestTranscription.segments.map {
                            SubtitleBuilder.TimedWord(w: $0.substring, t: $0.timestamp)
                        }
                        guard !words.isEmpty else {
                            self.finish(completion, .failure(NSError(
                                domain: "Transcriber", code: 3, userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "No se reconoció ninguna palabra en el audio"])))
                            return
                        }
                        self.finish(completion, .success(SubtitleBuilder.group(words)))
                    }
                }
            }
        }
    }

    private func finish(_ completion: @escaping (Result<[SubtitleChunk], Error>) -> Void,
                        _ result: Result<[SubtitleChunk], Error>) {
        running = false
        progress = ""
        completion(result)
    }
}
