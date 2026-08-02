import Foundation
import CoreGraphics

// Modelo del proyecto de composición: QUÉ se ve en cada tramo de tiempo.
// Funciones puras y serializable a project.json junto a los .mov — el dibujo
// vive en el compositor; aquí no se importa ningún framework de vídeo.
//
// Reglas de diseño (pensadas para crecer):
// - Se guardan solo los PUNTOS de corte, nunca rangos: es imposible crear un
//   hueco o un solape por construcción. layouts.count == cuts.count + 1.
// - Todo va normalizado 0..1 con origen ARRIBA-izquierda (como piensa la
//   gente); el compositor convierte a coordenadas de Core Image en UN lugar.
// - Cada pieza nueva (fondo, recorte, ratio…) es un tipo aparte con su valor
//   por defecto: añadir la siguiente no toca las existentes.

// MARK: - Piezas

// Cómo entra la imagen de una fuente en su ventana.
enum SourceFit: String, Codable, CaseIterable {
    case fill     // cubre la ventana y recorta el sobrante (por defecto)
    case fit      // encaja entera, pueden quedar franjas
    case crop     // usa el rectángulo de recorte elegido por el usuario
    case stretch  // deforma: estira a la ventana sin respetar proporción
}

// Recorte manual de una fuente: qué parte del fotograma original se usa.
// Normalizado 0..1 sobre la imagen fuente, origen arriba-izquierda.
struct SourceCrop: Codable, Equatable {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 1
    var height: Double = 1

    var isFull: Bool { x == 0 && y == 0 && width == 1 && height == 1 }

    // El recorte jamás sale de la imagen ni queda degenerado.
    func clamped() -> SourceCrop {
        var c = SourceCrop()
        c.width = min(1, max(0.05, width))
        c.height = min(1, max(0.05, height))
        c.x = min(1 - c.width, max(0, x))
        c.y = min(1 - c.height, max(0, y))
        return c
    }
}

// Ajustes de una fuente dentro de un tramo (cámara o pantalla por igual).
struct SourceSettings: Codable, Equatable {
    var fit: SourceFit = .fill
    var crop = SourceCrop()
}

// Fondo del lienzo. Un caso nuevo = una función nueva en el compositor.
enum BackgroundStyle: Codable, Equatable {
    case color(RGBA)
    case gradient(top: RGBA, bottom: RGBA)
    case image(path: String, mode: ImageMode)

    enum ImageMode: String, Codable, CaseIterable {
        case fill      // expandido: cubre todo, recorta el sobrante
        case fit       // adaptado: entero, con franjas del color de respaldo
        case stretch   // estirado a la fuerza
        case tile      // mosaico
        case center    // tamaño original, centrado
    }

    static let `default` = BackgroundStyle.color(RGBA(r: 0.07, g: 0.09, b: 0.13))
}

struct RGBA: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1
}

// MARK: - El tramo

// La receta completa de un tramo de tiempo.
struct SegmentLayout: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable {
        case overlay      // cámara flotando sobre la pantalla
        case sideBySide   // las dos fuentes una junto a otra
        case onlyScreen
        case onlyCamera
    }
    enum Shape: String, Codable, CaseIterable {
        case rect, rounded, circle
    }

    init() {}

    init(mode: Mode) {
        self.mode = mode
    }

    // Los project.json anteriores no traen los campos nuevos: valores por
    // defecto en vez de fallar.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .overlay
        transitionIn = try c.decodeIfPresent(TransitionKind.self, forKey: .transitionIn) ?? .cut
        transitionMs = try c.decodeIfPresent(Double.self, forKey: .transitionMs) ?? 400
        layerOrder = try c.decodeIfPresent([UUID].self, forKey: .layerOrder)
        camRect = try c.decodeIfPresent(NRect.self, forKey: .camRect)
            ?? NRect(x: 0.72, y: 0.62, width: 0.25, height: 0.34)
        shape = try c.decodeIfPresent(Shape.self, forKey: .shape) ?? .circle
        borderWidth = try c.decodeIfPresent(Double.self, forKey: .borderWidth) ?? 0.012
        splitRatio = try c.decodeIfPresent(Double.self, forKey: .splitRatio) ?? 0.5
        camera = try c.decodeIfPresent(SourceSettings.self, forKey: .camera) ?? SourceSettings()
        screen = try c.decodeIfPresent(SourceSettings.self, forKey: .screen) ?? SourceSettings()
        zoomRampMs = try c.decodeIfPresent(Double.self, forKey: .zoomRampMs) ?? 0
    }

    enum TransitionKind: String, Codable, CaseIterable {
        case cut    // corte seco (por defecto: la metodología no se toca)
        case fade   // fundido desde el tramo anterior
    }

    var mode: Mode = .overlay
    // Transición de ENTRADA del tramo: cómo se llega a él desde el anterior.
    var transitionIn: TransitionKind = .cut
    var transitionMs: Double = 400
    // Orden de dibujo de las capas EN ESTE TRAMO (ids, la última más arriba).
    // nil = usar el orden global del proyecto. Así en un corte la capa A va
    // encima y en el siguiente va debajo, sin duplicar nada.
    var layerOrder: [UUID]? = nil
    // Ventana de la cámara en modo overlay (normalizada, origen arriba-izq).
    var camRect = NRect(x: 0.72, y: 0.62, width: 0.25, height: 0.34)
    var shape: Shape = .circle
    var borderWidth: Double = 0.012   // fracción del lado menor del lienzo
    // Reparto del lado a lado: fracción del ancho para la CÁMARA (0.2–0.8).
    var splitRatio: Double = 0.5
    var camera = SourceSettings()
    var screen = SourceSettings()
    // Acercamiento suave al entrar al tramo: el recorte crece desde el
    // encuadre completo hasta el elegido en estos milisegundos (0 = salto).
    var zoomRampMs: Double = 0

    func sanitized() -> SegmentLayout {
        var l = self
        l.transitionMs = min(2000, max(100, l.transitionMs))
        l.zoomRampMs = min(3000, max(0, l.zoomRampMs))
        l.splitRatio = min(0.8, max(0.2, l.splitRatio))
        l.camRect = l.camRect.clamped(minSide: 0.06)
        l.borderWidth = min(0.05, max(0, l.borderWidth))
        l.camera.crop = l.camera.crop.clamped()
        l.screen.crop = l.screen.crop.clamped()
        return l
    }
}

extension SourceCrop {
    // Recorte a mitad de camino entre el encuadre completo y el elegido.
    // progreso 0 = todo el fotograma, 1 = el recorte final. Es lo que hace
    // que el zoom se acerque en vez de saltar.
    func ramped(progress: Double) -> SourceCrop {
        let p = min(1, max(0, progress))
        guard p < 1 else { return self }
        let full = SourceCrop()
        var c = SourceCrop()
        c.x = full.x + (x - full.x) * p
        c.y = full.y + (y - full.y) * p
        c.width = full.width + (width - full.width) * p
        c.height = full.height + (height - full.height) * p
        return c
    }
}

// CGRect no es Codable de fábrica; este sí, y con las operaciones que se usan.
struct NRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    func clamped(minSide: Double) -> NRect {
        var r = self
        r.width = min(1, max(minSide, r.width))
        r.height = min(1, max(minSide, r.height))
        r.x = min(1 - r.width, max(0, r.x))
        r.y = min(1 - r.height, max(0, r.y))
        return r
    }
}

// MARK: - Capas extra

// Un intervalo de visibilidad, en segundos del proyecto.
struct LayerAppearance: Codable, Equatable {
    var from: Double
    var to: Double
}

// Anotaciones de curso: lo que se dibuja ENCIMA del vídeo para señalar,
// subrayar, escribir o tapar. Se guardan como una capa más, así heredan
// gratis los intervalos de aparición, el orden por tramo y el lienzo vivo.
struct ShapeContent: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case arrow          // flecha que señala
        case rect           // recuadro
        case ellipse        // círculo/elipse
        case underline      // subrayado
        case text           // texto suelto
        case strikethrough  // tachado
        case blur           // pixelado/borroso: tapa datos sensibles
        case note           // nota adhesiva con texto
        case freehand       // trazo a mano alzada

        var label: String {
            switch self {
            case .arrow: return "Flecha"
            case .rect: return "Recuadro"
            case .ellipse: return "Elipse"
            case .underline: return "Subrayado"
            case .text: return "Texto"
            case .strikethrough: return "Tachado"
            case .blur: return "Pixelar"
            case .note: return "Nota"
            case .freehand: return "Lápiz"
            }
        }

        var symbol: String {
            switch self {
            case .arrow: return "arrow.up.right"
            case .rect: return "rectangle"
            case .ellipse: return "circle"
            case .underline: return "underline"
            case .text: return "textformat"
            case .strikethrough: return "strikethrough"
            case .blur: return "eye.slash"
            case .note: return "note.text"
            case .freehand: return "scribble"
            }
        }
    }

    var kind: Kind = .arrow
    var color = RGBA(r: 1, g: 0.23, b: 0.19)     // rojo señalador
    var thickness: Double = 0.006                 // fracción del lado menor
    var text: String = ""                         // para .text y .note
    // Puntos del trazo a mano alzada, normalizados 0..1 dentro del recuadro
    // de la capa: así el trazo se mueve y escala con ella como todo lo demás.
    var points: [[Double]] = []
    // Pixelar en bloques (true) o desenfocar (false).
    var pixelate = true

    func sanitized() -> ShapeContent {
        var s = self
        s.thickness = min(0.05, max(0.001, s.thickness))
        return s
    }
}

// Una capa añadida por el usuario: un vídeo o una imagen suya, con su
// posición, su forma, su orden y SUS TIEMPOS — aparece y desaparece cuando
// él decida, las veces que decida.
struct ExtraLayer: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case video, image, shape }

    var id = UUID()
    var kind: Kind
    var path: String
    var name: String
    // Solo para kind == .shape: qué se dibuja.
    var shapeContent: ShapeContent? = nil
    var rect = NRect(x: 0.62, y: 0.6, width: 0.32, height: 0.32)
    var settings = SourceSettings()
    var shape: SegmentLayout.Shape = .rect
    var borderWidth: Double = 0
    var opacity: Double = 1
    // En modo cámara-sobre-pantalla: ¿la capa va entre la pantalla y la
    // cámara flotante, o encima de todo? En los demás modos, detrás = fondo.
    var behindCamera = false
    // Vacío = visible durante todo el vídeo.
    var appearances: [LayerAppearance] = []

    func isVisible(at seconds: Double) -> Bool {
        appearances.isEmpty
            || appearances.contains { seconds >= $0.from && seconds < $0.to }
    }

    // Primer instante en que la capa existe (los vídeos arrancan aquí).
    var firstAppearance: Double {
        appearances.map(\.from).min() ?? 0
    }

    func sanitized(duration: Double) -> ExtraLayer {
        var l = self
        l.shapeContent = l.shapeContent?.sanitized()
        l.rect = l.rect.clamped(minSide: 0.01)
        l.opacity = min(1, max(0.05, l.opacity))
        l.borderWidth = min(0.05, max(0, l.borderWidth))
        l.settings.crop = l.settings.crop.clamped()
        // Un intervalo más allá de la duración actual NO se destruye: si la
        // fuente cambia y el vídeo vuelve a ser largo, el intervalo sigue ahí
        // (y mientras tanto es inofensivo: isVisible nunca lo alcanza).
        l.appearances = l.appearances
            .map { a -> LayerAppearance in
                var a2 = LayerAppearance(from: max(0, a.from), to: a.to)
                if duration > 0 && a2.from < duration { a2.to = min(duration, a2.to) }
                return a2
            }
            .filter { $0.to > $0.from }
            .sorted { $0.from < $1.from }
        return l
    }
}

// Resaltar el puntero en la grabación de pantalla: un halo suave que lo
// sigue, que es lo que separa un tutorial que se entiende de uno donde nadie
// encuentra el ratón. El recorrido lo graba el propio grabador.
struct CursorHighlight: Codable, Equatable {
    var enabled = false
    var color = RGBA(r: 1, g: 0.85, b: 0.1, a: 0.45)
    // Radio como fracción del lado menor del lienzo.
    var radius: Double = 0.035
    // Anillo alrededor del halo (0 = solo el relleno).
    var ringWidth: Double = 0.004
    var points: [[Double]] = []      // [t, x, y] normalizados, del grabador

    func position(at seconds: Double) -> (x: Double, y: Double)? {
        guard points.count > 1 else {
            if let p = points.first, p.count == 3 { return (p[1], p[2]) }
            return nil
        }
        // Interpolación entre las dos muestras que rodean al instante: el
        // halo se desliza en vez de dar saltos de veinte en veinte por segundo.
        var previous = points[0]
        for p in points where p.count == 3 {
            if p[0] >= seconds {
                let t0 = previous[0], t1 = p[0]
                guard t1 > t0 else { return (p[1], p[2]) }
                let f = min(1, max(0, (seconds - t0) / (t1 - t0)))
                return (previous[1] + (p[1] - previous[1]) * f,
                        previous[2] + (p[2] - previous[2]) * f)
            }
            previous = p
        }
        return (previous[1], previous[2])
    }

    func sanitized() -> CursorHighlight {
        var c = self
        c.radius = min(0.2, max(0.005, c.radius))
        c.ringWidth = min(0.05, max(0, c.ringWidth))
        return c
    }

    // Lee el cursor.jsonl que deja el grabador.
    static func fromRecording(folder: URL) -> [[Double]] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("cursor.jsonl"),
                                     encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let t = o["t"] as? Double, let x = o["x"] as? Double,
                  let y = o["y"] as? Double else { return nil }
            return [t, x, y]
        }
    }
}

// MARK: - Capas de audio

// Un audio del usuario en el montaje: música de fondo bajita, un efecto…
// Con su volumen, el RECORTE del archivo (usar del minuto 1 al 3 de un MP3)
// y DÓNDE suena en el proyecto.
struct AudioLayer: Codable, Equatable, Identifiable {
    var id = UUID()
    var path: String
    var name: String
    var volume: Double = 0.5
    // Segundo del ARCHIVO donde empieza a leerse (recortar la intro).
    var sourceStart: Double = 0
    // Segundo del PROYECTO donde empieza a sonar.
    var projectStart: Double = 0
    // Cuánto suena (segundos); 0 = hasta que se acabe el archivo o el vídeo.
    var duration: Double = 0

    func sanitized(projectDuration: Double) -> AudioLayer {
        var a = self
        a.volume = min(1, max(0, a.volume))
        a.sourceStart = max(0, a.sourceStart)
        a.projectStart = max(0, a.projectStart)
        a.duration = max(0, a.duration)
        return a
    }
}

// MARK: - El proyecto

struct VideoProject: Codable, Equatable {
    var cuts: [Double] = []                        // segundos, ordenados, únicos
    var layouts: [SegmentLayout] = [SegmentLayout()]
    var background: BackgroundStyle = .default
    var duration: Double = 0                       // de la composición ya recortada
    // Capas del usuario, dibujadas en el orden del array (última = más arriba).
    var extraLayers: [ExtraLayer] = []
    // Audios del usuario (música, efectos) y volumen del micrófono.
    var audioLayers: [AudioLayer] = []
    // Subtítulos quemados (nil = sin subtítulos configurados).
    var subtitles: SubtitleTrack? = nil
    var cursor: CursorHighlight? = nil
    var micVolume: Double = 1.0
    // Volumen del sonido del sistema (la pista de audio de pantalla-*.mov,
    // si la grabación lo capturó). Independiente del micrófono: se puede ver
    // el escritorio con el sonido de la webcam, o al revés.
    var screenAudioVolume: Double = 1.0
    // Fuentes propias: sustituyen a la cámara o pantalla grabadas (o las
    // aportan si la grabación no las tiene). Rutas absolutas elegidas por él.
    var cameraOverridePath: String? = nil
    var screenOverridePath: String? = nil

    // Los project.json de la versión anterior no traen los campos nuevos:
    // se decodifican con sus valores por defecto en vez de fallar.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cuts = try c.decodeIfPresent([Double].self, forKey: .cuts) ?? []
        layouts = try c.decodeIfPresent([SegmentLayout].self, forKey: .layouts) ?? [SegmentLayout()]
        background = try c.decodeIfPresent(BackgroundStyle.self, forKey: .background) ?? .default
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        extraLayers = try c.decodeIfPresent([ExtraLayer].self, forKey: .extraLayers) ?? []
        audioLayers = try c.decodeIfPresent([AudioLayer].self, forKey: .audioLayers) ?? []
        subtitles = try c.decodeIfPresent(SubtitleTrack.self, forKey: .subtitles)
        cursor = try c.decodeIfPresent(CursorHighlight.self, forKey: .cursor)
        micVolume = try c.decodeIfPresent(Double.self, forKey: .micVolume) ?? 1.0
        screenAudioVolume = try c.decodeIfPresent(Double.self, forKey: .screenAudioVolume) ?? 1.0
        cameraOverridePath = try c.decodeIfPresent(String.self, forKey: .cameraOverridePath)
        screenOverridePath = try c.decodeIfPresent(String.self, forKey: .screenOverridePath)
    }

    // Invariante: layouts.count == cuts.count + 1. Todo lo que muta pasa por
    // estas operaciones; no hay forma de crear huecos ni desajustes.

    // Tramo vigente en un instante dado.
    func segmentIndex(at seconds: Double) -> Int {
        var idx = 0
        for cut in cuts where seconds >= cut { idx += 1 }
        return min(idx, layouts.count - 1)
    }

    func layout(at seconds: Double) -> SegmentLayout {
        layouts[segmentIndex(at: seconds)]
    }

    // Capas en el orden de dibujo del instante dado: el orden del tramo si lo
    // tiene, el global si no. Capas ausentes de la lista van al final en su
    // orden global (capas añadidas después de fijar el orden del tramo).
    func orderedLayers(at seconds: Double) -> [ExtraLayer] {
        orderedLayers(forSegment: segmentIndex(at: seconds))
    }

    func orderedLayers(forSegment seg: Int) -> [ExtraLayer] {
        guard layouts.indices.contains(seg), let order = layouts[seg].layerOrder else {
            return extraLayers
        }
        var byID = [UUID: ExtraLayer]()
        for l in extraLayers { byID[l.id] = l }
        var result: [ExtraLayer] = []
        for id in order {
            if let l = byID.removeValue(forKey: id) { result.append(l) }
        }
        result.append(contentsOf: extraLayers.filter { byID[$0.id] != nil })
        return result
    }

    // Mueve una capa a la posición dada (0 = fondo) SOLO en el tramo indicado.
    // La primera vez congela el orden global como orden del tramo.
    mutating func setLayerPosition(_ id: UUID, to position: Int, inSegment seg: Int) {
        guard layouts.indices.contains(seg) else { return }
        var order = layouts[seg].layerOrder ?? extraLayers.map(\.id)
        guard let from = order.firstIndex(of: id) else { return }
        order.remove(at: from)
        order.insert(id, at: min(max(0, position), order.count))
        layouts[seg].layerOrder = order
    }

    // Mueve una capa en el orden GLOBAL (todo el vídeo) y limpia el orden
    // particular de los tramos que la contengan igual que el global.
    mutating func setLayerPositionGlobal(_ id: UUID, to position: Int) {
        guard let from = extraLayers.firstIndex(where: { $0.id == id }) else { return }
        let layer = extraLayers.remove(at: from)
        extraLayers.insert(layer, at: min(max(0, position), extraLayers.count))
    }

    // Rango [inicio, fin) del tramo i.
    func segmentRange(_ i: Int) -> (start: Double, end: Double) {
        let start = i == 0 ? 0 : cuts[i - 1]
        let end = i < cuts.count ? cuts[i] : duration
        return (start, end)
    }

    // Corta en el instante dado: el tramo se parte en dos con la misma receta.
    // Devuelve el índice del tramo nuevo, o nil si el corte no vale.
    mutating func addCut(at seconds: Double, minGap: Double = 0.2) -> Int? {
        guard seconds > minGap, seconds < duration - minGap else { return nil }
        guard !cuts.contains(where: { abs($0 - seconds) < minGap }) else { return nil }
        let segment = segmentIndex(at: seconds)
        let insertAt = cuts.firstIndex(where: { $0 > seconds }) ?? cuts.count
        cuts.insert(seconds, at: insertAt)
        layouts.insert(layouts[segment], at: segment + 1)
        return segment + 1
    }

    // Borrar un tramo = fusionarlo con el anterior (o el siguiente si es el
    // primero). Nunca queda hueco, por construcción.
    mutating func removeSegment(_ i: Int) {
        guard layouts.count > 1, i >= 0, i < layouts.count else { return }
        if i == 0 {
            cuts.removeFirst()
            layouts.removeFirst()
        } else {
            cuts.remove(at: i - 1)
            layouts.remove(at: i)
        }
    }

    // Mover un corte sin invadir a los vecinos.
    mutating func moveCut(_ i: Int, to seconds: Double, minGap: Double = 0.2) {
        guard i >= 0, i < cuts.count else { return }
        let lower = (i == 0 ? 0 : cuts[i - 1]) + minGap
        let upper = (i == cuts.count - 1 ? duration : cuts[i + 1]) - minGap
        guard lower < upper else { return }
        cuts[i] = min(upper, max(lower, seconds))
    }

    // Un tramo por capítulo del guion (capitulos.txt del grabador).
    mutating func applyChapterCuts(_ chapterSeconds: [Double]) {
        for s in chapterSeconds.sorted() {
            _ = addCut(at: s)
        }
    }

    func sanitized() -> VideoProject {
        var p = self
        // duration <= 0 significa "aún no se conoce": los cortes se conservan.
        // Filtrarlos aquí destruía el proyecto guardado al reabrir el editor,
        // que carga primero y conoce la duración después.
        p.cuts = Array(Set(p.cuts)).sorted()
            .filter { $0 > 0 && (p.duration <= 0 || $0 < p.duration) }
        // Reparar el invariante si el JSON venía mal de fuera.
        while p.layouts.count < p.cuts.count + 1 { p.layouts.append(p.layouts.last ?? SegmentLayout()) }
        while p.layouts.count > p.cuts.count + 1 { p.layouts.removeLast() }
        p.layouts = p.layouts.map { $0.sanitized() }
        p.extraLayers = p.extraLayers.map { $0.sanitized(duration: p.duration) }
        p.audioLayers = p.audioLayers.map { $0.sanitized(projectDuration: p.duration) }
        p.subtitles = p.subtitles?.sanitized()
        p.cursor = p.cursor?.sanitized()
        p.micVolume = min(1, max(0, p.micVolume))
        p.screenAudioVolume = min(1, max(0, p.screenAudioVolume))
        // Órdenes por tramo: fuera los ids de capas que ya no existen.
        let alive = Set(p.extraLayers.map(\.id))
        for i in p.layouts.indices {
            if let order = p.layouts[i].layerOrder {
                let cleaned = order.filter { alive.contains($0) }
                p.layouts[i].layerOrder = cleaned.isEmpty ? nil : cleaned
            }
        }
        return p
    }
}

// MARK: - Persistencia

enum VideoProjectStore {

    static func projectURL(inFolder folder: URL) -> URL {
        folder.appendingPathComponent("project.json")
    }

    static func load(folder: URL, duration: Double) -> VideoProject {
        guard let data = try? Data(contentsOf: projectURL(inFolder: folder)),
              var p = try? JSONDecoder().decode(VideoProject.self, from: data) else {
            var fresh = VideoProject()
            fresh.duration = duration
            return fresh
        }
        p.duration = duration
        return p.sanitized()
    }

    static func save(_ project: VideoProject, folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(project.sanitized()) else { return }
        try? data.write(to: projectURL(inFolder: folder), options: .atomic)
    }

    // Lee capitulos.txt ("HH:MM:SS  título") → segundos de cada capítulo.
    static func chapterSeconds(inFolder folder: URL) -> [Double] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("capitulos.txt"),
                                     encoding: .utf8) else { return [] }
        var result: [Double] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard let stamp = parts.first, stamp.contains(":") else { continue }
            let comps = stamp.split(separator: ":").compactMap { Double($0) }
            guard comps.count == 3 else { continue }
            result.append(comps[0] * 3600 + comps[1] * 60 + comps[2])
        }
        return result
    }
}

// MARK: - Presets (una receta con nombre)

extension SegmentLayout {
    static let presets: [(name: String, layout: SegmentLayout)] = [
        ("Solo pantalla", SegmentLayout(mode: .onlyScreen)),
        ("Cara en círculo", SegmentLayout()),
        ("Lado a lado", {
            var l = SegmentLayout()
            l.mode = .sideBySide
            l.shape = .rounded
            return l
        }()),
        ("Solo cámara", SegmentLayout(mode: .onlyCamera)),
        ("Cara grande", {
            var l = SegmentLayout()
            l.mode = .sideBySide
            l.shape = .rounded
            l.splitRatio = 0.65
            return l
        }()),
        ("Esquina sup. izq.", {
            var l = SegmentLayout()
            l.camRect = NRect(x: 0.03, y: 0.05, width: 0.25, height: 0.34)
            l.shape = .rounded
            return l
        }()),
    ]
}
