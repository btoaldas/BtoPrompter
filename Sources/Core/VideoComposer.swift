import AVFoundation
import CoreImage
import Foundation

// Composición de una grabación: cámara sobre pantalla (o lado a lado), con la
// forma y posición del preset elegido, alineadas con el desfase del sync.json.
// El MISMO compositor sirve para previsualizar y para exportar: lo que se ve
// es exactamente lo que sale.
//
// Los adornos se dibujan con Core Image, nunca con CALayer: la herramienta de
// Core Animation es solo para render offline y MATA la app si se asigna a un
// AVPlayerItem (excepción ObjC no capturable; reproducido en esta Mac).

// MARK: - Modelo

// Un preset es la receta completa de un montaje. camRect va normalizado 0..1
// con origen ARRIBA-izquierda (como piensa la gente); el compositor convierte
// al origen ABAJO-izquierda de Core Image en un único lugar.
struct CompositionLayout: Equatable {
    enum Mode: String { case overlay, sideBySide, onlyScreen, onlyCamera }
    enum Shape: String { case rect, rounded, circle }

    var mode: Mode = .overlay
    var camRect = CGRect(x: 0.72, y: 0.62, width: 0.25, height: 0.34)
    var shape: Shape = .circle
    var borderWidth: CGFloat = 0.012      // fracción del lado menor del lienzo
    var background: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.07, 0.09, 0.13)

    static func == (a: CompositionLayout, b: CompositionLayout) -> Bool {
        a.mode == b.mode && a.camRect == b.camRect && a.shape == b.shape
            && a.borderWidth == b.borderWidth
            && a.background == b.background
    }

    // Presets de fábrica, en el orden de las teclas 1–4.
    static let presets: [(name: String, layout: CompositionLayout)] = [
        ("Solo pantalla", CompositionLayout(mode: .onlyScreen)),
        ("Cara en círculo", CompositionLayout()),
        ("Lado a lado", CompositionLayout(mode: .sideBySide, shape: .rounded)),
        ("Solo cámara", CompositionLayout(mode: .onlyCamera)),
    ]
}

// Caja de parámetros compartida entre la UI y el compositor (hilos distintos).
// Cambiar el layout NO exige reconstruir la composición: el siguiente
// fotograma ya se dibuja con la receta nueva.
final class CompositionParameters: @unchecked Sendable {
    static let shared = CompositionParameters()
    private let lock = NSLock()
    private var _layout = CompositionLayout()
    var layout: CompositionLayout {
        get { lock.lock(); defer { lock.unlock() }; return _layout }
        set { lock.lock(); _layout = newValue; lock.unlock() }
    }
}

// MARK: - Compositor

// Instrucción propia: transporta los IDs de las dos pistas.
final class PiPInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let screenTrack: CMPersistentTrackID
    let cameraTrack: CMPersistentTrackID

    init(timeRange: CMTimeRange, screenTrack: CMPersistentTrackID, cameraTrack: CMPersistentTrackID) {
        self.timeRange = timeRange
        self.screenTrack = screenTrack
        self.cameraTrack = cameraTrack
        self.requiredSourceTrackIDs = [NSNumber(value: screenTrack), NSNumber(value: cameraTrack)]
    }
}

final class PiPCompositor: NSObject, AVVideoCompositing {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "pip.compositor")

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let instruction = request.videoCompositionInstruction as? PiPInstruction,
                  let out = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "PiPCompositor", code: 1))
                return
            }
            let size = CGSize(width: CVPixelBufferGetWidth(out), height: CVPixelBufferGetHeight(out))
            let layout = CompositionParameters.shared.layout

            let screen = request.sourceFrame(byTrackID: instruction.screenTrack).map { CIImage(cvPixelBuffer: $0) }
            let camera = request.sourceFrame(byTrackID: instruction.cameraTrack).map { CIImage(cvPixelBuffer: $0) }

            let image = Self.compose(screen: screen, camera: camera, layout: layout, canvas: size)
            self.context.render(image, to: out)
            request.finish(withComposedVideoFrame: out)
        }
    }

    // Función de dibujo pura: también la usa la exportación y cualquier
    // miniatura futura. Un solo sitio → lo que se ve es lo que sale.
    static func compose(screen: CIImage?, camera: CIImage?,
                        layout: CompositionLayout, canvas: CGSize) -> CIImage {
        let bg = CIImage(color: CIColor(red: layout.background.r,
                                        green: layout.background.g,
                                        blue: layout.background.b))
            .cropped(to: CGRect(origin: .zero, size: canvas))

        func fitted(_ img: CIImage, into rect: CGRect) -> CIImage {
            let s = img.extent.size
            guard s.width > 0, s.height > 0 else { return img }
            // .fill: cubre el rectángulo y recorta el sobrante.
            let scale = max(rect.width / s.width, rect.height / s.height)
            let scaled = img.transformed(by: .init(scaleX: scale, y: scale))
            let dx = rect.midX - scaled.extent.midX
            let dy = rect.midY - scaled.extent.midY
            return scaled.transformed(by: .init(translationX: dx, y: dy))
                .cropped(to: rect)
        }

        // camRect llega con origen arriba-izquierda; Core Image usa abajo-izquierda.
        func ciRect(_ n: CGRect) -> CGRect {
            CGRect(x: n.minX * canvas.width,
                   y: (1 - n.maxY) * canvas.height,
                   width: n.width * canvas.width,
                   height: n.height * canvas.height)
        }

        switch layout.mode {
        case .onlyScreen:
            guard let screen else { return bg }
            return fitted(screen, into: CGRect(origin: .zero, size: canvas)).composited(over: bg)
        case .onlyCamera:
            guard let camera else { return bg }
            return fitted(camera, into: CGRect(origin: .zero, size: canvas)).composited(over: bg)
        case .sideBySide:
            var result = bg
            let m = canvas.width * 0.02
            let half = (canvas.width - 3 * m) / 2
            let h = min(canvas.height - 2 * m, half * 9 / 16 * 2)
            let y = (canvas.height - h) / 2
            if let camera {
                result = shaped(fitted(camera, into: CGRect(x: m, y: y, width: half, height: h)),
                                shape: layout.shape, layout: layout, canvas: canvas)
                    .composited(over: result)
            }
            if let screen {
                result = shaped(fitted(screen, into: CGRect(x: half + 2 * m, y: y, width: half, height: h)),
                                shape: layout.shape, layout: layout, canvas: canvas)
                    .composited(over: result)
            }
            return result
        case .overlay:
            var result = bg
            if let screen {
                result = fitted(screen, into: CGRect(origin: .zero, size: canvas)).composited(over: result)
            }
            if let camera {
                let rect = ciRect(layout.camRect)
                // El círculo exige rectángulo cuadrado: se centra en el menor lado.
                let square = layout.shape == .circle
                    ? CGRect(x: rect.midX - min(rect.width, rect.height) / 2,
                             y: rect.midY - min(rect.width, rect.height) / 2,
                             width: min(rect.width, rect.height),
                             height: min(rect.width, rect.height))
                    : rect
                result = shaped(fitted(camera, into: square),
                                shape: layout.shape, layout: layout, canvas: canvas)
                    .composited(over: result)
            }
            return result
        }
    }

    // Recorta la imagen a la forma pedida y le pinta el aro del borde.
    private static func shaped(_ image: CIImage, shape: CompositionLayout.Shape,
                               layout: CompositionLayout, canvas: CGSize) -> CIImage {
        guard shape != .rect else { return image }
        let rect = image.extent
        let radius = shape == .circle ? rect.width / 2 : min(rect.width, rect.height) * 0.08
        let border = layout.borderWidth * min(canvas.width, canvas.height)

        // Máscara con CGContext (cacheable por geometría si hiciera falta).
        func maskImage(_ r: CGRect, inset: CGFloat) -> CIImage? {
            let w = Int(r.width), h = Int(r.height)
            guard w > 0, h > 0,
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            ctx.setFillColor(gray: 1, alpha: 1)
            let box = CGRect(x: 0, y: 0, width: r.width, height: r.height).insetBy(dx: inset, dy: inset)
            let rad = max(0, radius - inset)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: min(rad, box.width / 2),
                               cornerHeight: min(rad, box.height / 2), transform: nil))
            ctx.fillPath()
            guard let cg = ctx.makeImage() else { return nil }
            return CIImage(cgImage: cg)
                .transformed(by: .init(translationX: r.minX, y: r.minY))
        }

        guard let mask = maskImage(rect, inset: 0) else { return image }
        let blend = CIFilter(name: "CIBlendWithMask", parameters: [
            kCIInputImageKey: image,
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ])
        var result = blend?.outputImage ?? image

        if border > 0 {
            // Aro: forma llena de color menos la forma encogida.
            guard let outer = maskImage(rect, inset: 0),
                  let inner = maskImage(rect, inset: border) else { return result }
            let ringMask = CIFilter(name: "CISourceOutCompositing", parameters: [
                kCIInputImageKey: outer,
                kCIInputBackgroundImageKey: inner,
            ])?.outputImage ?? outer
            let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: rect)
            if let ring = CIFilter(name: "CIBlendWithMask", parameters: [
                kCIInputImageKey: white,
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: ringMask,
            ])?.outputImage {
                result = ring.composited(over: result)
            }
        }
        return result
    }
}

// MARK: - Construcción

enum CompositionBuilder {

    struct Sources {
        let screenURL: URL
        let cameraURL: URL
        let offsetSeconds: Double   // pantalla − cámara, del sync.json
    }

    // Carga una carpeta de grabación (los dos .mov + sync.json).
    static func sources(inFolder folder: URL) -> Sources? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return nil
        }
        guard let cam = files.first(where: { $0.lastPathComponent.hasPrefix("camara-") }),
              let scr = files.first(where: { $0.lastPathComponent.hasPrefix("pantalla-") }) else {
            return nil
        }
        var offset = 0.0
        if let data = try? Data(contentsOf: folder.appendingPathComponent("sync.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let o = json["offsetSeconds"] as? Double {
            offset = o
        }
        return Sources(screenURL: scr, cameraURL: cam, offsetSeconds: offset)
    }

    // Composición alineada y recortada a la pista más corta. La regla dura:
    // las instrucciones deben teselar [0, duración] sin huecos ni solapes, o
    // la exportación revienta con -11841.
    static func build(_ src: Sources) async throws
        -> (composition: AVMutableComposition, video: AVMutableVideoComposition) {
        let screenAsset = AVURLAsset(url: src.screenURL)
        let cameraAsset = AVURLAsset(url: src.cameraURL)

        let comp = AVMutableComposition()
        guard let screenTrack = try await screenAsset.loadTracks(withMediaType: .video).first,
              let cameraTrack = try await cameraAsset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "CompositionBuilder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Falta la pista de vídeo en alguno de los archivos"])
        }

        let screenDur = try await screenAsset.load(.duration).seconds
        let cameraDur = try await cameraAsset.load(.duration).seconds
        // El archivo que empezó tarde se corre hacia delante; ambos rebasan a
        // cero en disco, así que el desfase del sidecar es la única verdad.
        let camDelay = max(0, -src.offsetSeconds)
        let scrDelay = max(0, src.offsetSeconds)
        let usable = min(screenDur - scrDelay, cameraDur - camDelay)
        guard usable > 0.1 else {
            throw NSError(domain: "CompositionBuilder", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Las grabaciones no se solapan en el tiempo"])
        }
        let duration = CMTime(seconds: usable, preferredTimescale: 600)

        let vScreen = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try vScreen.insertTimeRange(
            CMTimeRange(start: CMTime(seconds: scrDelay, preferredTimescale: 600), duration: duration),
            of: screenTrack, at: .zero)
        let vCamera = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try vCamera.insertTimeRange(
            CMTimeRange(start: CMTime(seconds: camDelay, preferredTimescale: 600), duration: duration),
            of: cameraTrack, at: .zero)

        // El audio vive en el archivo de cámara.
        if let audio = try await cameraAsset.loadTracks(withMediaType: .audio).first {
            let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try aTrack.insertTimeRange(
                CMTimeRange(start: CMTime(seconds: camDelay, preferredTimescale: 600), duration: duration),
                of: audio, at: .zero)
        }

        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = PiPCompositor.self
        video.renderSize = CGSize(width: 1920, height: 1080)
        video.frameDuration = CMTime(value: 1, timescale: 30)
        video.instructions = [PiPInstruction(
            timeRange: CMTimeRange(start: .zero, duration: duration),
            screenTrack: vScreen.trackID, cameraTrack: vCamera.trackID)]
        return (comp, video)
    }
}

// MARK: - Exportación

enum CompositionExporter {

    // Passthrough ignora la videoComposition EN SILENCIO: jamás se ofrece.
    static func export(composition: AVMutableComposition,
                       video: AVMutableVideoComposition,
                       to url: URL,
                       progress: @escaping (Double) -> Void,
                       done: @escaping (Result<URL, Error>) -> Void) {
        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            done(.failure(NSError(domain: "CompositionExporter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No se pudo crear la sesión de exportación"])))
            return
        }
        session.videoComposition = video
        session.outputURL = url
        session.outputFileType = .mp4
        try? FileManager.default.removeItem(at: url)

        let timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            progress(Double(session.progress))
        }
        session.exportAsynchronously {
            DispatchQueue.main.async {
                timer.invalidate()
                switch session.status {
                case .completed: done(.success(url))
                case .cancelled:
                    done(.failure(NSError(domain: "CompositionExporter", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "Exportación cancelada"])))
                default:
                    done(.failure(session.error ?? NSError(domain: "CompositionExporter", code: 3)))
                }
            }
        }
    }
}
