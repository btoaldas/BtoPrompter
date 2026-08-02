import Foundation

// Presets del editor de composición, estilo OBS, en CUATRO niveles:
// características (solo apariencia), componente (capa completa), escena
// (tramo con sus capas) y plantilla de proyecto entero. Los archivos que la
// plantilla usaba y no existen en el destino quedan como "demo N": al
// aplicar, el usuario decide qué poner en cada hueco.
// Guardado en Application Support/video-presets.json (patrón CustomStyles).

struct StylePreset: Codable, Equatable {
    var name: String
    var shape: SegmentLayout.Shape
    var borderWidth: Double
    var opacity: Double
    var fit: SourceFit
}

struct ComponentPreset: Codable, Equatable {
    var name: String
    var layer: ExtraLayer   // path = "demo" (placeholder), kind conservado
}

struct ScenePreset: Codable, Equatable {
    var name: String
    var layout: SegmentLayout
    var layers: [ExtraLayer]   // paths = "demo N"
}

struct ProjectTemplate: Codable, Equatable {
    var name: String
    var cuts: [Double]
    var layouts: [SegmentLayout]
    var layers: [ExtraLayer]   // paths = "demo N"
    var background: BackgroundStyle
    var subtitleStyle: SubtitleStyle?
}

struct VideoPresetLibrary: Codable, Equatable {
    var styles: [StylePreset] = []
    var components: [ComponentPreset] = []
    var scenes: [ScenePreset] = []
    var templates: [ProjectTemplate] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        styles = try c.decodeIfPresent([StylePreset].self, forKey: .styles) ?? []
        components = try c.decodeIfPresent([ComponentPreset].self, forKey: .components) ?? []
        scenes = try c.decodeIfPresent([ScenePreset].self, forKey: .scenes) ?? []
        templates = try c.decodeIfPresent([ProjectTemplate].self, forKey: .templates) ?? []
    }
}

enum VideoPresetStore {

    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("BtoPrompter", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("video-presets.json")
    }

    static func load() -> VideoPresetLibrary {
        guard let data = try? Data(contentsOf: url),
              let lib = try? JSONDecoder().decode(VideoPresetLibrary.self, from: data) else {
            return VideoPresetLibrary()
        }
        return lib
    }

    static func save(_ lib: VideoPresetLibrary) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(lib) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // Sustituye las rutas reales por placeholders "demo N": una plantilla no
    // debe arrastrar rutas de archivos de OTRO proyecto (ni datos personales).
    static func placeholdered(_ layers: [ExtraLayer]) -> [ExtraLayer] {
        var n = 0
        return layers.map { layer in
            n += 1
            var l = layer
            l.path = "demo \(n)"
            l.name = "demo \(n) (\(layer.kind == .video ? "vídeo" : "imagen"))"
            return l
        }
    }

    static func isPlaceholder(_ layer: ExtraLayer) -> Bool {
        layer.path.hasPrefix("demo ") || layer.path == "demo"
    }
}
