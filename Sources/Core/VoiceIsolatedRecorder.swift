import AVFoundation
import Foundation

// Micrófono SIN el eco del sistema: si mientras hablas suena un vídeo en el
// Mac, el micrófono lo capta por los altavoces y acaba duplicado en la
// grabación. Es el problema que Zoom y Teams resuelven con cancelación de eco.
//
// macOS trae esa misma tecnología: el nodo de entrada de AVAudioEngine con
// «voice processing» activado sabe qué está reproduciendo el Mac y lo RESTA
// de lo que entra por el micrófono, además de reducir ruido de fondo.
//
// Se usa en lugar del micrófono de la sesión de cámara: el archivo de cámara
// queda mudo y la voz limpia vive en microfono-<sello>.m4a, que el editor
// prefiere automáticamente.

final class VoiceIsolatedRecorder {

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var pendingURL: URL?
    private(set) var outputURL: URL?
    private(set) var isRunning = false
    private(set) var lastError: String?

    // Arranca la captura limpia hacia el archivo dado. Devuelve false si el
    // sistema no puede activar la cancelación de eco (entonces el llamador
    // se queda con el micrófono normal, sin sorpresas).
    @discardableResult
    func start(to url: URL, cancelEcho: Bool = true) -> Bool {
        guard !isRunning else { return false }
        lastError = nil
        let input = engine.inputNode
        do {
            // Aquí está la magia: cancelación de eco + reducción de ruido.
            try input.setVoiceProcessingEnabled(cancelEcho)
        } catch {
            lastError = "El sistema no pudo activar la cancelación de eco: "
                + error.localizedDescription
            return false
        }

        // El archivo se crea con el PRIMER búfer, usando su formato real: el
        // que anuncia el nodo antes de arrancar no siempre coincide con el
        // que acaba entregando cuando la cancelación de eco está activa, y
        // esa diferencia dejaba el archivo con cero muestras.
        pendingURL = url
        file = nil

        // Tap con formato nil: se usa el del nodo, sea cual sea.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            if self.file == nil {
                guard let target = self.pendingURL else { return }
                // Se escribe en el formato NATIVO del micrófono (CAF/PCM).
                // Comprimir a AAC en vivo desde float sin entrelazar falla
                // (error −50) y dejaba el archivo mudo; AVFoundation lee CAF
                // igual de bien para componer y para transcribir.
                let bufferFormat = buffer.format
                do {
                    self.file = try AVAudioFile(
                        forWriting: target, settings: bufferFormat.settings,
                        commonFormat: bufferFormat.commonFormat,
                        interleaved: bufferFormat.isInterleaved)
                } catch {
                    self.lastError = "No se pudo crear el archivo de voz: "
                        + error.localizedDescription
                    return
                }
            }
            do {
                try self.file?.write(from: buffer)
            } catch {
                // Un fallo aquí deja el archivo mudo: hay que enterarse.
                self.lastError = "Error escribiendo la voz: \(error.localizedDescription)"
            }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            lastError = "No se pudo arrancar el micrófono: \(error.localizedDescription)"
            input.removeTap(onBus: 0)
            try? input.setVoiceProcessingEnabled(false)
            file = nil
            return false
        }
        outputURL = url
        isRunning = true
        return true
    }

    @discardableResult
    func stop() -> URL? {
        guard isRunning else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        file = nil
        isRunning = false
        let url = outputURL
        outputURL = nil
        return url
    }
}
