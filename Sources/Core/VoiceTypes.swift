import AVFoundation
import Foundation

// Contrato común de todos los motores de reconocimiento en vivo. El capturador
// de micrófono existe una sola vez; cada proveedor recibe el mismo audio y
// devuelve eventos homogéneos para el seguidor del guion.

enum VoiceProviderID: String, CaseIterable, Codable, Identifiable {
    case appleLocal = "apple_local"
    case appleCloud = "apple_cloud"
    case elevenLabs = "elevenlabs"
    case deepgram
    case voxtralCloud = "voxtral_cloud"
    case soniox
    case assemblyAI = "assemblyai"
    case speechmatics
    case gladia

    var id: String { rawValue }

    var name: String {
        switch self {
        case .appleLocal: return "Apple local"
        case .appleCloud: return "Apple nube"
        case .elevenLabs: return "ElevenLabs Scribe"
        case .deepgram: return "Deepgram Nova"
        case .voxtralCloud: return "Mistral Voxtral"
        case .soniox: return "Soniox"
        case .assemblyAI: return "AssemblyAI"
        case .speechmatics: return "Speechmatics"
        case .gladia: return "Gladia"
        }
    }

    var isLocal: Bool { self == .appleLocal }
    var needsSpeechPermission: Bool { self == .appleLocal || self == .appleCloud }
    var secretName: String? {
        switch self {
        case .appleLocal, .appleCloud: return nil
        case .elevenLabs: return "sttKey_elevenlabs"
        case .deepgram: return "sttKey_deepgram"
        case .voxtralCloud: return "sttKey_mistral"
        case .soniox: return "sttKey_soniox"
        case .assemblyAI: return "sttKey_assemblyai"
        case .speechmatics: return "sttKey_speechmatics"
        case .gladia: return "sttKey_gladia"
        }
    }

    var defaultModel: String {
        switch self {
        case .appleLocal, .appleCloud: return "es-ES"
        case .elevenLabs: return "scribe_v2_realtime"
        case .deepgram: return "nova-3"
        case .voxtralCloud: return "voxtral-mini-transcribe-realtime-2602"
        case .soniox: return "stt-rt-v5"
        case .assemblyAI: return "universal-3-5-pro"
        case .speechmatics: return "enhanced"
        case .gladia: return "solaria-1"
        }
    }

    var privacyNote: String {
        isLocal ? "El audio no sale del Mac." : "El audio se envía en vivo al proveedor elegido."
    }

    static let recommendedOrder: [VoiceProviderID] = [
        .appleLocal, .elevenLabs, .deepgram, .voxtralCloud,
        .soniox, .assemblyAI, .speechmatics, .gladia, .appleCloud,
    ]
}

struct VoiceTranscriptEvent {
    let text: String
    let isFinal: Bool
    let provider: VoiceProviderID
    let receivedAt: Date
}

enum VoiceProviderState: Equatable {
    case idle
    case connecting(VoiceProviderID)
    case listening(VoiceProviderID)
    case failingOver(from: VoiceProviderID, message: String)
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Seguimiento en espera"
        case .connecting(let p): return "Conectando con \(p.name)…"
        case .listening(let p): return "Escuchando con \(p.name)"
        case .failingOver(let p, _): return "\(p.name) falló; probando respaldo…"
        case .failed(let message): return message
        }
    }

    var isFailure: Bool {
        switch self {
        case .failingOver, .failed: return true
        case .idle, .connecting, .listening: return false
        }
    }
}

enum VoiceProviderError: LocalizedError {
    case missingKey(VoiceProviderID)
    case cloudConsentRequired
    case unavailable(String)
    case connection(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let p): return "Falta la API key de \(p.name)."
        case .cloudConsentRequired: return "Debes autorizar el envío de audio a proveedores externos."
        case .unavailable(let message), .connection(let message): return message
        }
    }
}

protocol LiveSpeechProvider: AnyObject {
    var id: VoiceProviderID { get }
    var onTranscript: ((VoiceTranscriptEvent) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    func start(inputFormat: AVAudioFormat, completion: @escaping (Result<Void, Error>) -> Void)
    func accept(buffer: AVAudioPCMBuffer, pcm16: Data)
    func stop()
}

enum VoiceProviderCatalog {
    static func configuredOrder(primary: VoiceProviderID,
                                rawFallbacks: String,
                                failover: Bool) -> [VoiceProviderID] {
        guard failover else { return [primary] }
        let saved = rawFallbacks.split(separator: ",")
            .compactMap { VoiceProviderID(rawValue: String($0)) }
        let candidates = [primary] + saved + VoiceProviderID.recommendedOrder
        var seen = Set<VoiceProviderID>()
        return candidates.filter { seen.insert($0).inserted }
    }
}
