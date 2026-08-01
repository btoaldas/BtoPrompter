import AVFoundation
import Foundation
import Speech

final class AppleLegacySpeechProvider: LiveSpeechProvider {
    let id: VoiceProviderID
    var onTranscript: ((VoiceTranscriptEvent) -> Void)?
    var onError: ((Error) -> Void)?

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    // El tap de audio llama a accept() en su propio hilo mientras stop() corre
    // en el principal: sin candado es una carrera de datos que puede caer.
    private let lock = NSLock()
    private var inputFormat: AVAudioFormat?
    private var renewWork: DispatchWorkItem?
    private var stopped = false

    init(id: VoiceProviderID) {
        precondition(id == .appleCloud)
        self.id = id
    }

    func start(inputFormat: AVAudioFormat, completion: @escaping (Result<Void, Error>) -> Void) {
        let locale = Locale(identifier: Settings.string(.voiceLanguage, default: "es-ES"))
        let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            completion(.failure(VoiceProviderError.unavailable("Apple Speech no está disponible ahora.")))
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        self.recognizer = recognizer
        self.inputFormat = inputFormat
        lock.lock()
        stopped = false
        self.request = request
        lock.unlock()
        let newTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.onTranscript?(VoiceTranscriptEvent(
                    text: result.bestTranscription.formattedString,
                    isFinal: result.isFinal,
                    provider: self.id,
                    receivedAt: Date()
                ))
            }
            if error != nil {
                // Sesión cortada por el sistema: renovar en vez de morir.
                DispatchQueue.main.async { self.renew() }
            }
        }
        lock.lock()
        task = newTask
        lock.unlock()
        scheduleRenewal()
        completion(.success(()))
    }

    func accept(buffer: AVAudioPCMBuffer, pcm16: Data) {
        lock.lock()
        let current = stopped ? nil : request
        lock.unlock()
        current?.append(buffer)
    }

    func stop() {
        lock.lock()
        stopped = true
        let r = request
        let t = task
        request = nil
        task = nil
        lock.unlock()
        renewWork?.cancel()
        renewWork = nil
        r?.endAudio()
        t?.cancel()
        recognizer = nil
    }

    // SFSpeechRecognizer corta la sesión al cabo de ~1 minuto, a veces sin
    // error: sin renovación el proveedor quedaba mudo para siempre.
    private func scheduleRenewal() {
        renewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.renew() }
        renewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: work)
    }

    private func renew() {
        lock.lock()
        let alive = !stopped
        let previous = request
        let previousTask = task
        lock.unlock()
        guard alive, let format = inputFormat else { return }
        previous?.endAudio()
        previousTask?.cancel()
        start(inputFormat: format) { _ in }
    }
}

// MARK: - Apple SpeechAnalyzer local (macOS 26+)

final class AppleLocalSpeechProvider: LiveSpeechProvider {
    let id: VoiceProviderID = .appleLocal
    var onTranscript: ((VoiceTranscriptEvent) -> Void)?
    var onError: ((Error) -> Void)?

    private var implementation: AnyObject?

    func start(inputFormat: AVAudioFormat, completion: @escaping (Result<Void, Error>) -> Void) {
        guard #available(macOS 26, *) else {
            completion(.failure(VoiceProviderError.unavailable("Apple local requiere macOS 26 o superior.")))
            return
        }
        Task { @MainActor in
            do {
                let live = try await AppleAnalyzerLive(inputFormat: inputFormat)
                live.onTranscript = { [weak self] text, final in
                    guard let self else { return }
                    self.onTranscript?(VoiceTranscriptEvent(text: text, isFinal: final,
                                                            provider: .appleLocal,
                                                            receivedAt: Date()))
                }
                live.onError = { [weak self] error in self?.onError?(error) }
                live.start()
                self.implementation = live
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func accept(buffer: AVAudioPCMBuffer, pcm16: Data) {
        guard #available(macOS 26, *), let live = implementation as? AppleAnalyzerLive else { return }
        live.accept(buffer)
    }

    func stop() {
        guard #available(macOS 26, *), let live = implementation as? AppleAnalyzerLive else {
            implementation = nil
            return
        }
        live.stop()
        implementation = nil
    }
}

@available(macOS 26, *)
private final class AppleAnalyzerLive: NSObject {
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?

    private let transcriber: DictationTranscriber
    private let analyzer: SpeechAnalyzer
    private let analyzerFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let inputStream: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var resultTask: Task<Void, Never>?
    private var analyzerTask: Task<Void, Never>?
    private var running = false

    init(inputFormat: AVAudioFormat) async throws {
        let requested = Locale(identifier: Settings.string(.voiceLanguage, default: "es-ES"))
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw VoiceProviderError.unavailable("Apple local no soporta el idioma \(requested.identifier).")
        }
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        let status = await AssetInventory.status(forModules: [transcriber])
        if status != .installed {
            guard Settings.bool(.voiceAutoDownloadAppleModel, default: true) else {
                throw VoiceProviderError.unavailable("Falta el modelo local de Apple. Descárgalo en Configuración → Voz.")
            }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
                throw VoiceProviderError.unavailable("El modelo local de Apple todavía no está instalado.")
            }
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) ?? inputFormat
        let pair = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.analyzerFormat = format
        self.converter = format == inputFormat ? nil : AVAudioConverter(from: inputFormat, to: format)
        self.inputStream = pair.stream
        self.continuation = pair.continuation
        super.init()
    }

    func start() {
        guard !running else { return }
        running = true
        analyzerTask = Task { [weak self] in
            guard let self else { return }
            // DictationTranscriber es sensible al orden: crear el lector y
            // llamar a analyzer.start sin ningún await intermedio.
            let reader = Task { [weak self] in
                guard let self else { return }
                var fixed = ""
                do {
                    for try await result in self.transcriber.results {
                        let segment = String(result.text.characters)
                        var visible = fixed
                        if result.isFinal {
                            fixed += segment
                            visible = fixed
                        } else {
                            visible = fixed + segment
                        }
                        let text = visible.replacingOccurrences(of: "\n", with: " ")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty, !Task.isCancelled {
                            await MainActor.run { self.onTranscript?(text, result.isFinal) }
                        }
                    }
                } catch {
                    if !Task.isCancelled { await MainActor.run { self.onError?(error) } }
                }
            }
            self.resultTask = reader
            do {
                try await self.analyzer.start(inputSequence: self.inputStream)
            } catch {
                if !Task.isCancelled { await MainActor.run { self.onError?(error) } }
            }
        }
    }

    func accept(_ buffer: AVAudioPCMBuffer) {
        guard running else { return }
        if let converter {
            let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat,
                                                frameCapacity: capacity) else { return }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, conversionError == nil, output.frameLength > 0 else {
                if let conversionError { onError?(conversionError) }
                return
            }
            continuation.yield(AnalyzerInput(buffer: output))
        } else {
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
    }

    func stop() {
        guard running else { return }
        running = false
        continuation.finish()
        resultTask?.cancel()
        resultTask = nil
        analyzerTask?.cancel()
        analyzerTask = nil
        Task { await analyzer.cancelAndFinishNow() }
    }
}

// Estado y descarga controlada del modelo local de Apple. El sistema conserva
// la descarga y la reanuda en intentos posteriores; cancelar detiene la petición
// visible sin borrar un modelo ya instalado.
@MainActor
final class AppleSpeechModelManager: ObservableObject {
    static let shared = AppleSpeechModelManager()
    @Published var status = "Comprobando…"
    @Published var progress: Double = 0
    @Published var busy = false
    // Tipo borrado a propósito: las propiedades almacenadas no admiten
    // @available, y con el tipo concreto la app no compilaría para macOS < 26.
    private var request: AnyObject?
    private var observer: NSKeyValueObservation?

    func refresh() {
        guard #available(macOS 26, *) else { status = "Requiere macOS 26"; return }
        Task { await refreshModern() }
    }

    @available(macOS 26, *)
    private func refreshModern() async {
        let requested = Locale(identifier: Settings.string(.voiceLanguage, default: "es-ES"))
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            status = "Idioma no compatible"
            return
        }
        let module = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        switch await AssetInventory.status(forModules: [module]) {
        case .installed: status = "Instalado ✓"; progress = 1
        case .downloading: status = "Descargando…"
        case .supported: status = "Disponible para descargar"; progress = 0
        case .unsupported: status = "No compatible"
        @unknown default: status = "Estado desconocido"
        }
    }

    func download() {
        guard #available(macOS 26, *) else { status = "Requiere macOS 26"; return }
        busy = true
        status = "Preparando descarga…"
        Task { await downloadModern() }
    }

    @available(macOS 26, *)
    private func downloadModern() async {
        do {
            let requested = Locale(identifier: Settings.string(.voiceLanguage, default: "es-ES"))
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
                throw VoiceProviderError.unavailable("Idioma no compatible")
            }
            let module = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
                status = "Instalado ✓"; progress = 1; busy = false; return
            }
            self.request = request
            observer = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { _, change in
                Task { @MainActor in self.progress = change.newValue ?? 0 }
            }
            try await request.downloadAndInstall()
            self.request = nil
            observer = nil
            busy = false
            await refreshModern()
        } catch {
            request = nil
            observer = nil
            busy = false
            status = "Error: \(error.localizedDescription)"
        }
    }

    func cancel() {
        request?.progress.cancel()
        request = nil
        observer = nil
        busy = false
        status = "Pausada; puedes continuar después"
    }
}
