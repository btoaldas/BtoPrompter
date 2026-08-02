import Foundation

// Parámetros globales de la app, centralizados y tipados.
// Una sola fuente de verdad para los nombres de clave: nadie más
// escribe strings de UserDefaults por su cuenta.
enum Settings {
    private static let d = UserDefaults.standard

    enum Key: String {
        case wpm, fontSize, bgOpacity, spyMode, guideTitles, selectedID
        case miniMode, miniFontSize
        case countdownSeconds, autoPlay, keepAwake, accentColorID, voiceFollow
        case voiceProvider, voiceFailoverEnabled, voiceFailoverOrder
        case voiceLanguage, voiceCloudConsent, voiceAutoDownloadAppleModel
        case voiceMatchSensitivity, voiceMaxJump, voiceConfirmLargeJumps
        case diagnosticsEnabled, diagnosticsRecordAudio, diagnosticsRetentionDays
        case diagnosticsMaxMegabytes, diagnosticsIncludeScript
        case speechProfileEnabled, speechProfileMinimumSessions, speechProfileShareWithAI
        case ttsVoiceIdentifier, ttsRate
        case ttsProvider, ttsCloudConsent, ttsLocalVoiceID, ttsPiperPath
        case rehearsalStats, autoInstallUpdates
        case remoteEnabled, remotePort, remoteToken, remoteComputerControl
        case remoteInvertPointer, remoteInvertScroll
        case slideSyncEnabled, slideSyncApp
        case aiEnabled, aiProvider, aiModel, aiBaseURL, aiStyle, aiCustomPrompt
        case recordingEnabled, recordCamera, recordScreen, recordFolder
        case recordCameraDevice, recordCountdown, recordChapters, recordMicInRecording
        case recordSystemAudio, recordAudioCopies, recordAutoPlayPrompter
        case videoEditorEnabled
        // Claves históricas de la v1.0 (migradas a la biblioteca).
        case legacyScript = "script"
        case legacyLastScript = "lastScript"
    }

    // Límites del prompter — un solo lugar para ajustarlos.
    enum Limits {
        static let wpmRange = 60...400
        static let wpmStep = 10
        static let fontRange: ClosedRange<CGFloat> = 20...72
        static let fontStep: CGFloat = 2
        static let miniFontRange: ClosedRange<CGFloat> = 14...32
        static let speedDeltaRange = -60...60
        // Multiplicadores de pausa según la puntuación final de la palabra.
        static let sentencePauseMultiplier = 1.9
        static let commaPauseMultiplier = 1.4
        static let sentenceEnders = ".!?…:"
        static let commaEnders = ",;"
    }

    static func bool(_ key: Key, default def: Bool) -> Bool {
        d.object(forKey: key.rawValue) as? Bool ?? def
    }
    static func int(_ key: Key, default def: Int) -> Int {
        d.object(forKey: key.rawValue) as? Int ?? def
    }
    static func double(_ key: Key, default def: Double) -> Double {
        d.object(forKey: key.rawValue) as? Double ?? def
    }
    static func string(_ key: Key, default def: String) -> String {
        d.string(forKey: key.rawValue) ?? def
    }
    static func set(_ value: Any?, _ key: Key) {
        d.set(value, forKey: key.rawValue)
    }
    static func remove(_ key: Key) {
        d.removeObject(forKey: key.rawValue)
    }
}
