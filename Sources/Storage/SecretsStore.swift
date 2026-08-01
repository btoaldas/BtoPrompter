import Foundation

// Secretos (API keys) fuera de UserDefaults: archivo JSON con permisos 0600
// en Application Support, mismo patrón que usan otras apps locales del autor.
// Nota de diseño: no se usa el Llavero porque la app se firma ad-hoc en cada
// build de desarrollo y el Llavero pediría autorización en cada recompilación.
enum SecretsStore {
    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BtoPrompter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("secrets.json")
    }()

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private static func save(_ dict: [String: String]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: fileURL.path)
    }

    static func get(_ name: String) -> String {
        migrateFromDefaultsIfNeeded()
        return load()[name] ?? ""
    }

    static func set(_ value: String, for name: String) {
        var dict = load()
        if value.isEmpty { dict.removeValue(forKey: name) } else { dict[name] = value }
        save(dict)
    }

    // Migración única: versiones anteriores guardaban aiKey_<proveedor> en UserDefaults.
    private static var migrated = false
    private static func migrateFromDefaultsIfNeeded() {
        guard !migrated else { return }
        migrated = true
        let d = UserDefaults.standard
        var dict = load()
        var changed = false
        for (key, value) in d.dictionaryRepresentation() where key.hasPrefix("aiKey_") {
            if let s = value as? String, !s.isEmpty, dict[key] == nil {
                dict[key] = s
                changed = true
            }
            d.removeObject(forKey: key)
        }
        if changed { save(dict) }
    }
}
