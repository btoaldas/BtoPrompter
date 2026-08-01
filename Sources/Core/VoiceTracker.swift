import AppKit
import AVFoundation
import Foundation
import Speech

// Orquestador del seguimiento por voz. El micrófono se captura una sola vez y
// el audio se entrega al proveedor activo. Si este falla, cambia de proveedor
// sin crear un segundo tap ni permitir que dos motores muevan el guion a la vez.

final class VoiceTracker {
    static let shared = VoiceTracker()

    private let engine = AVAudioEngine()
    private let providerLock = NSLock()
    private var provider: LiveSpeechProvider?
    private var order: [VoiceProviderID] = []
    private var orderIndex = 0
    private var desired = false
    private var startGeneration = 0
    private var inputFormat: AVAudioFormat?
    private var pcmConverter: VoicePCM16Converter?
    private var lastError: String?
    private var conversionErrorReported = false

    private(set) var running = false

    private init() {}

    // Se llama al activar el parámetro, antes de una presentación. Así los
    // diálogos del sistema no aparecen después de pulsar Play.
    func requestPermissions(_ completion: @escaping (Bool) -> Void) {
        requestMicrophone(openSettingsOnDenial: true) { granted in
            guard granted else { completion(false); return }
            let primary = self.configuredPrimary
            guard primary.needsSpeechPermission else {
                PrompterModel.shared.voiceStatus = nil
                completion(true)
                return
            }
            self.requestSpeechPermission(openSettingsOnDenial: true, completion: completion)
        }
    }

    func start() {
        guard !desired else { return }
        desired = true
        startGeneration += 1
        let generation = startGeneration
        let primary = configuredPrimary
        PrompterModel.shared.voiceProviderState = .connecting(primary)
        PrompterModel.shared.voiceStatus = nil

        requestMicrophone(openSettingsOnDenial: false) { [weak self] granted in
            guard let self, self.desired, generation == self.startGeneration else { return }
            guard granted else {
                self.failCompletely("Micrófono denegado. Actívalo en Ajustes del Sistema → Privacidad y seguridad → Micrófono.")
                return
            }
            let input = self.engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                self.failCompletely("El micrófono no entregó un formato de audio válido.")
                return
            }
            self.inputFormat = format
            self.pcmConverter = VoicePCM16Converter(inputFormat: format)
            self.order = VoiceProviderCatalog.configuredOrder(
                primary: primary,
                rawFallbacks: Settings.string(.voiceFailoverOrder, default: ""),
                failover: Settings.bool(.voiceFailoverEnabled, default: true)
            )
            self.orderIndex = 0
            self.lastError = nil
            self.connectNext(generation: generation)
        }
    }

    func stop() {
        desired = false
        startGeneration += 1
        detachProvider()?.stop()
        stopCapture()
        inputFormat = nil
        pcmConverter = nil
        running = false
        PrompterModel.shared.voiceActive = false
        PrompterModel.shared.voiceProviderState = .idle
    }

    func restartIfRunning() {
        guard desired || running else { return }
        stop()
        start()
    }

    // Si el usuario cambia de micrófono en vivo, AVAudioEngine se detiene y el
    // tap deja de entregar audio: reconectar en vez de morir en silencio.
    private var configObserver: NSObjectProtocol?
    private func observeConfigurationChanges() {
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.desired else { return }
            VoiceDiagnostics.shared.operational("INFO", "Cambio de dispositivo de audio: reconectando")
            self.restartIfRunning()
        }
    }

    // Tras una navegación manual (⇧←, saltos, clic, marcadores) la
    // transcripción acumulada del proveedor ya no corresponde a la posición
    // nueva y arrastraría el guion de vuelta. Se reinicia el proveedor para
    // empezar con un buffer limpio, sin tocar la preferencia del usuario.
    private var contextResetWork: DispatchWorkItem?
    func resetTranscriptContext() {
        guard running else { return }
        contextResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running || self.desired else { return }
            VoiceDiagnostics.shared.operational("INFO", "reinicio de contexto tras navegación manual")
            self.stop()
            self.start()
        }
        contextResetWork = work
        // Pequeño retardo: agrupa ráfagas de ⇧← seguidas en un solo reinicio.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    static func openMicrophoneSettings() {
        openPrivacyPane("Privacy_Microphone")
    }

    static func openSpeechSettings() {
        openPrivacyPane("Privacy_SpeechRecognition")
    }

    private var configuredPrimary: VoiceProviderID {
        VoiceProviderID(rawValue: Settings.string(.voiceProvider, default: VoiceProviderID.appleLocal.rawValue))
            ?? .appleLocal
    }

    private func connectNext(generation: Int) {
        guard desired, generation == startGeneration else { return }
        guard orderIndex < order.count else {
            failCompletely(lastError ?? "No hay un proveedor de voz disponible. Revisa Voz en Configuración.")
            return
        }

        let id = order[orderIndex]
        orderIndex += 1

        if !id.hasCloudConsent {
            skip(id, reason: "sin autorización para enviar audio fuera del Mac", generation: generation)
            return
        }
        if let secretName = id.secretName, SecretsStore.get(secretName).isEmpty {
            skip(id, reason: "falta API key", generation: generation)
            return
        }
        guard let format = inputFormat else {
            failCompletely("El micrófono dejó de estar disponible.")
            return
        }

        let continueConnection = { [weak self] (permissionGranted: Bool) in
            guard let self, self.desired, generation == self.startGeneration else { return }
            guard permissionGranted else {
                self.skip(id, reason: "permiso de reconocimiento de voz denegado", generation: generation)
                return
            }

            let next = self.makeProvider(id)
            next.onTranscript = { [weak self, weak next] event in
                guard let self, let next, self.isCurrent(next), self.desired else { return }
                DispatchQueue.main.async {
                    guard self.isCurrent(next), self.desired else { return }
                    VoiceDiagnostics.shared.transcript(event)
                    PrompterModel.shared.voiceHeard(event)
                }
            }
            next.onError = { [weak self, weak next] error in
                guard let self, let next else { return }
                DispatchQueue.main.async {
                    guard self.isCurrent(next) else { return }
                    self.providerFailed(id: id, error: error, generation: generation)
                }
            }
            self.attachProvider(next)
            PrompterModel.shared.voiceProviderState = .connecting(id)
            VoiceDiagnostics.shared.operational("INFO", "Conectando proveedor de voz: \(id.rawValue)")
            next.start(inputFormat: format) { [weak self, weak next] result in
                DispatchQueue.main.async {
                    guard let self, let next, self.desired,
                          generation == self.startGeneration, self.isCurrent(next) else {
                        next?.stop()
                        return
                    }
                    switch result {
                    case .success:
                        do {
                            if !self.running { try self.startCapture(format: format) }
                            // Conexión sana: la escalera de respaldos vuelve al
                            // principio, si no cada corte transitorio consumía un
                            // puesto y el proveedor principal no se reintentaba.
                            self.orderIndex = 0
                            PrompterModel.shared.voiceActive = true
                            PrompterModel.shared.voiceFollowFailed = false
                            PrompterModel.shared.voiceProviderState = .listening(id)
                            PrompterModel.shared.voiceStatus = nil
                            VoiceDiagnostics.shared.operational("INFO", "Seguimiento activo con \(id.rawValue)")
                        } catch {
                            self.providerFailed(id: id, error: error, generation: generation)
                        }
                    case .failure(let error):
                        self.providerFailed(id: id, error: error, generation: generation)
                    }
                }
            }
        }

        if id.needsSpeechPermission {
            requestSpeechPermission(openSettingsOnDenial: false, completion: continueConnection)
        } else {
            continueConnection(true)
        }
    }

    private func skip(_ id: VoiceProviderID, reason: String, generation: Int) {
        lastError = "\(id.name): \(reason)."
        VoiceDiagnostics.shared.operational("WARN", "Proveedor omitido \(id.rawValue): \(reason)")
        guard Settings.bool(.voiceFailoverEnabled, default: true) else {
            failCompletely(lastError ?? "Proveedor no disponible")
            return
        }
        connectNext(generation: generation)
    }

    private func providerFailed(id: VoiceProviderID, error: Error, generation: Int) {
        guard desired, generation == startGeneration else { return }
        let message = error.localizedDescription
        lastError = "\(id.name): \(message)"
        PrompterModel.shared.voiceProviderState = .failingOver(from: id, message: message)
        VoiceDiagnostics.shared.event("provider_failed", fields: [
            "provider": id.rawValue,
            "message": message,
        ])
        VoiceDiagnostics.shared.operational("ERROR", "Proveedor \(id.rawValue) falló: \(message)")
        detachProvider()?.stop()

        guard Settings.bool(.voiceFailoverEnabled, default: true) else {
            failCompletely(lastError ?? "El reconocimiento de voz falló.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.connectNext(generation: generation)
        }
    }

    private func failCompletely(_ message: String) {
        desired = false
        detachProvider()?.stop()
        stopCapture()
        running = false
        let model = PrompterModel.shared
        model.voiceActive = false
        model.voiceProviderState = .failed(message)
        VoiceDiagnostics.shared.operational("ERROR", message)
        // NUNCA dejar el prompter congelado en plena presentación: si ningún
        // proveedor pudo escuchar, se vuelve al avance por tiempo y se avisa.
        model.voiceStatus = message + " — el guion sigue avanzando por tiempo."
        model.resumeTimedAdvanceAfterVoiceFailure()
    }

    private func makeProvider(_ id: VoiceProviderID) -> LiveSpeechProvider {
        switch id {
        case .appleLocal: return AppleLocalSpeechProvider()
        case .appleCloud: return AppleLegacySpeechProvider(id: .appleCloud)
        default: return CloudSpeechProvider(id: id)
        }
    }

    private func startCapture(format: AVAudioFormat) throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        conversionErrorReported = false
        // El formato pudo capturarse segundos antes; si el usuario cambió de
        // micrófono, instalar el tap con el formato viejo lanza una excepción
        // de CoreAudio que tumbaría la app en plena presentación.
        let live = input.outputFormat(forBus: 0)
        let format = (live.channelCount > 0 && live.sampleRate > 0) ? live : format
        if format.sampleRate != inputFormat?.sampleRate || format.channelCount != inputFormat?.channelCount {
            inputFormat = format
            pcmConverter = VoicePCM16Converter(inputFormat: format)
        }
        observeConfigurationChanges()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, self.desired else { return }
            VoiceDiagnostics.shared.appendAudio(buffer)
            guard let active = self.currentProvider() else { return }
            var pcm16 = Data()
            if active.id != .appleLocal && active.id != .appleCloud {
                if let converted = self.pcmConverter?.convert(buffer) {
                    pcm16 = converted
                } else if !self.conversionErrorReported {
                    self.conversionErrorReported = true
                    VoiceDiagnostics.shared.operational("ERROR", "No se pudo convertir el micrófono a PCM16/16 kHz")
                }
            }
            active.accept(buffer: buffer, pcm16: pcm16)
        }
        VoiceDiagnostics.shared.startAudio(format: format)
        engine.prepare()
        try engine.start()
        running = true
    }

    private func stopCapture() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }

    private func attachProvider(_ value: LiveSpeechProvider) {
        providerLock.lock()
        provider = value
        providerLock.unlock()
    }

    private func detachProvider() -> LiveSpeechProvider? {
        providerLock.lock()
        let value = provider
        provider = nil
        providerLock.unlock()
        return value
    }

    private func currentProvider() -> LiveSpeechProvider? {
        providerLock.lock()
        defer { providerLock.unlock() }
        return provider
    }

    private func isCurrent(_ candidate: LiveSpeechProvider) -> Bool {
        providerLock.lock()
        defer { providerLock.unlock() }
        return provider === candidate
    }

    private func requestMicrophone(openSettingsOnDenial: Bool,
                                   completion: @escaping (Bool) -> Void) {
        let finish: (Bool) -> Void = { granted in
            DispatchQueue.main.async {
                if !granted {
                    let message = "Micrófono denegado. Actívalo en Ajustes del Sistema → Privacidad y seguridad → Micrófono."
                    PrompterModel.shared.voiceStatus = message
                    PrompterModel.shared.voiceProviderState = .failed(message)
                    if openSettingsOnDenial { Self.openMicrophoneSettings() }
                }
                completion(granted)
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            finish(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { finish($0) }
        case .denied, .restricted:
            finish(false)
        @unknown default:
            finish(false)
        }
    }

    private func requestSpeechPermission(openSettingsOnDenial: Bool,
                                         completion: @escaping (Bool) -> Void) {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current == .authorized { completion(true); return }
        if current == .denied || current == .restricted {
            let message = "Reconocimiento de voz denegado. Actívalo en Ajustes del Sistema → Privacidad y seguridad → Reconocimiento de voz."
            PrompterModel.shared.voiceStatus = message
            PrompterModel.shared.voiceProviderState = .failed(message)
            if openSettingsOnDenial { Self.openSpeechSettings() }
            completion(false)
            return
        }
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                let granted = status == .authorized
                if !granted {
                    let message = "Reconocimiento de voz denegado. Actívalo en Ajustes del Sistema → Privacidad y seguridad → Reconocimiento de voz."
                    PrompterModel.shared.voiceStatus = message
                    PrompterModel.shared.voiceProviderState = .failed(message)
                    if openSettingsOnDenial { Self.openSpeechSettings() }
                }
                completion(granted)
            }
        }
    }

    private static func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

// Conversión exclusiva del hilo del tap: Float/48 kHz/multicanal → PCM16,
// 16 kHz, mono. Los proveedores Apple reciben además el buffer original.
private final class VoicePCM16Converter {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let frameRatio: Double

    init?(inputFormat: AVAudioFormat) {
        guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: 16_000,
                                         channels: 1,
                                         interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: output) else { return nil }
        self.outputFormat = output
        self.converter = converter
        self.frameRatio = output.sampleRate / inputFormat.sampleRate
    }

    func convert(_ input: AVAudioPCMBuffer) -> Data? {
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * frameRatio)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil, output.frameLength > 0,
              let samples = output.int16ChannelData?[0] else { return nil }
        return Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}
