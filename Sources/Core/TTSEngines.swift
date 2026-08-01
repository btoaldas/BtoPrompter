import AVFoundation
import AppKit
import Foundation

// Motores de síntesis: locales (Piper) y de nube (ElevenLabs, OpenAI, Gemini,
// Deepgram). Todos devuelven audio listo para reproducir; la app nunca envía
// nada fuera del Mac con proveedores locales.

enum TTSEngines {

    // MARK: Voces locales instaladas

    static var voicesDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BtoPrompter/Voices", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func installedLocalVoices() -> [LocalVoice] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: voicesDirectory,
                                                        includingPropertiesForKeys: nil) else { return [] }
        return entries.compactMap { dir in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            let model = dir.appendingPathComponent("voz.onnx")
            guard fm.fileExists(atPath: model.path) else { return nil }
            let display = (try? String(contentsOf: dir.appendingPathComponent("nombre.txt"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return LocalVoice(id: dir.lastPathComponent,
                              name: display?.isEmpty == false ? display! : dir.lastPathComponent,
                              modelURL: model)
        }.sorted { $0.name < $1.name }
    }

    // Instala una voz Piper (.onnx + .onnx.json) copiándola a la carpeta de la app.
    @discardableResult
    static func installLocalVoice(from onnx: URL, name: String) throws -> LocalVoice {
        let fm = FileManager.default
        let slug = name.folding(options: .diacriticInsensitive, locale: Locale(identifier: "es"))
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let dir = voicesDirectory.appendingPathComponent(slug.isEmpty ? UUID().uuidString : slug,
                                                         isDirectory: true)
        if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.copyItem(at: onnx, to: dir.appendingPathComponent("voz.onnx"))
        let config = URL(fileURLWithPath: onnx.path + ".json")
        if fm.fileExists(atPath: config.path) {
            try fm.copyItem(at: config, to: dir.appendingPathComponent("voz.onnx.json"))
        }
        try name.data(using: .utf8)?.write(to: dir.appendingPathComponent("nombre.txt"))
        return LocalVoice(id: dir.lastPathComponent, name: name,
                          modelURL: dir.appendingPathComponent("voz.onnx"))
    }

    static func removeLocalVoice(_ voice: LocalVoice) {
        try? FileManager.default.removeItem(at: voice.modelURL.deletingLastPathComponent())
    }

    // Motor Piper: ejecutable configurable; se autodetecta en rutas habituales.
    static var piperPath: String {
        get {
            let stored = Settings.string(.ttsPiperPath, default: "")
            if !stored.isEmpty, FileManager.default.isExecutableFile(atPath: stored) { return stored }
            return autodetectPiper() ?? ""
        }
        set { Settings.set(newValue, .ttsPiperPath) }
    }

    static func autodetectPiper() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/piper", "/usr/local/bin/piper",
            "\(home)/.betodicta/voz-engine/venv/bin/piper",
            "\(home)/bin/piper",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Síntesis

    static func synthesize(text: String, provider: TTSProviderID,
                           completion: @escaping (Result<Data, Error>) -> Void) {
        switch provider {
        case .appleSystem:
            completion(.failure(TTSError.engineMissing("Las voces del sistema se reproducen directamente.")))
        case .piperLocal:
            synthesizePiper(text: text, completion: completion)
        case .elevenLabs, .openAI, .gemini, .deepgram:
            synthesizeCloud(text: text, provider: provider, completion: completion)
        }
    }

    private static func synthesizePiper(text: String,
                                        completion: @escaping (Result<Data, Error>) -> Void) {
        let voiceID = Settings.string(.ttsLocalVoiceID, default: "")
        guard let voice = installedLocalVoices().first(where: { $0.id == voiceID })
                ?? installedLocalVoices().first else {
            completion(.failure(TTSError.engineMissing("No hay voces locales instaladas. Añade una en Configuración → Voz.")))
            return
        }
        let engine = piperPath
        guard !engine.isEmpty else {
            completion(.failure(TTSError.engineMissing("No se encontró el motor Piper. Indícalo en Configuración → Voz.")))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("btoprompter-tts-\(UUID().uuidString).wav")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: engine)
            process.arguments = ["-m", voice.modelURL.path, "-f", out.path]
            let stdin = Pipe()
            process.standardInput = stdin
            process.standardOutput = FileHandle.nullDevice
            let errPipe = Pipe()
            process.standardError = errPipe
            do {
                try process.run()
                stdin.fileHandleForWriting.write(Data(text.utf8))
                stdin.fileHandleForWriting.closeFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0,
                      let data = try? Data(contentsOf: out) else {
                    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                     encoding: .utf8)?.prefix(200) ?? ""
                    completion(.failure(TTSError.engineMissing("Piper falló: \(err)")))
                    return
                }
                try? FileManager.default.removeItem(at: out)
                completion(.success(data))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private static func synthesizeCloud(text: String, provider: TTSProviderID,
                                        completion: @escaping (Result<Data, Error>) -> Void) {
        guard let secretName = provider.secretName else {
            completion(.failure(TTSError.missingKey(provider)))
            return
        }
        let key = SecretsStore.get(secretName)
        guard !key.isEmpty else {
            completion(.failure(TTSError.missingKey(provider)))
            return
        }
        guard Settings.bool(.ttsCloudConsent, default: false) else {
            completion(.failure(TTSError.remote("Autoriza el envío del texto a proveedores externos en Configuración → Voz.")))
            return
        }
        let model = provider.configuredModel
        let voice = provider.configuredVoice
        var request: URLRequest
        var body: [String: Any] = [:]

        switch provider {
        case .elevenLabs:
            let vid = voice.isEmpty ? "21m00Tcm4TlvDq8ikWAM" : voice
            request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(vid)")!)
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
            body = ["text": text, "model_id": model]
        case .openAI:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body = ["model": model, "input": text,
                    "voice": voice.isEmpty ? "alloy" : voice, "response_format": "mp3"]
        case .deepgram:
            var comps = URLComponents(string: "https://api.deepgram.com/v1/speak")!
            comps.queryItems = [.init(name: "model", value: voice.isEmpty ? "aura-2-celeste-es" : voice)]
            request = URLRequest(url: comps.url!)
            request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
            body = ["text": text]
        case .gemini:
            let url = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
            request = URLRequest(url: URL(string: url)!)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            body = [
                "contents": [["parts": [["text": text]]]],
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": [
                        "voiceName": voice.isEmpty ? "Kore" : voice,
                    ]]],
                ],
            ]
        case .appleSystem, .piperLocal:
            completion(.failure(TTSError.engineMissing("Proveedor local")))
            return
        }

        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, (200...299).contains(status) else {
                let detail = String(data: data ?? Data(), encoding: .utf8)?.prefix(200) ?? ""
                completion(.failure(TTSError.remote("HTTP \(status). \(detail)")))
                return
            }
            // Gemini devuelve el audio en base64 dentro del JSON (PCM 24 kHz).
            if provider == .gemini {
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let candidates = json["candidates"] as? [[String: Any]],
                      let content = candidates.first?["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]],
                      let inline = parts.compactMap({ $0["inlineData"] as? [String: Any] }).first,
                      let b64 = inline["data"] as? String,
                      let pcm = Data(base64Encoded: b64) else {
                    completion(.failure(TTSError.remote("Respuesta de Gemini sin audio.")))
                    return
                }
                completion(.success(wavFromPCM16(pcm, sampleRate: 24000)))
                return
            }
            completion(.success(data))
        }.resume()
    }

    // Gemini entrega PCM crudo: se le pone cabecera WAV para poder reproducirlo.
    static func wavFromPCM16(_ pcm: Data, sampleRate: Int) -> Data {
        var header = Data()
        func append32(_ v: Int) { var x = UInt32(v).littleEndian; header.append(Data(bytes: &x, count: 4)) }
        func append16(_ v: Int) { var x = UInt16(v).littleEndian; header.append(Data(bytes: &x, count: 2)) }
        header.append("RIFF".data(using: .ascii)!)
        append32(36 + pcm.count)
        header.append("WAVEfmt ".data(using: .ascii)!)
        append32(16); append16(1); append16(1)
        append32(sampleRate); append32(sampleRate * 2); append16(2); append16(16)
        header.append("data".data(using: .ascii)!)
        append32(pcm.count)
        return header + pcm
    }

    // Comprobación de clave sin generar audio largo.
    static func validate(provider: TTSProviderID, apiKey: String,
                         completion: @escaping (Result<String, Error>) -> Void) {
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { completion(.failure(TTSError.missingKey(provider))); return }
        var request: URLRequest
        switch provider {
        case .elevenLabs:
            request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
        case .openAI:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .gemini:
            request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        case .deepgram:
            request = URLRequest(url: URL(string: "https://api.deepgram.com/v1/projects")!)
            request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        case .appleSystem, .piperLocal:
            completion(.success("proveedor local"))
            return
        }
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(status) {
                completion(.success(""))
            } else {
                completion(.failure(TTSError.remote("HTTP \(status)")))
            }
        }.resume()
    }

    // Voces disponibles en la cuenta de ElevenLabs (incluye clones propios).
    static func fetchElevenLabsVoices(completion: @escaping ([(id: String, label: String)]) -> Void) {
        let key = SecretsStore.get(TTSProviderID.elevenLabs.secretName ?? "")
        guard !key.isEmpty else { completion([]); return }
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let voices = json["voices"] as? [[String: Any]] else {
                completion([])
                return
            }
            let list = voices.compactMap { v -> (id: String, label: String)? in
                guard let id = v["voice_id"] as? String, let name = v["name"] as? String else { return nil }
                return (id: id, label: name)
            }
            completion(list)
        }.resume()
    }
}
