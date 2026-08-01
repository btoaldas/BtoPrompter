import AVFoundation
import Foundation

// Cliente unificado para STT en vivo de nube. Todos reciben PCM16/16 kHz/mono
// desde el mismo capturador; las diferencias de protocolo quedan encapsuladas.

final class CloudSpeechProvider: NSObject, LiveSpeechProvider {
    let id: VoiceProviderID
    var onTranscript: ((VoiceTranscriptEvent) -> Void)?
    var onError: ((Error) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var stopped = false
    private let lock = NSLock()
    private var finals: [String] = []
    private var partial = ""
    private var sequence = 0
    private var completion: ((Result<Void, Error>) -> Void)?
    private var timeoutWork: DispatchWorkItem?

    init(id: VoiceProviderID) {
        precondition(!id.isLocal && id != .appleCloud)
        self.id = id
    }

    func start(inputFormat: AVAudioFormat, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let secretName = id.secretName else {
            completion(.failure(VoiceProviderError.missingKey(id)))
            return
        }
        let key = SecretsStore.get(secretName)
        guard !key.isEmpty else { completion(.failure(VoiceProviderError.missingKey(id))); return }
        stopped = false
        finals = []
        partial = ""
        sequence = 0
        self.completion = completion

        switch id {
        case .gladia:
            initializeGladia(key: key)
        case .elevenLabs:
            var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
            components.queryItems = [
                .init(name: "model_id", value: VoiceProviderID.elevenLabs.defaultModel),
                .init(name: "audio_format", value: "pcm_16000"),
                .init(name: "language_code", value: "es"),
                .init(name: "commit_strategy", value: "vad"),
                .init(name: "vad_silence_threshold_secs", value: "0.8"),
            ]
            var request = URLRequest(url: components.url!)
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
            open(request: request, confirmationEvent: "session_started")
        case .deepgram:
            var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
            components.queryItems = [
                .init(name: "model", value: VoiceProviderID.deepgram.defaultModel),
                .init(name: "language", value: "es"),
                .init(name: "encoding", value: "linear16"),
                .init(name: "sample_rate", value: "16000"),
                .init(name: "channels", value: "1"),
                .init(name: "punctuate", value: "true"),
                .init(name: "smart_format", value: "true"),
                .init(name: "interim_results", value: "true"),
            ]
            var request = URLRequest(url: components.url!)
            request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
            open(request: request)
        case .voxtralCloud:
            var components = URLComponents(string: "wss://api.mistral.ai/v1/audio/transcriptions/realtime")!
            components.queryItems = [.init(name: "model", value: VoiceProviderID.voxtralCloud.defaultModel)]
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            open(request: request, confirmationEvent: "session.created")
        case .soniox:
            let request = URLRequest(url: URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!)
            open(request: request, initialJSON: [
                "api_key": key,
                "model": VoiceProviderID.soniox.defaultModel,
                "audio_format": "pcm_s16le",
                "sample_rate": 16000,
                "num_channels": 1,
                "language_hints": ["es", "en"],
                "enable_language_identification": true,
            ])
        case .assemblyAI:
            var components = URLComponents(string: "wss://streaming.assemblyai.com/v3/ws")!
            components.queryItems = [
                .init(name: "speech_model", value: VoiceProviderID.assemblyAI.defaultModel),
                .init(name: "sample_rate", value: "16000"),
                .init(name: "encoding", value: "pcm_s16le"),
                .init(name: "format_turns", value: "true"),
            ]
            var request = URLRequest(url: components.url!)
            request.setValue(key, forHTTPHeaderField: "Authorization")
            open(request: request, confirmationEvent: "Begin")
        case .speechmatics:
            var request = URLRequest(url: URL(string: "wss://global.rt.speechmatics.com/v2/")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            open(request: request, initialJSON: [
                "message": "StartRecognition",
                "audio_format": ["type": "raw", "encoding": "pcm_s16le", "sample_rate": 16000],
                "transcription_config": [
                    "language": "es", "operating_point": "enhanced",
                    "enable_partials": true, "max_delay": 2.0,
                ],
            ], confirmationEvent: "RecognitionStarted", timeout: 7)
        case .appleLocal, .appleCloud:
            completion(.failure(VoiceProviderError.unavailable("Proveedor incorrecto")))
        }
    }

    func accept(buffer: AVAudioPCMBuffer, pcm16: Data) {
        // accept() corre en el hilo de audio en tiempo real y stop() en el
        // principal: el estado compartido va bajo candado.
        lock.lock()
        let alive = !stopped
        if alive { sequence += 1 }
        lock.unlock()
        guard alive, !pcm16.isEmpty else { return }
        switch id {
        case .elevenLabs:
            sendJSON(["message_type": "input_audio_chunk", "audio_base_64": pcm16.base64EncodedString()])
        case .voxtralCloud:
            sendJSON(["type": "input_audio.append", "audio": pcm16.base64EncodedString()])
        default:
            task?.send(.data(pcm16)) { [weak self] error in
                if let error { self?.fail(error) }
            }
        }
    }

    func stop() {
        lock.lock()
        let already = stopped
        stopped = true
        lock.unlock()
        guard !already else { return }
        timeoutWork?.cancel()
        timeoutWork = nil
        switch id {
        case .elevenLabs:
            sendJSON(["message_type": "input_audio_chunk", "audio_base_64": "", "commit": true])
        case .deepgram:
            sendJSON(["type": "CloseStream"])
        case .voxtralCloud:
            sendJSON(["type": "input_audio.end"])
        case .soniox:
            task?.send(.string("")) { _ in }
        case .assemblyAI:
            sendJSON(["type": "Terminate"])
        case .speechmatics:
            sendJSON(["message": "EndOfStream", "last_seq_no": sequence])
        case .gladia:
            sendJSON(["type": "stop_recording"])
        case .appleLocal, .appleCloud:
            break
        }
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        completion = nil
    }

    private func initializeGladia(key: String) {
        var request = URLRequest(url: URL(string: "https://api.gladia.io/v2/live")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-gladia-key")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "encoding": "wav/pcm", "sample_rate": 16000, "bit_depth": 16, "channels": 1,
            "model": VoiceProviderID.gladia.defaultModel,
            "language_config": ["languages": ["es"]],
            "messages_config": [
                "receive_partial_transcripts": true,
                "receive_final_transcripts": true,
                "receive_errors": true,
                "receive_lifecycle_events": true,
            ],
        ])
        URLSession(configuration: .ephemeral).dataTask(with: request) { [weak self] data, response, error in
            guard let self, !self.stopped else { return }
            if let error { self.complete(.failure(error)); return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = json["url"] as? String,
                  let url = URL(string: value) else {
                self.complete(.failure(VoiceProviderError.connection("Gladia no devolvió una sesión válida.")))
                return
            }
            self.open(request: URLRequest(url: url))
        }.resume()
    }

    private func open(request: URLRequest, initialJSON: [String: Any]? = nil,
                      confirmationEvent: String? = nil, timeout: Double = 6) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        task.resume()
        receiveLoop(confirmationEvent: confirmationEvent)
        if let initialJSON { sendJSON(initialJSON) }
        if confirmationEvent == nil { complete(.success(())) }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.completion != nil else { return }
            self.complete(.failure(VoiceProviderError.connection("\(self.id.name) no confirmó conexión en \(Int(timeout)) s.")))
            self.stop()
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    private func receiveLoop(confirmationEvent: String?) {
        task?.receive { [weak self] result in
            guard let self, !self.stopped else { return }
            switch result {
            case .failure(let error):
                self.fail(error)
            case .success(let message):
                let text: String?
                switch message {
                case .string(let value): text = value
                case .data(let data): text = String(data: data, encoding: .utf8)
                @unknown default: text = nil
                }
                if let text {
                    if let confirmationEvent, self.messageType(text) == confirmationEvent {
                        if self.id == .voxtralCloud {
                            self.sendJSON([
                                "type": "session.update",
                                "session": [
                                    "audio_format": ["encoding": "pcm_s16le", "sample_rate": 16000],
                                    "target_streaming_delay_ms": 480,
                                ],
                            ])
                        }
                        self.complete(.success(()))
                    }
                    self.handle(text)
                }
                self.receiveLoop(confirmationEvent: confirmationEvent)
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = (json["type"] as? String) ?? (json["message"] as? String)

        if type == "Error" || type == "error" || type?.contains("error") == true || type?.contains("_error") == true {
            let reason = (json["error"] as? String) ?? (json["reason"] as? String) ?? "Error de \(id.name)"
            fail(VoiceProviderError.connection(reason))
            return
        }

        switch id {
        case .elevenLabs:
            guard let type = json["message_type"] as? String else { return }
            if ["partial_transcript", "final_transcript", "committed_transcript",
                "committed_transcript_with_timestamps"].contains(type),
               let value = json["text"] as? String {
                let final = type != "partial_transcript"
                update(value, final: final, appendFinal: final)
            } else if type.contains("error") || type.contains("exceeded") || type.contains("limited") {
                fail(VoiceProviderError.connection((json["error"] as? String) ?? type))
            }
        case .deepgram:
            guard type == "Results",
                  let channel = json["channel"] as? [String: Any],
                  let alternatives = channel["alternatives"] as? [[String: Any]],
                  let value = alternatives.first?["transcript"] as? String else { return }
            let final = (json["is_final"] as? Bool) ?? false
            update(value, final: final, appendFinal: final)
        case .voxtralCloud:
            if type == "transcription.text.delta" {
                let delta = (json["text"] as? String) ?? (json["delta"] as? String) ?? ""
                partial += delta
                emit(combinedText(), final: false)
            } else if type == "transcription.done" {
                if !partial.isEmpty { finals.append(partial); partial = "" }
                emit(combinedText(), final: true)
            }
        case .soniox:
            guard let tokens = json["tokens"] as? [[String: Any]] else { return }
            var finalText = "", interim = ""
            for token in tokens {
                let value = (token["text"] as? String) ?? ""
                if (token["is_final"] as? Bool) ?? false { finalText += value }
                else { interim += value }
            }
            if !finalText.isEmpty {
                let existing = finals.popLast() ?? ""
                finals.append(existing + finalText)
            }
            partial = interim
            emit(combinedText(), final: interim.isEmpty && !finalText.isEmpty)
        case .assemblyAI:
            guard type == "Turn", let value = json["transcript"] as? String else { return }
            let end = (json["end_of_turn"] as? Bool) ?? false
            let formatted = (json["turn_is_formatted"] as? Bool) ?? false
            if end && formatted { update(value, final: true, appendFinal: true) }
            else { update(value, final: false, appendFinal: false) }
        case .speechmatics:
            guard let metadata = json["metadata"] as? [String: Any],
                  let value = metadata["transcript"] as? String else { return }
            if type == "AddTranscript" { update(value, final: true, appendFinal: true) }
            else if type == "AddPartialTranscript" { update(value, final: false, appendFinal: false) }
        case .gladia:
            guard type == "transcript", let payload = json["data"] as? [String: Any] else { return }
            let utterance = payload["utterance"] as? [String: Any]
            guard let value = (utterance?["text"] as? String) ?? (payload["text"] as? String) else { return }
            let final = (payload["is_final"] as? Bool) ?? false
            update(value, final: final, appendFinal: final)
        case .appleLocal, .appleCloud:
            break
        }
    }

    private func update(_ value: String, final: Bool, appendFinal: Bool) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if appendFinal {
            if !trimmed.isEmpty, finals.last != trimmed { finals.append(trimmed) }
            partial = ""
        } else {
            partial = trimmed
        }
        emit(combinedText(), final: final)
    }

    private func combinedText() -> String {
        (finals + (partial.isEmpty ? [] : [partial]))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func emit(_ text: String, final: Bool) {
        guard !text.isEmpty else { return }
        DispatchQueue.main.async {
            self.onTranscript?(VoiceTranscriptEvent(text: text, isFinal: final,
                                                    provider: self.id, receivedAt: Date()))
        }
    }

    private func messageType(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["type"] as? String) ?? (json["message_type"] as? String) ?? (json["message"] as? String)
    }

    private func sendJSON(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { [weak self] error in
            if let error, self?.stopped == false { self?.fail(error) }
        }
    }

    private func complete(_ result: Result<Void, Error>) {
        let finish = {
            guard let completion = self.completion else { return }
            self.completion = nil
            self.timeoutWork?.cancel()
            self.timeoutWork = nil
            completion(result)
        }
        if Thread.isMainThread { finish() }
        else { DispatchQueue.main.async(execute: finish) }
    }

    private func fail(_ error: Error) {
        let report = {
            guard !self.stopped else { return }
            if self.completion != nil { self.complete(.failure(error)) }
            else { self.onError?(error) }
        }
        if Thread.isMainThread { report() }
        else { DispatchQueue.main.async(execute: report) }
    }
}
