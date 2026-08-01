import Foundation

// Estilos de ensayo creados por el usuario: se guardan con nombre, se editan,
// se eliminan y pueden generarse a partir del diagnóstico o del perfil.

struct CustomStyle: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var prompt: String
    var origin: String = "manual"   // manual | perfil | diagnostico | ia
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    // Identificador que usa el selector de estilos del Ensayo IA.
    var styleID: String { "custom:" + id.uuidString }
}

final class CustomStylesStore: ObservableObject {
    static let shared = CustomStylesStore()

    @Published private(set) var styles: [CustomStyle] = []

    private let fileURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BtoPrompter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("styles.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([CustomStyle].self, from: data) else { return }
        styles = list.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(styles) {
            try? data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: fileURL.path)
        }
    }

    func style(withStyleID id: String) -> CustomStyle? {
        guard id.hasPrefix("custom:"),
              let uuid = UUID(uuidString: String(id.dropFirst("custom:".count))) else { return nil }
        return styles.first { $0.id == uuid }
    }

    @discardableResult
    func add(name: String, prompt: String, origin: String = "manual") -> CustomStyle {
        let unique = uniqueName(name)
        let style = CustomStyle(name: unique, prompt: prompt, origin: origin)
        styles.insert(style, at: 0)
        save()
        return style
    }

    func update(_ id: UUID, name: String, prompt: String) {
        guard let i = styles.firstIndex(where: { $0.id == id }) else { return }
        styles[i].name = name
        styles[i].prompt = prompt
        styles[i].updatedAt = Date()
        save()
    }

    func delete(_ id: UUID) {
        styles.removeAll { $0.id == id }
        save()
    }

    private func uniqueName(_ base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "Estilo personalizado" : trimmed
        guard styles.contains(where: { $0.name == candidate }) else { return candidate }
        var n = 2
        while styles.contains(where: { $0.name == "\(candidate) \(n)" }) { n += 1 }
        return "\(candidate) \(n)"
    }
}
