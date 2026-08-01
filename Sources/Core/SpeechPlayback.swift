import AVFoundation
import Combine
import Foundation

// Lectura TTS local del discurso con las voces instaladas en macOS. Es un
// módulo independiente del seguimiento STT y no usa red ni API keys.

final class SpeechPlayback: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechPlayback()

    @Published private(set) var speaking = false
    @Published private(set) var status: String?

    private let synthesizer = AVSpeechSynthesizer()

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    static var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("es") || $0.language.hasPrefix("en") }
            .sorted {
                if $0.language != $1.language { return $0.language < $1.language }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    private var player: AVAudioPlayer?

    var currentProvider: TTSProviderID {
        TTSProviderID(rawValue: Settings.string(.ttsProvider,
                                                default: TTSProviderID.appleSystem.rawValue))
            ?? .appleSystem
    }

    // Enrutado por proveedor: el sistema usa AVSpeechSynthesizer; el resto
    // genera audio (local con Piper o de nube) y se reproduce aquí.
    func speak(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        stop()
        let provider = currentProvider
        guard provider == .appleSystem else {
            speaking = true
            status = "Generando voz con \(provider.name)…"
            TTSEngines.synthesize(text: clean, provider: provider) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(let data):
                        do {
                            let p = try AVAudioPlayer(data: data)
                            p.delegate = self
                            self.player = p
                            self.status = nil
                            p.play()
                        } catch {
                            self.speaking = false
                            self.status = "No se pudo reproducir el audio: \(error.localizedDescription)"
                        }
                    case .failure(let error):
                        self.speaking = false
                        self.status = error.localizedDescription
                    }
                }
            }
            return
        }
        speakWithSystemVoice(clean)
    }

    private func speakWithSystemVoice(_ clean: String) {
        let utterance = AVSpeechUtterance(string: clean)
        let selected = Settings.string(.ttsVoiceIdentifier, default: "")
        if !selected.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: selected) {
            utterance.voice = voice
        } else {
            let locale = Settings.string(.voiceLanguage, default: "es-EC")
            utterance.voice = AVSpeechSynthesisVoice(language: locale)
                ?? AVSpeechSynthesisVoice(language: "es-ES")
        }
        utterance.rate = Float(min(0.68, max(0.30,
            Settings.double(.ttsRate, default: Double(AVSpeechUtteranceDefaultSpeechRate)))))
        status = nil
        speaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        player?.stop()
        player = nil
        speaking = false
        status = nil
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.speaking = false }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.speaking = false }
    }
}

extension SpeechPlayback: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.speaking = false
            self.player = nil
        }
    }
}
