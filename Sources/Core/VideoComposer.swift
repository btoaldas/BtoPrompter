import AVFoundation
import CoreImage
import Foundation

// El motor de dibujo del editor de composición. Cada fotograma pregunta al
// proyecto QUÉ receta rige en su instante (tramos de tiempo) y la pinta:
// cámara sobre pantalla, lado a lado con reparto ajustable, recortes por
// fuente y fondo de color, degradado o imagen.
//
// El MISMO compositor sirve para previsualizar y para exportar: lo que se ve
// es exactamente lo que sale.
//
// Los adornos se dibujan con Core Image, nunca con CALayer: la herramienta de
// Core Animation es solo para render offline y MATA la app si se asigna a un
// AVPlayerItem (excepción ObjC no capturable; reproducido en esta Mac).

// MARK: - Parámetros compartidos

// Caja compartida entre la UI y el compositor (hilos distintos). Cambiar el
// proyecto NO exige reconstruir la composición: el siguiente fotograma ya se
// dibuja con la receta nueva.
final class CompositionParameters: @unchecked Sendable {
    static let shared = CompositionParameters()
    private let lock = NSLock()
    private var _project = VideoProject()
    private var _exportProject: VideoProject?
    var project: VideoProject {
        get { lock.lock(); defer { lock.unlock() }; return _project }
        set { lock.lock(); _project = newValue; lock.unlock() }
    }
    // Copia CONGELADA para la exportación: si el usuario sigue moviendo
    // sliders mientras exporta, el archivo sale con lo que había al pulsar
    // Exportar, no con una mezcla de ambos.
    var exportProject: VideoProject? {
        get { lock.lock(); defer { lock.unlock() }; return _exportProject }
        set { lock.lock(); _exportProject = newValue; lock.unlock() }
    }
}

// El mismo dibujo, pero leyendo la copia congelada. Es la clase que se asigna
// a la composición de EXPORTACIÓN; la de previsualización usa PiPCompositor.
final class ExportCompositor: PiPCompositor {
    override var useExportSnapshot: Bool { true }
}

// MARK: - Instrucción

// Una sola instrucción cubre toda la línea de tiempo (imposible dejar huecos,
// que revientan la exportación con -11841); el compositor decide por instante.
final class PiPInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let screenTrack: CMPersistentTrackID
    let cameraTrack: CMPersistentTrackID
    // Pista de cada capa de vídeo del usuario (las imágenes no necesitan pista).
    let layerTracks: [UUID: CMPersistentTrackID]

    init(timeRange: CMTimeRange, screenTrack: CMPersistentTrackID,
         cameraTrack: CMPersistentTrackID,
         layerTracks: [UUID: CMPersistentTrackID] = [:]) {
        self.timeRange = timeRange
        self.screenTrack = screenTrack
        self.cameraTrack = cameraTrack
        self.layerTracks = layerTracks
        // Solo las pistas que existen: con una fuente única la otra es Invalid.
        self.requiredSourceTrackIDs = ([screenTrack, cameraTrack] + layerTracks.values)
            .filter { $0 != kCMPersistentTrackID_Invalid }
            .map { NSNumber(value: $0) }
    }
}

// MARK: - Compositor

class PiPCompositor: NSObject, AVVideoCompositing {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "pip.compositor")
    var useExportSnapshot: Bool { false }

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
            let project = (self.useExportSnapshot
                           ? CompositionParameters.shared.exportProject : nil)
                ?? CompositionParameters.shared.project
            let seconds = request.compositionTime.seconds
            let segIdx = project.segmentIndex(at: seconds)
            var layout = project.layouts.indices.contains(segIdx)
                ? project.layouts[segIdx] : SegmentLayout()
            // Acercamiento suave: durante los primeros milisegundos del tramo
            // el recorte se interpola desde el encuadre completo.
            if layout.zoomRampMs > 0 {
                let start = project.segmentRange(segIdx).start
                let ramp = layout.zoomRampMs / 1000
                if seconds < start + ramp {
                    let p = max(0, min(1, (seconds - start) / ramp))
                    if layout.screen.fit == .crop {
                        layout.screen.crop = layout.screen.crop.ramped(progress: p)
                    }
                    if layout.camera.fit == .crop {
                        layout.camera.crop = layout.camera.crop.ramped(progress: p)
                    }
                }
            }

            let screen = instruction.screenTrack == kCMPersistentTrackID_Invalid ? nil
                : request.sourceFrame(byTrackID: instruction.screenTrack).map { CIImage(cvPixelBuffer: $0) }
            let camera = instruction.cameraTrack == kCMPersistentTrackID_Invalid ? nil
                : request.sourceFrame(byTrackID: instruction.cameraTrack).map { CIImage(cvPixelBuffer: $0) }

            // Fotograma de cada capa visible en este instante: los vídeos
            // salen de su pista; las imágenes, de la cache de decodificación.
            var layerImages: [UUID: CIImage] = [:]
            let ordered = project.orderedLayers(at: seconds)
            for layer in ordered where layer.isVisible(at: seconds) {
                switch layer.kind {
                case .video:
                    if let tid = instruction.layerTracks[layer.id],
                       let buf = request.sourceFrame(byTrackID: tid) {
                        layerImages[layer.id] = CIImage(cvPixelBuffer: buf)
                    }
                case .image:
                    layerImages[layer.id] = FrameComposer.layerImage(layer.path)
                case .shape:
                    break   // se dibuja sola, no necesita imagen de origen
                }
            }

            var image = FrameComposer.compose(screen: screen, camera: camera,
                                              layout: layout, background: project.background,
                                              canvas: size, seconds: seconds,
                                              extraLayers: ordered,
                                              layerImages: layerImages,
                                              subtitles: project.subtitles,
                                              subtitlePreview: !self.useExportSnapshot,
                                              cursor: project.cursor,
                                              keystrokes: project.keystrokes)

            // Fundido de entrada: durante la ventana de la transición se
            // compone TAMBIÉN el tramo saliente y se mezclan. El corte sigue
            // siendo corte; solo la imagen funde.
            if segIdx > 0, layout.transitionIn == .fade {
                let start = project.segmentRange(segIdx).start
                let dur = layout.transitionMs / 1000
                if dur > 0, seconds < start + dur {
                    let progress = max(0, min(1, (seconds - start) / dur))
                    let prevLayout = project.layouts[segIdx - 1]
                    let prevOrdered = project.orderedLayers(forSegment: segIdx - 1)
                    let prevImage = FrameComposer.compose(
                        screen: screen, camera: camera, layout: prevLayout,
                        background: project.background, canvas: size,
                        seconds: seconds, extraLayers: prevOrdered,
                        layerImages: layerImages)
                    if let blend = CIFilter(name: "CIDissolveTransition", parameters: [
                        kCIInputImageKey: prevImage,
                        kCIInputTargetImageKey: image,
                        kCIInputTimeKey: progress,
                    ])?.outputImage {
                        image = blend.cropped(to: CGRect(origin: .zero, size: size))
                    }
                }
            }
            self.context.render(image, to: out)
            request.finish(withComposedVideoFrame: out)
        }
    }
}

// MARK: - Dibujo

// Función de dibujo pura y única: la usan el compositor (preview y export) y
// cualquier miniatura futura. Un solo sitio → WYSIWYG por construcción.
enum FrameComposer {

    static func compose(screen: CIImage?, camera: CIImage?,
                        layout: SegmentLayout, background: BackgroundStyle,
                        canvas: CGSize, seconds: Double = 0,
                        extraLayers: [ExtraLayer] = [],
                        layerImages: [UUID: CIImage] = [:],
                        subtitles: SubtitleTrack? = nil,
                        subtitlePreview: Bool = false,
                        cursor: CursorHighlight? = nil,
                        keystrokes: KeystrokeOverlay? = nil) -> CIImage {
        let base = composeBase(screen: screen, camera: camera, layout: layout,
                               background: background, canvas: canvas,
                               seconds: seconds, extraLayers: extraLayers,
                               layerImages: layerImages)
        // Capas de encima, en el orden del proyecto (la última va más arriba).
        var result = base
        for layer in extraLayers where !layer.behindCamera {
            result = drawLayer(layer, image: layerImages[layer.id],
                               at: seconds, over: result, canvas: canvas)
        }
        // Halo del puntero: va sobre la pantalla y bajo los subtítulos.
        if let cur = cursor, cur.enabled, let pos = cur.position(at: seconds) {
            result = drawCursorHalo(cur, at: pos, over: result, canvas: canvas)
        }
        // Teclas pulsadas: sobre todo, para que se lean.
        if let ks = keystrokes, ks.enabled, let label = ks.label(at: seconds),
           let img = keystrokeImage(label, style: ks, canvas: canvas) {
            result = img.composited(over: result)
        }
        // Subtítulos quemados SOLO si el proyecto lo pide (por defecto van
        // como .srt separado junto al MP4). En la previsualización se
        // muestran siempre que estén activados, para poder ajustar el estilo.
        if let track = subtitles, track.enabled, track.burnIn || subtitlePreview,
           let chunk = track.chunk(at: seconds),
           let img = subtitleImage(chunk.text, style: track.style, canvas: canvas) {
            result = img.composited(over: result)
        }
        return result
    }

    // Dibuja una capa del usuario sobre lo ya compuesto, si le toca verse.
    private static func drawLayer(_ layer: ExtraLayer, image: CIImage?,
                                  at seconds: Double, over result: CIImage,
                                  canvas: CGSize) -> CIImage {
        guard layer.isVisible(at: seconds) else { return result }
        // Las anotaciones se dibujan solas; el pixelado necesita ver lo que
        // hay debajo, así que recibe la composición actual.
        if layer.kind == .shape, let content = layer.shapeContent {
            return drawAnnotation(content, in: layer.rect, over: result, canvas: canvas)
        }
        guard let image else { return result }
        let rect = ciRect(layer.rect.cgRect, canvas: canvas)
        let side = min(rect.width, rect.height)
        let window = layer.shape == .circle
            ? CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2,
                     width: side, height: side)
            : rect
        var piece = place(image, settings: layer.settings, into: window)
        var shapeProxy = SegmentLayout()
        shapeProxy.borderWidth = layer.borderWidth
        piece = shaped(piece, shape: layer.shape, layout: shapeProxy, canvas: canvas)
        if layer.opacity < 1 {
            piece = piece.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: layer.opacity),
            ])
        }
        return piece.composited(over: result)
    }

    // Imagen de una capa (cacheada igual que el fondo).
    static func layerImage(_ path: String) -> CIImage? {
        cachedImage(path)
    }

    // Halo del puntero. Se dibuja en coordenadas del LIENZO: cuando la
    // pantalla ocupa todo (que es el caso normal) cae justo donde estaba el
    // ratón. Con la pantalla en una ventana pequeña o recortada, el halo
    // sigue el mismo encuadre general, que para señalar basta.
    static func drawCursorHalo(_ cur: CursorHighlight, at pos: (x: Double, y: Double),
                               over base: CIImage, canvas: CGSize) -> CIImage {
        let r = cur.radius * min(canvas.width, canvas.height)
        let cx = pos.x * canvas.width
        let cy = (1 - pos.y) * canvas.height      // el modelo va con origen arriba
        let box = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
        guard box.width > 2, r.isFinite, cx.isFinite, cy.isFinite else { return base }

        let w = Int(canvas.width), h = Int(canvas.height)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return base
        }
        // Relleno suave con un degradado radial: un círculo plano tapa el
        // contenido; así se ve por debajo.
        let space = CGColorSpaceCreateDeviceRGB()
        let inner = CGColor(red: cur.color.r, green: cur.color.g, blue: cur.color.b,
                            alpha: cur.color.a)
        let outer = CGColor(red: cur.color.r, green: cur.color.g, blue: cur.color.b, alpha: 0)
        if let gradient = CGGradient(colorsSpace: space,
                                     colors: [inner, outer] as CFArray,
                                     locations: [0, 1]) {
            ctx.saveGState()
            ctx.addEllipse(in: box)
            ctx.clip()
            ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                                   endCenter: CGPoint(x: cx, y: cy), endRadius: r,
                                   options: [])
            ctx.restoreGState()
        }
        if cur.ringWidth > 0 {
            let lw = cur.ringWidth * min(canvas.width, canvas.height)
            ctx.setStrokeColor(CGColor(red: cur.color.r, green: cur.color.g,
                                       blue: cur.color.b, alpha: min(1, cur.color.a + 0.4)))
            ctx.setLineWidth(lw)
            ctx.strokeEllipse(in: box.insetBy(dx: lw / 2, dy: lw / 2))
        }
        guard let cg = ctx.makeImage() else { return base }
        return CIImage(cgImage: cg).composited(over: base)
    }

    // Cápsula oscura con el atajo, como las de los tutoriales.
    private static let keyCache = NSCache<NSString, CIImage>()

    static func keystrokeImage(_ label: String, style: KeystrokeOverlay,
                               canvas: CGSize) -> CIImage? {
        let key = "\(label)|\(style.size)|\(style.corner.rawValue)|\(Int(canvas.width))" as NSString
        if let hit = keyCache.object(forKey: key) { return hit }

        let w = Int(canvas.width), h = Int(canvas.height)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        let size = style.size * canvas.height
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, size, nil)
        let attributed = NSAttributedString(string: label, attributes: [
            .font: font,
            .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let padX = size * 0.5, padY = size * 0.32
        let boxW = bounds.width + padX * 2, boxH = bounds.height + padY * 2
        let margin = size * 0.7

        let x: CGFloat, y: CGFloat
        switch style.corner {
        case .bottomLeft:   x = margin; y = margin
        case .bottomCenter: x = (canvas.width - boxW) / 2; y = margin
        case .bottomRight:  x = canvas.width - boxW - margin; y = margin
        case .topLeft:      x = margin; y = canvas.height - boxH - margin
        case .topRight:     x = canvas.width - boxW - margin; y = canvas.height - boxH - margin
        }
        let box = CGRect(x: x, y: y, width: boxW, height: boxH)

        ctx.setFillColor(CGColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 0.85))
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: boxH * 0.28,
                           cornerHeight: boxH * 0.28, transform: nil))
        ctx.fillPath()
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.2))
        ctx.setLineWidth(max(1, size * 0.04))
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: boxH * 0.28,
                           cornerHeight: boxH * 0.28, transform: nil))
        ctx.strokePath()

        ctx.textPosition = CGPoint(x: box.minX + padX, y: box.minY + padY - bounds.minY)
        CTLineDraw(line, ctx)

        guard let cg = ctx.makeImage() else { return nil }
        let image = CIImage(cgImage: cg)
        keyCache.setObject(image, forKey: key)
        return image
    }

    // MARK: Anotaciones

    // Las siete anotaciones de curso. El pixelado opera SOBRE lo compuesto
    // (tapa lo que hay debajo); el resto se dibuja encima con CGContext y se
    // cachea por geometría, igual que las máscaras.
    private static let annotationCache = NSCache<NSString, CIImage>()

    static func drawAnnotation(_ content: ShapeContent, in nrect: NRect,
                               over base: CIImage, canvas: CGSize) -> CIImage {
        let rect = ciRect(nrect.cgRect, canvas: canvas)
        guard rect.width > 1, rect.height > 1 else { return base }

        // Pixelar / desenfocar: se toma la zona de la imagen ya compuesta.
        if content.kind == .blur {
            let region = base.cropped(to: rect)
            let processed: CIImage?
            if content.pixelate {
                let scale = max(8, min(rect.width, rect.height) / 12)
                processed = region.applyingFilter("CIPixellate", parameters: [
                    kCIInputCenterKey: CIVector(x: rect.midX, y: rect.midY),
                    kCIInputScaleKey: scale,
                ]).cropped(to: rect)
            } else {
                processed = region
                    .clampedToExtent()
                    .applyingFilter("CIGaussianBlur",
                                    parameters: [kCIInputRadiusKey: max(6, rect.width / 20)])
                    .cropped(to: rect)
            }
            return (processed ?? region).composited(over: base)
        }

        let key = "\(content.kind.rawValue)|\(content.text)|\(content.thickness)|\(content.points.count)|"
            + "\(content.color.r),\(content.color.g),\(content.color.b)|"
            + "\(Int(rect.width))x\(Int(rect.height))|\(Int(rect.minX)),\(Int(rect.minY))|"
            + "\(Int(canvas.width))" as NSString
        if let hit = annotationCache.object(forKey: key) {
            return hit.composited(over: base)
        }

        let w = Int(canvas.width), h = Int(canvas.height)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return base
        }
        let color = CGColor(red: content.color.r, green: content.color.g,
                            blue: content.color.b, alpha: 1)
        let line = max(1, content.thickness * min(canvas.width, canvas.height))
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(line)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch content.kind {
        case .rect:
            ctx.stroke(rect.insetBy(dx: line / 2, dy: line / 2))
        case .ellipse:
            ctx.strokeEllipse(in: rect.insetBy(dx: line / 2, dy: line / 2))
        case .underline:
            // Línea gruesa pegada al borde inferior del recuadro.
            ctx.move(to: CGPoint(x: rect.minX, y: rect.minY + line))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + line))
            ctx.strokePath()
        case .strikethrough:
            ctx.move(to: CGPoint(x: rect.minX, y: rect.midY))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            ctx.strokePath()
        case .arrow:
            // De la esquina superior izquierda a la inferior derecha del
            // recuadro: mover el recuadro mueve y gira la flecha.
            let from = CGPoint(x: rect.minX, y: rect.maxY)
            let to = CGPoint(x: rect.maxX, y: rect.minY)
            ctx.move(to: from)
            ctx.addLine(to: to)
            ctx.strokePath()
            let angle = atan2(to.y - from.y, to.x - from.x)
            let head = max(line * 3.5, min(rect.width, rect.height) * 0.28)
            for side in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
                ctx.move(to: to)
                ctx.addLine(to: CGPoint(x: to.x + cos(angle + side) * head,
                                        y: to.y + sin(angle + side) * head))
            }
            ctx.strokePath()
        case .text:
            let size = max(12, rect.height * 0.7)
            let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, size, nil)
            let attributed = NSAttributedString(string: content.text, attributes: [
                .font: font, .foregroundColor: color,
            ])
            ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.05),
                          blur: size * 0.14,
                          color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.8))
            let setter = CTFramesetterCreateWithAttributedString(attributed)
            let path = CGPath(rect: rect, transform: nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
        case .note:
            // Nota adhesiva: rectángulo del color elegido con el texto encima
            // y una esquina doblada, como un papelito pegado.
            ctx.setFillColor(color)
            ctx.fill(rect)
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.18))
            let fold = min(rect.width, rect.height) * 0.18
            ctx.move(to: CGPoint(x: rect.maxX - fold, y: rect.maxY))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - fold))
            ctx.fillPath()
            if !content.text.isEmpty {
                let size = max(11, rect.height * 0.16)
                let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, size, nil)
                // Texto oscuro sobre la nota: se lee sobre amarillos y claros.
                let attributed = NSAttributedString(string: content.text, attributes: [
                    .font: font,
                    .foregroundColor: CGColor(red: 0.1, green: 0.09, blue: 0.05, alpha: 1),
                ])
                let setter = CTFramesetterCreateWithAttributedString(attributed)
                let inner = rect.insetBy(dx: size * 0.6, dy: size * 0.5)
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                                     CGPath(rect: inner, transform: nil), nil)
                CTFrameDraw(frame, ctx)
            }
        case .freehand:
            // Trazo a mano: los puntos van normalizados dentro del recuadro,
            // así el dibujo se mueve y crece con la capa.
            guard content.points.count > 1 else { break }
            ctx.setLineWidth(line)
            var first = true
            for pt in content.points where pt.count == 2 {
                let p = CGPoint(x: rect.minX + pt[0] * rect.width,
                                y: rect.minY + (1 - pt[1]) * rect.height)
                if first { ctx.move(to: p); first = false } else { ctx.addLine(to: p) }
            }
            ctx.strokePath()
        case .blur:
            break   // ya tratado arriba
        }

        guard let cg = ctx.makeImage() else { return base }
        let image = CIImage(cgImage: cg)
        annotationCache.setObject(image, forKey: key)
        return image.composited(over: base)
    }

    private static func composeBase(screen: CIImage?, camera: CIImage?,
                                    layout: SegmentLayout, background: BackgroundStyle,
                                    canvas: CGSize, seconds: Double,
                                    extraLayers: [ExtraLayer],
                                    layerImages: [UUID: CIImage]) -> CIImage {
        let bg = backgroundImage(background, canvas: canvas)

        // Capas "detrás de la cámara": entre el contenido base y la cámara
        // flotante en modo overlay; bajo todo lo demás en el resto de modos.
        func withBehindLayers(_ current: CIImage) -> CIImage {
            var r = current
            for layer in extraLayers where layer.behindCamera {
                r = drawLayer(layer, image: layerImages[layer.id],
                              at: seconds, over: r, canvas: canvas)
            }
            return r
        }

        switch layout.mode {
        case .onlyScreen:
            guard let screen else { return withBehindLayers(bg) }
            return place(screen, settings: layout.screen,
                         into: CGRect(origin: .zero, size: canvas))
                .composited(over: withBehindLayers(bg))
        case .onlyCamera:
            guard let camera else { return withBehindLayers(bg) }
            return place(camera, settings: layout.camera,
                         into: CGRect(origin: .zero, size: canvas))
                .composited(over: withBehindLayers(bg))
        case .sideBySide:
            var result = withBehindLayers(bg)
            let m = canvas.width * 0.02
            let usable = canvas.width - 3 * m
            // El reparto es la fracción del ancho para la cámara: 30/70, 50/50…
            let camW = usable * layout.splitRatio
            let scrW = usable - camW
            let h = canvas.height - 2 * m
            let y = m
            if let camera {
                let rect = CGRect(x: m, y: y, width: camW, height: h)
                result = shaped(place(camera, settings: layout.camera, into: rect),
                                shape: layout.shape, layout: layout, canvas: canvas)
                    .composited(over: result)
            }
            if let screen {
                let rect = CGRect(x: m + camW + m, y: y, width: scrW, height: h)
                result = shaped(place(screen, settings: layout.screen, into: rect),
                                shape: layout.shape, layout: layout, canvas: canvas)
                    .composited(over: result)
            }
            return result
        case .overlay:
            var result = bg
            if let screen {
                result = place(screen, settings: layout.screen,
                               into: CGRect(origin: .zero, size: canvas))
                    .composited(over: result)
            }
            result = withBehindLayers(result)
            if let camera {
                let rect = ciRect(layout.camRect.cgRect, canvas: canvas)
                // El círculo exige ventana cuadrada: se centra en el lado menor.
                let side = min(rect.width, rect.height)
                let window = layout.shape == .circle
                    ? CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2,
                             width: side, height: side)
                    : rect
                result = shaped(place(camera, settings: layout.camera, into: window),
                                shape: layout.shape, layout: layout, canvas: canvas)
                    .composited(over: result)
            }
            return result
        }
    }

    // camRect llega con origen arriba-izquierda; Core Image usa abajo-izquierda.
    private static func ciRect(_ n: CGRect, canvas: CGSize) -> CGRect {
        CGRect(x: n.minX * canvas.width,
               y: (1 - n.maxY) * canvas.height,
               width: n.width * canvas.width,
               height: n.height * canvas.height)
    }

    // Coloca una fuente en su ventana según sus ajustes (escala o recorte).
    private static func place(_ image: CIImage, settings: SourceSettings, into rect: CGRect) -> CIImage {
        var source = image
        // Recorte manual: primero se queda solo la parte elegida del fotograma.
        if settings.fit == .crop, !settings.crop.isFull {
            let s = image.extent
            let c = settings.crop.clamped()
            // El crop viene con origen arriba-izquierda sobre la fuente.
            let cropRect = CGRect(x: s.minX + c.x * s.width,
                                  y: s.minY + (1 - c.y - c.height) * s.height,
                                  width: c.width * s.width,
                                  height: c.height * s.height)
            source = image.cropped(to: cropRect)
        }
        let s = source.extent
        guard s.width > 0, s.height > 0 else { return source }
        let sx: CGFloat, sy: CGFloat
        switch settings.fit {
        case .fill, .crop:
            let k = max(rect.width / s.width, rect.height / s.height)
            sx = k; sy = k
        case .fit:
            let k = min(rect.width / s.width, rect.height / s.height)
            sx = k; sy = k
        case .stretch:
            // Deformar: cada eje a su escala, la proporción no se respeta.
            sx = rect.width / s.width
            sy = rect.height / s.height
        }
        let scaled = source.transformed(by: .init(scaleX: sx, y: sy))
        let dx = rect.midX - scaled.extent.midX
        let dy = rect.midY - scaled.extent.midY
        let moved = scaled.transformed(by: .init(translationX: dx, y: dy))
        return settings.fit == .fit ? moved.cropped(to: moved.extent.intersection(rect))
                                    : moved.cropped(to: rect)
    }

    // MARK: Fondos

    // La imagen de fondo se decodifica UNA vez por ruta (los fotogramas llegan
    // a 30 por segundo; releer el archivo en cada uno sería absurdo).
    private static let imageCache = NSCache<NSString, CIImage>()

    private static func backgroundImage(_ style: BackgroundStyle, canvas: CGSize) -> CIImage {
        let frame = CGRect(origin: .zero, size: canvas)
        switch style {
        case .color(let c):
            return CIImage(color: CIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a))
                .cropped(to: frame)
        case .gradient(let top, let bottom):
            let f = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: canvas.height),
                "inputColor0": CIColor(red: top.r, green: top.g, blue: top.b, alpha: top.a),
                "inputPoint1": CIVector(x: 0, y: 0),
                "inputColor1": CIColor(red: bottom.r, green: bottom.g, blue: bottom.b, alpha: bottom.a),
            ])
            return (f?.outputImage ?? CIImage.empty()).cropped(to: frame)
        case .image(let path, let mode):
            guard let img = cachedImage(path) else {
                return CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1)).cropped(to: frame)
            }
            return placedBackground(img, mode: mode, canvas: canvas)
        }
    }

    // Las rutas que fallaron también se recuerdan: sin esto, una imagen
    // borrada provocaba una lectura de disco fallida por CADA fotograma.
    private static let missingLock = NSLock()
    private static var missingPaths = Set<String>()

    static func forgetMissing(_ path: String) {
        missingLock.lock()
        missingPaths.remove(path)
        missingLock.unlock()
    }

    private static func cachedImage(_ path: String) -> CIImage? {
        if let hit = imageCache.object(forKey: path as NSString) { return hit }
        missingLock.lock()
        let known = missingPaths.contains(path)
        missingLock.unlock()
        if known { return nil }
        guard let img = CIImage(contentsOf: URL(fileURLWithPath: path)) else {
            missingLock.lock()
            missingPaths.insert(path)
            missingLock.unlock()
            return nil
        }
        imageCache.setObject(img, forKey: path as NSString)
        return img
    }

    private static func placedBackground(_ img: CIImage, mode: BackgroundStyle.ImageMode,
                                         canvas: CGSize) -> CIImage {
        let frame = CGRect(origin: .zero, size: canvas)
        let s = img.extent.size
        guard s.width > 0, s.height > 0 else { return CIImage.empty().cropped(to: frame) }
        let base = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: frame)
        switch mode {
        case .fill:
            let scale = max(canvas.width / s.width, canvas.height / s.height)
            return centered(img, scale: scale, canvas: canvas).cropped(to: frame)
        case .fit:
            let scale = min(canvas.width / s.width, canvas.height / s.height)
            return centered(img, scale: scale, canvas: canvas)
                .composited(over: base).cropped(to: frame)
        case .stretch:
            return img.transformed(by: .init(scaleX: canvas.width / s.width,
                                             y: canvas.height / s.height))
                .transformed(by: .init(translationX: -img.extent.minX * canvas.width / s.width,
                                       y: -img.extent.minY * canvas.height / s.height))
                .cropped(to: frame)
        case .tile:
            // CIImage infinita por teselado y recorte al lienzo.
            let tiled = img.transformed(by: .init(translationX: -img.extent.minX,
                                                  y: -img.extent.minY))
            let f = CIFilter(name: "CIAffineTile", parameters: [
                kCIInputImageKey: tiled,
                kCIInputTransformKey: NSAffineTransform(),
            ])
            return (f?.outputImage ?? tiled).cropped(to: frame)
        case .center:
            return centered(img, scale: 1, canvas: canvas)
                .composited(over: base).cropped(to: frame)
        }
    }

    private static func centered(_ img: CIImage, scale: CGFloat, canvas: CGSize) -> CIImage {
        let scaled = img.transformed(by: .init(scaleX: scale, y: scale))
        let dx = canvas.width / 2 - scaled.extent.midX
        let dy = canvas.height / 2 - scaled.extent.midY
        return scaled.transformed(by: .init(translationX: dx, y: dy))
    }

    // MARK: Subtítulos

    // El texto se dibuja UNA vez por frase+estilo y se cachea: a 30 fps
    // redibujar tipografía en cada fotograma sería un despilfarro.
    private static let subtitleCache = NSCache<NSString, CIImage>()

    static func subtitleImage(_ text: String, style: SubtitleStyle,
                              canvas: CGSize) -> CIImage? {
        let key = "\(text)|\(style.fontSize)|\(style.position.rawValue)|\(style.maxLines)|"
            + "\(style.widthFraction)|\(style.boxOpacity)|\(style.shadow)|"
            + "\(style.color.r),\(style.color.g),\(style.color.b)|"
            + "\(style.shadowColor.r)|\(style.boxColor.r)|\(style.margin)|\(canvas.width)" as NSString
        if let hit = subtitleCache.object(forKey: key) { return hit }

        let w = Int(canvas.width), h = Int(canvas.height)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        let fontSize = style.fontSize * canvas.height
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let textColor = CGColor(red: style.color.r, green: style.color.g,
                                blue: style.color.b, alpha: 1)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)

        // Envoltura al ancho elegido; se limita al número de filas del estilo.
        let maxWidth = canvas.width * style.widthFraction
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let lineHeight = fontSize * 1.25
        let allowedHeight = lineHeight * Double(style.maxLines) + 4
        let textSize = CGSize(width: min(fit.width, maxWidth),
                              height: min(fit.height, allowedHeight))

        // Posición del bloque en el lienzo (coordenadas CG: abajo-izquierda).
        let x = (canvas.width - textSize.width) / 2
        let y: CGFloat
        switch style.position {
        case .bottom: y = style.margin * canvas.height
        case .middle: y = (canvas.height - textSize.height) / 2
        case .top: y = canvas.height - textSize.height - style.margin * canvas.height
        }
        let textRect = CGRect(x: x, y: y, width: textSize.width, height: textSize.height)

        // Caja de fondo.
        if style.boxOpacity > 0 {
            ctx.setFillColor(CGColor(red: style.boxColor.r, green: style.boxColor.g,
                                     blue: style.boxColor.b, alpha: style.boxOpacity))
            let pad = fontSize * 0.35
            let box = textRect.insetBy(dx: -pad, dy: -pad * 0.6)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: pad * 0.5,
                               cornerHeight: pad * 0.5, transform: nil))
            ctx.fillPath()
        }

        // Sombra del texto.
        if style.shadow {
            ctx.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.06),
                          blur: fontSize * 0.16,
                          color: CGColor(red: style.shadowColor.r, green: style.shadowColor.g,
                                         blue: style.shadowColor.b, alpha: 0.9))
        }

        let path = CGPath(rect: textRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                             path, nil)
        CTFrameDraw(frame, ctx)

        guard let cg = ctx.makeImage() else { return nil }
        let image = CIImage(cgImage: cg)
        subtitleCache.setObject(image, forKey: key)
        return image
    }

    // MARK: Formas

    // Recorta la imagen a la forma pedida y le pinta el aro del borde.
    private static func shaped(_ image: CIImage, shape: SegmentLayout.Shape,
                               layout: SegmentLayout, canvas: CGSize) -> CIImage {
        guard shape != .rect else { return image }
        let rect = image.extent
        guard rect.width > 0, rect.height > 0 else { return image }
        let radius = shape == .circle ? rect.width / 2 : min(rect.width, rect.height) * 0.08
        let border = layout.borderWidth * min(canvas.width, canvas.height)

        func maskImage(_ r: CGRect, inset: CGFloat) -> CIImage? {
            let w = Int(r.width), h = Int(r.height)
            guard w > 0, h > 0,
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            ctx.setFillColor(gray: 1, alpha: 1)
            let box = CGRect(x: 0, y: 0, width: r.width, height: r.height).insetBy(dx: inset, dy: inset)
            guard box.width > 0, box.height > 0 else { return nil }
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

    // Cuánto hay que saltarse del principio de cada archivo para que todos
    // empiecen en el MISMO instante real. El que arrancó antes tiene metraje
    // de más; el último no se toca. Función pura, probada en --selftest:
    // aquí vivía el fallo que descuadraba la voz, la imagen y el escritorio.
    static func alignmentDelays(offsets: [String: Double]) -> [String: Double] {
        guard let latest = offsets.values.max() else { return [:] }
        return offsets.mapValues { max(0, latest - $0) }
    }


    // Una parte física de una pieza: el archivo y su instante real de
    // arranque (offsetSeconds del sync.json, medido contra la primera pieza
    // que arrancó). Tras un corte a mitad de toma hay varias.
    struct SourcePart {
        let url: URL
        let offset: Double
    }

    struct Sources {
        let screenURL: URL?
        let cameraURL: URL?
        let offsetSeconds: Double   // pantalla − cámara, del sync.json
        // Cuánto tarde arrancó CADA pieza respecto a la primera. Cada archivo
        // tiene su propio instante: aplicar a la voz el desfase de la cámara
        // (lo que se hacía antes) descuadraba todo.
        var cameraOffset: Double = 0
        var screenOffset: Double = 0
        var micOffset: Double = 0
        // TODAS las partes de cada pieza, en orden de arranque. El montaje
        // coloca cada una en su instante y el hueco del corte queda a la
        // vista (fondo) en vez de descartar en silencio todo lo recuperado.
        var screenParts: [SourcePart] = []
        var cameraParts: [SourcePart] = []
    }

    // Carga una carpeta de grabación (los dos .mov + sync.json). Las fuentes
    // PROPIAS del proyecto mandan: el usuario puede poner su vídeo en lugar
    // de la pantalla o de la cámara grabadas, o aportarlas si no existen.
    // Montar las partes recuperadas es parametrizable; apagado, se compone
    // solo la parte 1 (comportamiento clásico) y el editor avisa del resto.
    static var wantMountParts: Bool { Settings.bool(.editorMountParts, default: true) }

    static func sources(inFolder folder: URL) -> Sources? {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var cam = primaryFile(prefix: "camara-", in: files)
        var scr = primaryFile(prefix: "pantalla-", in: files)
        var offset = 0.0
        var camOff = 0.0, scrOff = 0.0, micOff = 0.0
        var screenSegs: [SourcePart] = []
        var cameraSegs: [SourcePart] = []
        if let data = try? Data(contentsOf: folder.appendingPathComponent("sync.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let o = json["offsetSeconds"] as? Double { offset = o }
            camOff = json["cameraOffset"] as? Double ?? 0
            scrOff = json["screenOffset"] as? Double ?? 0
            micOff = json["micOffset"] as? Double ?? camOff
            // Grabaciones antiguas: solo traían el desfase pantalla−cámara.
            if json["cameraOffset"] == nil {
                camOff = max(0, -offset)
                scrOff = max(0, offset)
                micOff = camOff
            }
            // Si hubo cortes, el blindaje dejó el instante real de cada
            // parte; solo cuentan las que siguen existiendo en disco.
            func segs(_ key: String) -> [SourcePart] {
                guard let raw = json[key] as? [[String: Any]] else { return [] }
                return raw.compactMap { entry -> SourcePart? in
                    guard let f = entry["file"] as? String,
                          let o = entry["offsetSeconds"] as? Double else { return nil }
                    let url = folder.appendingPathComponent(f)
                    guard fm.fileExists(atPath: url.path) else { return nil }
                    return SourcePart(url: url, offset: o)
                }.sorted { $0.offset < $1.offset }
            }
            if wantMountParts {
                screenSegs = segs("screenSegments")
                cameraSegs = segs("cameraSegments")
            }
        }
        if let data = try? Data(contentsOf: VideoProjectStore.projectURL(inFolder: folder)),
           let project = try? JSONDecoder().decode(VideoProject.self, from: data) {
            if let c = project.cameraOverridePath, fm.fileExists(atPath: c) {
                cam = URL(fileURLWithPath: c)
                offset = 0   // el desfase medido solo vale para lo grabado junto
                cameraSegs = []   // el archivo del usuario es una sola parte
            }
            if let s = project.screenOverridePath, fm.fileExists(atPath: s) {
                scr = URL(fileURLWithPath: s)
                offset = 0
                screenSegs = []
            }
        }
        // Con UNA sola pieza también se puede componer (recortes y fondo
        // siguen valiendo); la grabación de fábrica es solo-cámara.
        guard cam != nil || scr != nil else { return nil }
        var src = Sources(screenURL: scr, cameraURL: cam, offsetSeconds: offset,
                          cameraOffset: camOff, screenOffset: scrOff, micOffset: micOff)
        // Con registro de cortes mandan los segmentos (traen el instante REAL
        // de cada parte, aunque solo sobreviva una); sin registro, la pieza
        // es una sola parte con su desfase del sidecar.
        src.screenParts = !screenSegs.isEmpty ? screenSegs
            : (scr.map { [SourcePart(url: $0, offset: scrOff)] } ?? [])
        src.cameraParts = !cameraSegs.isEmpty ? cameraSegs
            : (cam.map { [SourcePart(url: $0, offset: camOff)] } ?? [])
        return src
    }

    // Tras un corte a mitad de toma hay varias partes (pantalla-<fecha>.mov,
    // pantalla-<fecha>.parte2.mov…) y el orden de carpeta no es determinista:
    // la pieza principal es siempre la de nombre más corto (la parte 1).
    static func primaryFile(prefix: String, in files: [URL],
                            ext: String = "mov") -> URL? {
        files.filter { $0.lastPathComponent.hasPrefix(prefix)
                       && $0.pathExtension.lowercased() == ext }
            .min { ($0.lastPathComponent.count, $0.lastPathComponent)
                 < ($1.lastPathComponent.count, $1.lastPathComponent) }
    }

    // Qué partes de la carpeta NO van a aparecer en el montaje, con su motivo:
    // sin registro en sync.json (o montaje apagado), ilegibles, o fuera del
    // alcance porque la otra pieza termina antes. Repite la matemática de
    // build() con las duraciones reales — estar en sources no basta: el aviso
    // honesto se decide con lo que placeParts de verdad coloca.
    static func unmountedParts(inFolder folder: URL, sources src: Sources) async
        -> [(file: String, reason: String)] {
        var out: [(file: String, reason: String)] = []
        let fm = FileManager.default
        let all = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let registered = Set((src.screenParts + src.cameraParts).map { $0.url.lastPathComponent })
        for f in all where f.lastPathComponent.contains(".parte")
                && f.pathExtension.lowercased() == "mov"
                && !registered.contains(f.lastPathComponent) {
            out.append((f.lastPathComponent,
                        "sin registro en sync.json o con el montaje de partes apagado"))
        }
        struct Probe { let file: String; let offset: Double; let dur: Double }
        func probe(_ parts: [SourcePart]) async -> [Probe] {
            var res: [Probe] = []
            for p in parts.sorted(by: { $0.offset < $1.offset }) {
                let asset = AVURLAsset(url: p.url)
                guard let v = try? await asset.loadTracks(withMediaType: .video).first,
                      let range = try? await v.load(.timeRange),
                      range.end.seconds > 0.05 else {
                    if p.url.lastPathComponent.contains(".parte") {
                        out.append((p.url.lastPathComponent, "ilegible: sin vídeo utilizable"))
                    }
                    continue
                }
                res.append(Probe(file: p.url.lastPathComponent,
                                 offset: p.offset, dur: range.end.seconds))
            }
            return res
        }
        let scr = await probe(src.screenParts)
        let cam = await probe(src.cameraParts)
        var named: [Double] = []
        if !cam.isEmpty { named.append(src.cameraOffset) }
        if !scr.isEmpty { named.append(src.screenOffset) }
        let latest = named.max() ?? 0
        func coverage(_ ps: [Probe]) -> Double {
            ps.map { $0.offset - latest + $0.dur }.max() ?? .infinity
        }
        let usable = min(scr.isEmpty ? .infinity : coverage(scr),
                         cam.isEmpty ? .infinity : coverage(cam))
        for ps in [scr, cam] {
            let placements = placeParts(ps.map { ($0.offset, $0.dur) },
                                        latest: latest, usable: usable)
            for (p, place) in zip(ps, placements)
                where place == nil && p.file.contains(".parte") {
                out.append((p.file, "fuera del montaje: la otra pieza termina antes"))
            }
        }
        return out
    }

    // Dónde cae cada parte en la línea de tiempo del montaje. PURA y probada
    // en --selftest. Entrada YA ordenada por arranque; salida alineada 1:1
    // con la entrada (nil = la parte queda fuera). `latest` es el arranque de
    // la pieza que más tardó (el cero del montaje) y `usable` la duración
    // total. La parte 1 puede arrancar ANTES del cero: se le salta ese
    // metraje. Las siguientes caen después, dejando a la vista el hueco del
    // corte que las separó.
    struct PartPlacement: Equatable {
        let sourceStart: Double   // qué saltarse del principio del archivo
        let start: Double         // dónde empieza en el montaje
        let length: Double
    }

    static func placeParts(_ parts: [(offset: Double, dur: Double)],
                           latest: Double, usable: Double) -> [PartPlacement?] {
        var prevEnd = 0.0
        return parts.map { p in
            let compStart = p.offset - latest
            var skip = max(0, -compStart)
            var at = max(0, compStart)
            // Defensa: las partes no deben solaparse; si el sidecar trae algo
            // raro, la posterior se recorta por delante.
            if at < prevEnd {
                skip += prevEnd - at
                at = prevEnd
            }
            let length = min(p.dur - skip, usable - at)
            guard length > 0.05 else { return nil }
            prevEnd = at + length
            return PartPlacement(sourceStart: skip, start: at, length: length)
        }
    }

    // Composición alineada. La regla dura: las instrucciones deben teselar
    // [0, duración] sin huecos ni solapes, o la exportación revienta con
    // -11841 (aquí: una sola instrucción total). Los huecos de las PISTAS sí
    // están permitidos: el compositor pinta el fondo cuando una pieza no
    // tiene fotograma en ese instante.
    static func build(_ src: Sources, extraLayers: [ExtraLayer] = [],
                      audioLayers: [AudioLayer] = [], micVolume: Double = 1.0,
                      screenAudioVolume: Double = 1.0) async throws
        -> (composition: AVMutableComposition, video: AVMutableVideoComposition,
            duration: Double, audioMix: AVAudioMix?) {
        // Partes de cada pieza; si Sources llegó construido a mano, la
        // principal hace de parte única con su desfase.
        let screenPartList = !src.screenParts.isEmpty ? src.screenParts
            : (src.screenURL.map { [SourcePart(url: $0, offset: src.screenOffset)] } ?? [])
        let cameraPartList = !src.cameraParts.isEmpty ? src.cameraParts
            : (src.cameraURL.map { [SourcePart(url: $0, offset: src.cameraOffset)] } ?? [])

        let comp = AVMutableComposition()

        // Cada parte con su asset, duración y pistas; las que no tienen vídeo
        // (restos de un intento fallido) se descartan enteras.
        struct LoadedPart {
            let asset: AVURLAsset
            let offset: Double
            let dur: Double
            let video: AVAssetTrack
            let audio: AVAssetTrack?
        }
        func load(_ parts: [SourcePart]) async -> [LoadedPart] {
            var out: [LoadedPart] = []
            for p in parts.sorted(by: { $0.offset < $1.offset }) {
                let asset = AVURLAsset(url: p.url)
                // La duración que manda es la de la pista de VÍDEO, no la del
                // asset: en las partes del reinicio el audio dura ~0.14 s más
                // y con asset.duration el final del montaje quedaba en fondo
                // puro (fotogramas sin fuente) con el audio aún sonando.
                guard let v = try? await asset.loadTracks(withMediaType: .video).first,
                      let range = try? await v.load(.timeRange),
                      range.end.seconds > 0.05
                else { continue }
                let a = try? await asset.loadTracks(withMediaType: .audio).first
                out.append(LoadedPart(asset: asset, offset: p.offset, dur: range.end.seconds,
                                      video: v, audio: a ?? nil))
            }
            return out
        }
        let screenLoaded = await load(screenPartList)
        let cameraLoaded = await load(cameraPartList)
        guard !screenLoaded.isEmpty || !cameraLoaded.isEmpty else {
            throw NSError(domain: "CompositionBuilder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Ningún archivo tiene pista de vídeo"])
        }

        // El archivo que empezó tarde se corre hacia delante; ambos rebasan a
        // cero en disco, así que el desfase del sidecar es la única verdad.
        // El montaje empieza donde ya existían todas las piezas — el arranque
        // más tardío — y a cada archivo se le salta la diferencia.
        // (Ojo: es al revés de lo que parece; recortarle su propio desfase a
        // cada uno descuadraba todo, que es lo que se veía al reproducir.)
        var named: [String: Double] = [:]
        if !cameraLoaded.isEmpty { named["camara"] = src.cameraOffset }
        if !screenLoaded.isEmpty { named["pantalla"] = src.screenOffset }
        let latest = named.values.max() ?? 0
        // El montaje ya no se recorta a la parte 1: dura hasta donde llegue
        // la última parte de la pieza que antes termine.
        func coverage(_ parts: [LoadedPart]) -> Double {
            parts.map { $0.offset - latest + $0.dur }.max() ?? .infinity
        }
        let usable = min(screenLoaded.isEmpty ? .infinity : coverage(screenLoaded),
                         cameraLoaded.isEmpty ? .infinity : coverage(cameraLoaded))
        guard usable > 0.1, usable.isFinite else {
            throw NSError(domain: "CompositionBuilder", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Las grabaciones no se solapan en el tiempo"])
        }
        let duration = CMTime(seconds: usable, preferredTimescale: 600)

        // Inserta las partes de una pieza en una pista del montaje, cada una
        // en su instante; los huecos quedan vacíos y el compositor pinta el
        // fondo. La misma matemática vale para el vídeo y para su audio.
        func insert(_ parts: [LoadedPart], into track: AVMutableCompositionTrack,
                    pick: (LoadedPart) -> AVAssetTrack?) {
            let placements = placeParts(parts.map { ($0.offset, $0.dur) },
                                        latest: latest, usable: usable)
            for (part, place) in zip(parts, placements) {
                guard let place, let source = pick(part) else { continue }
                try? track.insertTimeRange(
                    CMTimeRange(start: CMTime(seconds: place.sourceStart, preferredTimescale: 600),
                                duration: CMTime(seconds: place.length, preferredTimescale: 600)),
                    of: source, at: CMTime(seconds: place.start, preferredTimescale: 600))
            }
        }

        var screenID = kCMPersistentTrackID_Invalid
        if !screenLoaded.isEmpty {
            let vScreen = comp.addMutableTrack(withMediaType: .video,
                                               preferredTrackID: kCMPersistentTrackID_Invalid)!
            insert(screenLoaded, into: vScreen) { $0.video }
            screenID = vScreen.trackID
        }
        var cameraID = kCMPersistentTrackID_Invalid
        if !cameraLoaded.isEmpty {
            let vCamera = comp.addMutableTrack(withMediaType: .video,
                                               preferredTrackID: kCMPersistentTrackID_Invalid)!
            insert(cameraLoaded, into: vCamera) { $0.video }
            cameraID = vCamera.trackID
        }

        // El micrófono viaja dentro del archivo de cámara, con su volumen.
        var mixParams: [AVMutableAudioMixInputParameters] = []
        if cameraLoaded.contains(where: { $0.audio != nil }) {
            let aTrack = comp.addMutableTrack(withMediaType: .audio,
                                              preferredTrackID: kCMPersistentTrackID_Invalid)!
            insert(cameraLoaded, into: aTrack) { $0.audio }
            let params = AVMutableAudioMixInputParameters(track: aTrack)
            params.setVolume(Float(micVolume), at: .zero)
            mixParams.append(params)
        }

        // El sonido del SISTEMA vive en el archivo de pantalla (si la
        // grabación lo capturó). Su volumen es independiente del micrófono:
        // así se ve el escritorio con el audio de la webcam, o al revés.
        if screenLoaded.contains(where: { $0.audio != nil }) {
            let aTrack = comp.addMutableTrack(withMediaType: .audio,
                                              preferredTrackID: kCMPersistentTrackID_Invalid)!
            insert(screenLoaded, into: aTrack) { $0.audio }
            let params = AVMutableAudioMixInputParameters(track: aTrack)
            params.setVolume(Float(screenAudioVolume), at: .zero)
            mixParams.append(params)
        }

        // Audios del usuario: cada uno es una pista más, con su volumen, su
        // recorte del archivo (sourceStart) y su sitio en el proyecto
        // (projectStart). Un archivo ausente o sin audio no revienta nada.
        for layer in audioLayers {
            guard FileManager.default.fileExists(atPath: layer.path) else { continue }
            let asset = AVURLAsset(url: URL(fileURLWithPath: layer.path))
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let assetDur = try? await asset.load(.duration).seconds else { continue }
            let start = min(max(0, layer.projectStart), usable)
            let availableInAsset = assetDur - layer.sourceStart
            let availableInProject = usable - start
            var length = min(availableInAsset, availableInProject)
            if layer.duration > 0 { length = min(length, layer.duration) }
            guard length > 0.05 else { continue }
            let aTrack = comp.addMutableTrack(withMediaType: .audio,
                                              preferredTrackID: kCMPersistentTrackID_Invalid)!
            try? aTrack.insertTimeRange(
                CMTimeRange(start: CMTime(seconds: layer.sourceStart, preferredTimescale: 600),
                            duration: CMTime(seconds: length, preferredTimescale: 600)),
                of: track, at: CMTime(seconds: start, preferredTimescale: 600))
            let params = AVMutableAudioMixInputParameters(track: aTrack)
            params.setVolume(Float(layer.volume), at: .zero)
            mixParams.append(params)
        }
        let audioMix: AVMutableAudioMix?
        if mixParams.isEmpty {
            audioMix = nil
        } else {
            let m = AVMutableAudioMix()
            m.inputParameters = mixParams
            audioMix = m
        }

        // Cada capa de VÍDEO del usuario es una pista más. Arranca en su
        // primera aparición y avanza de corrido; su audio no se mezcla (el
        // audio del montaje es el de la cámara). Si el archivo no existe o no
        // tiene vídeo, la capa simplemente no se dibuja: no revienta nada.
        var layerTracks: [UUID: CMPersistentTrackID] = [:]
        for layer in extraLayers where layer.kind == .video {
            let url = URL(fileURLWithPath: layer.path)
            guard FileManager.default.fileExists(atPath: layer.path) else { continue }
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let layerDur = try? await asset.load(.duration).seconds else { continue }
            let start = min(max(0, layer.firstAppearance), usable)
            let available = min(layerDur, usable - start)
            guard available > 0.05 else { continue }
            let vTrack = comp.addMutableTrack(withMediaType: .video,
                                              preferredTrackID: kCMPersistentTrackID_Invalid)!
            try? vTrack.insertTimeRange(
                CMTimeRange(start: .zero,
                            duration: CMTime(seconds: available, preferredTimescale: 600)),
                of: track, at: CMTime(seconds: start, preferredTimescale: 600))
            layerTracks[layer.id] = vTrack.trackID
        }

        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = PiPCompositor.self
        video.renderSize = CGSize(width: 1920, height: 1080)
        video.frameDuration = CMTime(value: 1, timescale: 30)
        video.instructions = [PiPInstruction(
            timeRange: CMTimeRange(start: .zero, duration: duration),
            screenTrack: screenID, cameraTrack: cameraID,
            layerTracks: layerTracks)]
        return (comp, video, usable, audioMix)
    }
}

// MARK: - Exportación

enum CompositionExporter {

    // Passthrough ignora la videoComposition EN SILENCIO: jamás se ofrece.
    // Devuelve la sesión para poder CANCELAR (al cerrar la ventana, p. ej.).
    @discardableResult
    static func export(composition: AVMutableComposition,
                       video: AVMutableVideoComposition,
                       audioMix: AVAudioMix? = nil,
                       to url: URL,
                       progress: @escaping (Double) -> Void,
                       done: @escaping (Result<URL, Error>) -> Void) -> AVAssetExportSession? {
        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            done(.failure(NSError(domain: "CompositionExporter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No se pudo crear la sesión de exportación"])))
            return nil
        }
        session.videoComposition = video
        session.audioMix = audioMix
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
        return session
    }
}
