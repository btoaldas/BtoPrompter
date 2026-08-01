import Foundation

// Catálogo de motores de lectura en voz alta (TTS). Mismo patrón que los
// proveedores de voz: clave por proveedor, modelo elegible y voz elegible.

enum TTSProviderID: String, CaseIterable, Identifiable {
    case appleSystem = "apple_system"
    case piperLocal = "piper_local"
    case elevenLabs = "tts_elevenlabs"
    case openAI = "tts_openai"
    case gemini = "tts_gemini"
    case deepgram = "tts_deepgram"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .appleSystem: return "Voces del sistema (macOS)"
        case .piperLocal: return "Voces locales (Piper)"
        case .elevenLabs: return "ElevenLabs"
        case .openAI: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .deepgram: return "Deepgram Aura"
        }
    }

    var isLocal: Bool { self == .appleSystem || self == .piperLocal }

    var secretName: String? {
        switch self {
        case .appleSystem, .piperLocal: return nil
        case .elevenLabs: return "ttsKey_elevenlabs"
        case .openAI: return "ttsKey_openai"
        case .gemini: return "ttsKey_gemini"
        case .deepgram: return "ttsKey_deepgram"
        }
    }

    var availableModels: [String] {
        switch self {
        case .appleSystem, .piperLocal: return []
        case .elevenLabs: return ["eleven_v3", "eleven_turbo_v2_5", "eleven_multilingual_v2", "eleven_flash_v2_5"]
        case .openAI: return ["gpt-4o-mini-tts", "tts-1-hd", "tts-1"]
        case .gemini: return ["gemini-2.5-flash-preview-tts", "gemini-2.5-pro-preview-tts"]
        case .deepgram: return ["aura-2", "aura"]
        }
    }

    // Voces sugeridas; el usuario puede escribir cualquier otro identificador.
    var suggestedVoices: [(id: String, label: String)] {
        switch self {
        case .appleSystem, .piperLocal: return []
        case .elevenLabs: return []   // se listan desde la API del usuario
        case .openAI: return [
            ("alloy", "Alloy"), ("ash", "Ash"), ("ballad", "Ballad"), ("coral", "Coral"),
            ("echo", "Echo"), ("sage", "Sage"), ("shimmer", "Shimmer"), ("verse", "Verse"),
        ]
        case .gemini: return [
            ("Kore", "Kore"), ("Puck", "Puck"), ("Charon", "Charon"),
            ("Fenrir", "Fenrir"), ("Aoede", "Aoede"), ("Leda", "Leda"),
        ]
        case .deepgram: return [
            ("aura-2-celeste-es", "Celeste (es)"), ("aura-2-nestor-es", "Nestor (es)"),
            ("aura-2-sirio-es", "Sirio (es)"), ("aura-2-carina-es", "Carina (es)"),
            ("aura-2-thalia-en", "Thalia (en)"),
        ]
        }
    }

    var defaultModel: String { availableModels.first ?? "" }
    var defaultVoice: String { suggestedVoices.first?.id ?? "" }

    var modelKey: String { "ttsModel_\(rawValue)" }
    var voiceKey: String { "ttsVoice_\(rawValue)" }

    var configuredModel: String {
        let s = UserDefaults.standard.string(forKey: modelKey) ?? ""
        return s.isEmpty ? defaultModel : s
    }
    var configuredVoice: String {
        let s = UserDefaults.standard.string(forKey: voiceKey) ?? ""
        return s.isEmpty ? defaultVoice : s
    }

    var docsURL: URL? {
        switch self {
        case .elevenLabs: return URL(string: "https://elevenlabs.io/app/settings/api-keys")
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .gemini: return URL(string: "https://aistudio.google.com/app/apikey")
        case .deepgram: return URL(string: "https://console.deepgram.com/")
        case .appleSystem, .piperLocal: return nil
        }
    }

    var privacyNote: String {
        isLocal ? "El texto no sale del Mac."
                : "El texto del discurso se envía al proveedor para generar el audio."
    }
}

// Voz local instalada (modelo Piper .onnx en la carpeta de la app).
struct LocalVoice: Identifiable, Hashable {
    let id: String        // nombre de carpeta
    let name: String
    let modelURL: URL
}

enum TTSError: LocalizedError {
    case missingKey(TTSProviderID)
    case engineMissing(String)
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let p): return "Falta la API key de \(p.name)."
        case .engineMissing(let m): return m
        case .remote(let m): return m
        }
    }
}
