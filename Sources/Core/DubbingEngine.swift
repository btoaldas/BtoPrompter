import Foundation

// Doblaje del vídeo con IA: traduce los subtítulos al idioma elegido y
// sintetiza cada frase con el TTS configurado (ElevenLabs u otro proveedor de
// Ajustes → Lectura), alineando cada audio a su tiempo real. Las frases
// dobladas entran como capas de audio normales (editables una a una) y el
// micrófono original se baja a cero — el usuario decide si lo devuelve.
//
// v1: UNA voz para todo el vídeo (la configurada en Lectura). Multi-orador
// queda para después. Cada frase es UNA llamada al proveedor: se avisa del
// costo antes de lanzar.

@MainActor
final class DubbingEngine: ObservableObject {
    static let shared = DubbingEngine()

    @Published var running = false
    @Published var progress = ""
    @Published var status: String? = nil

    // Traduce (si language != nil) y sintetiza frase a frase, en secuencia
    // (los proveedores de TTS castigan el paralelismo). Devuelve las capas
    // de audio listas para el proyecto.
    func dub(chunks: [SubtitleChunk], language: (code: String, name: String)?,
             folder: URL,
             completion: @escaping (Result<[AudioLayer], Error>) -> Void) {
        guard !running else { return }
        guard !chunks.isEmpty else {
            completion(.failure(NSError(domain: "Dubbing", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No hay subtítulos de los que doblar"])))
            return
        }
        running = true
        status = nil

        func synthesizeAll(_ finalChunks: [SubtitleChunk]) {
            let dirName = "doblaje-\(language?.code ?? "orig")"
            let dir = folder.appendingPathComponent(dirName, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var layers: [AudioLayer] = []
            let provider = TTSProviderID(rawValue: Settings.string(.ttsProvider, default: "tts_elevenlabs"))
                ?? .elevenLabs

            func next(_ index: Int) {
                guard index < finalChunks.count else {
                    self.running = false
                    self.progress = ""
                    completion(.success(layers))
                    return
                }
                self.progress = "Doblando frase \(index + 1) de \(finalChunks.count)…"
                let chunk = finalChunks[index]
                TTSEngines.synthesize(text: chunk.text, provider: provider) { result in
                    DispatchQueue.main.async {
                        switch result {
                        case .success(let data):
                            let url = dir.appendingPathComponent("frase-\(index + 1).mp3")
                            do {
                                try data.write(to: url)
                                var layer = AudioLayer(path: url.path,
                                                       name: "\(dirName) · frase \(index + 1)")
                                layer.volume = 1.0
                                layer.projectStart = chunk.from
                                layers.append(layer)
                            } catch {
                                self.status = "No se pudo guardar la frase \(index + 1)"
                            }
                            next(index + 1)
                        case .failure(let error):
                            // Un fallo no tira el doblaje entero: se anota y sigue.
                            self.status = "Frase \(index + 1): \(error.localizedDescription)"
                            next(index + 1)
                        }
                    }
                }
            }
            next(0)
        }

        if let language {
            guard let config = SubtitleAI.ProviderConfig.current() else {
                running = false
                completion(.failure(NSError(domain: "Dubbing", code: 2, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Sin proveedor de IA para traducir (Ajustes → Ensayo IA)"])))
                return
            }
            progress = "Traduciendo \(chunks.count) frases al \(language.name)…"
            SubtitleAI.translate(chunks, to: language.name, config: config) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let translated):
                        synthesizeAll(translated)
                    case .failure(let error):
                        self.running = false
                        self.progress = ""
                        completion(.failure(error))
                    }
                }
            }
        } else {
            synthesizeAll(chunks)
        }
    }
}
