import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

// Escritor de pantalla a prueba de muertes. SCRecordingOutput escribe un .mov
// sin fragmentar: si el proceso escritor muere de golpe (crash de replayd,
// kill, corte de luz), el archivo entero queda sin moov y es ILEGIBLE —
// probado matando replayd a mitad de toma. Aquí la pantalla se escribe a
// mano con AVAssetWriter y fragmentos de película cada 5 segundos: pase lo
// que pase, lo grabado hasta el último fragmento siempre se puede abrir.
// Se pierden segundos, no horas.
//
// Detalle nada obvio: ScreenCaptureKit solo entrega fotogramas cuando la
// pantalla CAMBIA. Con la pantalla quieta no llega nada, la duración escrita
// se congela y el vigilante creería que la captura murió. El latido repite
// el último fotograma una vez por segundo cuando no fluye nada: la duración
// avanza, los fragmentos se cierran y el vigilante no da falsas alarmas.
@available(macOS 15.0, *)
final class ScreenSegmentWriter: NSObject, SCStreamOutput {
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let videoAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private var audio: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "recording.screen.writer")

    private var sessionStarted = false
    private var sessionStartSeconds = 0.0
    private var finished = false
    private var errorSent = false
    private var lastPTS = CMTime.invalid
    private var lastAppendHost = 0.0
    private var lastPixelBuffer: CVPixelBuffer?
    private var heartbeat: DispatchSourceTimer?
    private var writtenValue = 0.0

    // Ambos se disparan UNA vez, en el hilo principal.
    var onStart: (() -> Void)?
    var onError: ((Error) -> Void)?

    // Segundos de vídeo ya entregados al escritor; lo mira el vigilante.
    var writtenSeconds: Double { queue.sync { writtenValue } }

    init(outputURL: URL, width: Int, height: Int, withAudio: Bool) throws {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
        // H.264 no pasa de 4096 px de ancho: las pantallas 5K/6K van en HEVC.
        let codec: AVVideoCodecType =
            (width > 4096 || height > 2304) ? .hevc : .h264
        // ~0,05 bits por píxel a 30 fps: de sobra para contenido de pantalla
        // (un 4K queda en ~12 Mb/s) sin inflar una toma de horas.
        let bitrate = min(40_000_000, max(6_000_000, Int(Double(width * height) * 30 * 0.05)))
        let settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60,
            ],
        ]
        video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = true
        videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(video) else {
            throw NSError(domain: "BtoPrompter", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "no se pudo preparar el escritor de vídeo"])
        }
        writer.add(video)
        if withAudio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            a.expectsMediaDataInRealTime = true
            if writer.canAdd(a) {
                writer.add(a)
                audio = a
            }
        }
        super.init()
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "BtoPrompter", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "el escritor de pantalla no arrancó"])
        }
    }

    // La captura ya corre: engancharse a ella empieza a recibir fotogramas.
    func attach(to stream: SCStream) throws {
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if audio != nil {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
    }

    // MARK: - SCStreamOutput (llega en `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard !finished, sb.isValid else { return }
        switch type {
        case .screen:
            // Solo fotogramas completos: los avisos de «sin cambios» o
            // «pantalla en blanco» no traen imagen que escribir.
            guard let atts = CMSampleBufferGetSampleAttachmentsArray(
                        sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = atts.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete,
                  let px = CMSampleBufferGetImageBuffer(sb) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            startSessionIfNeeded(at: pts)
            appendVideo(px, at: pts)
        case .audio:
            // El audio no puede adelantarse a la sesión: se descarta hasta
            // que el primer fotograma fija el instante cero.
            guard sessionStarted, let a = audio, a.isReadyForMoreMediaData else { return }
            a.append(sb)
        default:
            break
        }
        checkWriterFailure()
    }

    // MARK: - Escritura

    private func startSessionIfNeeded(at pts: CMTime) {
        guard !sessionStarted else { return }
        writer.startSession(atSourceTime: pts)
        sessionStartSeconds = pts.seconds
        sessionStarted = true
        startHeartbeat()
        if let cb = onStart {
            onStart = nil
            DispatchQueue.main.async(execute: cb)
        }
    }

    private func appendVideo(_ px: CVPixelBuffer, at pts: CMTime) {
        // Antes atascarse que bloquear: si el codificador va lleno, este
        // fotograma se pierde y el siguiente entra.
        guard video.isReadyForMoreMediaData else { return }
        guard lastPTS == .invalid || pts > lastPTS else { return }
        guard videoAdaptor.append(px, withPresentationTime: pts) else { return }
        lastPTS = pts
        lastPixelBuffer = px
        lastAppendHost = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        writtenValue = pts.seconds - sessionStartSeconds
    }

    private func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.heartbeatTick() }
        t.resume()
        heartbeat = t
    }

    private func heartbeatTick() {
        guard !finished, sessionStarted, let px = lastPixelBuffer else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        guard now.seconds - lastAppendHost > 1.2 else { return }
        appendVideo(px, at: now)
        checkWriterFailure()
    }

    private func checkWriterFailure() {
        guard !errorSent, writer.status == .failed else { return }
        errorSent = true
        finished = true
        heartbeat?.cancel()
        heartbeat = nil
        let err = writer.error ?? NSError(domain: "BtoPrompter", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "el escritor de pantalla falló"])
        if let cb = onError {
            onError = nil
            DispatchQueue.main.async { cb(err) }
        }
    }

    // MARK: - Cierre

    // Cierre limpio; `done` vuelve en el hilo principal. Si nunca llegó un
    // fotograma no hay nada que rematar: se cancela y listo.
    func finish(_ done: @escaping () -> Void) {
        queue.async { [self] in
            heartbeat?.cancel()
            heartbeat = nil
            guard !finished else { DispatchQueue.main.async(execute: done); return }
            finished = true
            guard sessionStarted, writer.status == .writing else {
                writer.cancelWriting()
                DispatchQueue.main.async(execute: done)
                return
            }
            video.markAsFinished()
            audio?.markAsFinished()
            writer.finishWriting { DispatchQueue.main.async(execute: done) }
        }
    }
}
