import AVFoundation
import Accelerate
import Foundation

// Quitar del micrófono el sonido del sistema, DESPUÉS de grabar.
//
// En vivo no se puede: macOS no borra del micrófono lo que otras apps sacan
// por los altavoces (medido). Pero al terminar sí tenemos las dos piezas:
// - la REFERENCIA exacta: el sonido del sistema capturado en digital dentro de
//   pantalla-*.mov, que nunca pasó por el aire;
// - el micrófono, que trae la voz MÁS esa misma referencia, retrasada por el
//   camino altavoz → aire → micrófono y coloreada por la sala.
//
// Con la referencia exacta se puede estimar ese camino y restarlo. Es el
// mismo principio que la cancelación de eco de una llamada, pero con ventaja:
// aquí se conoce la señal entera de antemano, sin trabajar contra el reloj.
//
// Dos pasos: encontrar el retardo (correlación cruzada sobre la envolvente) y
// adaptar un filtro que reste (NLMS). Lo que no se pueda explicar con la
// referencia — o sea, la voz — se queda.

enum AudioEchoRemover {

    struct Result {
        let outputURL: URL
        let delaySeconds: Double
        let reductionDB: Double
        var micRMS: Double = 0
        var cleanRMS: Double = 0
        var micCount: Int = 0
        var refCount: Int = 0
    }

    // Frecuencia de trabajo: 16 kHz basta para el eco de voz y hace el
    // filtrado unas tres veces más rápido que a 48.
    private static let workRate: Double = 16000

    static func removeSystemAudio(micURL: URL, referenceURL: URL, outputURL: URL,
                                  progress: ((String) -> Void)? = nil) throws -> Result {
        progress?("Leyendo el micrófono…")
        let mic = try monoSamples(from: micURL)
        progress?("Leyendo el sonido del sistema…")
        let ref = try monoSamples(from: referenceURL)
        guard mic.count > 1000, ref.count > 1000 else {
            throw NSError(domain: "EchoRemover", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Alguna de las dos pistas está vacía"])
        }

        progress?("Buscando el retardo…")
        let delaySamples = estimateDelay(mic: mic, reference: ref)

        progress?("Restando el sonido del sistema…")
        var cleaned = nlms(mic: mic, reference: ref, delay: delaySamples)
        progress?("Puliendo lo que quedó…")
        cleaned = suppressResidual(cleaned, reference: ref, delay: delaySamples)

        let before = rms(mic)
        let after = rms(cleaned)
        let reduction: Double = before > 0 && after > 0
            ? 20 * log10(Double(after) / Double(before)) : 0

        progress?("Guardando…")
        try write(samples: cleaned, to: outputURL)
        return Result(outputURL: outputURL,
                      delaySeconds: Double(delaySamples) / workRate,
                      reductionDB: reduction,
                      micRMS: Double(before), cleanRMS: Double(after),
                      micCount: mic.count, refCount: ref.count)
    }

    // MARK: Lectura

    // Mono a 16 kHz: el filtro trabaja igual y va mucho más rápido.
    private static func monoSamples(from url: URL) throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw NSError(domain: "EchoRemover", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "El archivo no tiene pista de audio"])
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: workRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        reader.startReading()
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &length, dataPointerOut: &pointer)
            if let pointer, length > 0 {
                let count = length / MemoryLayout<Float>.size
                pointer.withMemoryRebound(to: Float.self, capacity: count) { p in
                    samples.append(contentsOf: UnsafeBufferPointer(start: p, count: count))
                }
            }
            CMSampleBufferInvalidate(buffer)
        }
        return samples
    }

    // MARK: Retardo

    // El sonido tarda en llegar del altavoz al micrófono (y macOS añade su
    // propia latencia). Se busca ese desfase comparando la ENVOLVENTE de las
    // dos señales: es robusto aunque la sala cambie el timbre.
    static func estimateDelay(mic: [Float], reference: [Float],
                              maxSeconds: Double = 2.0) -> Int {
        let step = 32
        // Envolvente: cuánta energía hay en cada tramito. Comparar
        // envolventes aguanta que la sala cambie el timbre del sonido.
        let env: ([Float]) -> [Float] = { s in
            var out: [Float] = []
            out.reserveCapacity(s.count / step)
            var i = 0
            while i + step <= s.count {
                var acc: Float = 0
                s.withUnsafeBufferPointer { p in
                    vDSP_svesq(p.baseAddress! + i, 1, &acc, vDSP_Length(step))
                }
                out.append(sqrtf(acc))
                i += step
            }
            return out
        }
        var a = env(mic), b = env(reference)
        guard a.count > 40, b.count > 40 else { return 0 }
        // Se quita la media: si no, el desfase que más solapa gana siempre
        // por acumular más señal, no por parecerse más.
        let center: (inout [Float]) -> Void = { v in
            var m: Float = 0
            vDSP_meanv(v, 1, &m, vDSP_Length(v.count))
            var neg = -m
            vDSP_vsadd(v, 1, &neg, &v, 1, vDSP_Length(v.count))
        }
        center(&a); center(&b)

        let maxLag = min(Int(maxSeconds * workRate) / step, min(a.count, b.count) - 20)
        guard maxLag > 1 else { return 0 }

        var best: Float = -2
        var bestLag = 0
        for lag in 0..<maxLag {
            let n = min(a.count - lag, b.count)
            guard n > 20 else { break }
            var dot: Float = 0, na: Float = 0, nb: Float = 0
            a.withUnsafeBufferPointer { ap in
                b.withUnsafeBufferPointer { bp in
                    vDSP_dotpr(ap.baseAddress! + lag, 1, bp.baseAddress!, 1, &dot, vDSP_Length(n))
                    vDSP_svesq(ap.baseAddress! + lag, 1, &na, vDSP_Length(n))
                    vDSP_svesq(bp.baseAddress!, 1, &nb, vDSP_Length(n))
                }
            }
            // Correlación normalizada: 1 = idénticas, 0 = nada que ver.
            let denom = sqrtf(na * nb)
            guard denom > 1e-9 else { continue }
            let score = dot / denom
            if score > best { best = score; bestLag = lag }
        }
        return bestLag * step
    }

    // MARK: Resta adaptativa

    // NLMS: se estima cómo suena la referencia al llegar al micrófono y se
    // resta. El filtro se ajusta solo muestra a muestra; lo que la referencia
    // no explica (la voz) sobrevive.
    static func nlms(mic: [Float], reference: [Float], delay: Int,
                     taps: Int = 1024, mu: Float = 0.5) -> [Float] {
        var weights = [Float](repeating: 0, count: taps)
        var history = [Float](repeating: 0, count: taps)
        var out = [Float](repeating: 0, count: mic.count)

        for n in 0..<mic.count {
            let refIndex = n - delay
            let x: Float = (refIndex >= 0 && refIndex < reference.count) ? reference[refIndex] : 0
            // Ventana deslizante de la referencia (la más reciente al frente).
            history.removeLast()
            history.insert(x, at: 0)

            // La energía se MIDE sobre la ventana, no se lleva sumando: el
            // acumulado iba perdiendo precisión hasta volverse negativo, la
            // división se disparaba y el filtro escupía NaN.
            var energy: Float = 0
            vDSP_svesq(history, 1, &energy, vDSP_Length(taps))
            energy = max(energy, 1e-4)

            var estimate: Float = 0
            vDSP_dotpr(weights, 1, history, 1, &estimate, vDSP_Length(taps))
            guard estimate.isFinite else {
                // Si algo se desmadró, se reinicia el filtro y se sigue con
                // el micrófono tal cual en vez de devolver silencio roto.
                weights = [Float](repeating: 0, count: taps)
                out[n] = mic[n]
                continue
            }
            let error = mic[n] - estimate
            out[n] = error.isFinite ? error : mic[n]

            // Paso normalizado y acotado: sin el tope, un tramo casi mudo de
            // la referencia dispara el ajuste y rompe la adaptación.
            var f = mu * error / energy
            if !f.isFinite { f = 0 }
            f = min(max(f, -1), 1)
            vDSP_vsma(history, 1, &f, weights, 1, &weights, 1, vDSP_Length(taps))
        }
        return out
    }

    // Supresor de residuo: lo que el filtro no logró restar del todo. Se mira
    // tramo a tramo cuánta referencia había sonando y cuánto queda; si lo que
    // queda es sobre todo eco, se baja. Es lo que hace cualquier cancelador
    // de verdad después de restar, porque la resta nunca es perfecta: los
    // relojes de la cámara y de la pantalla van cada uno por su lado y el
    // altavoz distorsiona.
    //
    // La mano es SUAVE a propósito: bajar de más se comería la voz cuando se
    // habla justo mientras suena algo.
    static func suppressResidual(_ signal: [Float], reference: [Float], delay: Int,
                                 window: Int = 256, floorGain: Float = 0.25) -> [Float] {
        guard !signal.isEmpty else { return signal }
        var out = signal
        var previousGain: Float = 1
        var i = 0
        while i < signal.count {
            let n = min(window, signal.count - i)
            var sigEnergy: Float = 0
            signal.withUnsafeBufferPointer { p in
                vDSP_svesq(p.baseAddress! + i, 1, &sigEnergy, vDSP_Length(n))
            }
            let refStart = i - delay
            var refEnergy: Float = 0
            if refStart >= 0, refStart + n <= reference.count {
                reference.withUnsafeBufferPointer { p in
                    vDSP_svesq(p.baseAddress! + refStart, 1, &refEnergy, vDSP_Length(n))
                }
            }
            // Cuánto de lo que queda se explica por la referencia.
            let ratio = refEnergy / max(sigEnergy, 1e-9)
            var gain: Float = 1
            if ratio > 1 {
                gain = max(floorGain, 1 / sqrtf(ratio))
            }
            // Cambios graduales: un salto de ganancia se oye como un chasquido.
            gain = previousGain * 0.7 + gain * 0.3
            previousGain = gain
            out.withUnsafeMutableBufferPointer { p in
                var g = gain
                vDSP_vsmul(p.baseAddress! + i, 1, &g, p.baseAddress! + i, 1, vDSP_Length(n))
            }
            i += n
        }
        return out
    }

    private static func rms(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        var acc: Float = 0
        vDSP_measqv(s, 1, &acc, vDSP_Length(s.count))
        return sqrtf(acc)
    }

    // MARK: Escritura

    private static func write(samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: workRate, channels: 1, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: workRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 8192
        var offset = 0
        while offset < samples.count {
            let n = min(chunk, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(n)) else { break }
            buffer.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { p in
                buffer.floatChannelData![0].update(from: p.baseAddress! + offset, count: n)
            }
            try file.write(from: buffer)
            offset += n
        }
    }
}
