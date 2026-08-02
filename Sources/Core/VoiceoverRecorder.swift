import AVFoundation
import Foundation

// Grabador de VOZ EN OFF del editor: narra sobre el vídeo ya grabado, las
// veces que quieras. Cada toma queda como voz-off-<n>.m4a en la carpeta del
// proyecto y entra al montaje como una capa de audio más, posicionada donde
// estaba el cursor al empezar a grabar. ADICIONAL al micrófono original de la
// grabación, nunca su reemplazo.
//
// Usa el permiso de micrófono que la app ya tiene; la acción es explícita
// (botón de grabar) así que no necesita interruptor propio.

@MainActor
final class VoiceoverRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var elapsed: Double = 0
    @Published var status: String? = nil

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?
    private(set) var currentURL: URL?

    // Empieza una toma en la carpeta dada. Devuelve false si no se pudo.
    func start(inFolder folder: URL) -> Bool {
        guard !isRecording else { return false }
        status = nil
        // Nombre libre: voz-off-1.m4a, voz-off-2.m4a…
        var n = 1
        var url = folder.appendingPathComponent("voz-off-\(n).m4a")
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = folder.appendingPathComponent("voz-off-\(n).m4a")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            guard r.record() else {
                status = "El micrófono no arrancó (¿permiso denegado?)"
                return false
            }
            recorder = r
            currentURL = url
            startedAt = Date()
            elapsed = 0
            isRecording = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let s = self.startedAt else { return }
                    self.elapsed = Date().timeIntervalSince(s)
                }
            }
            return true
        } catch {
            status = "No se pudo grabar: \(error.localizedDescription)"
            return false
        }
    }

    // Para la toma y devuelve el archivo (nil si quedó vacía).
    @discardableResult
    func stop() -> URL? {
        guard isRecording, let r = recorder else { return nil }
        r.stop()
        timer?.invalidate()
        timer = nil
        isRecording = false
        recorder = nil
        let url = currentURL
        currentURL = nil
        // Una toma de menos de medio segundo es un clic accidental.
        if elapsed < 0.5, let url {
            try? FileManager.default.removeItem(at: url)
            status = "Toma demasiado corta, descartada"
            return nil
        }
        return url
    }
}
