import AppKit
import Foundation

// Comprobación de actualizaciones contra los releases de GitHub.
// Solo consulta cuando el usuario lo pide; no llama a la red por su cuenta.
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published var status: String? = nil
    @Published var latestURL: URL? = nil
    @Published var checking = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    func check() {
        guard !checking else { return }
        checking = true
        status = "Comprobando…"
        latestURL = nil
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/btoaldas/BtoPrompter/releases/latest")!)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, error in
            DispatchQueue.main.async {
                self.checking = false
                guard error == nil, let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    self.status = "No se pudo comprobar (¿sin internet?)"
                    return
                }
                let current = "v" + self.currentVersion
                if tag == current {
                    self.status = "Estás al día ✓"
                } else {
                    self.status = "Nueva versión \(tag) disponible"
                    if let urlString = json["html_url"] as? String {
                        self.latestURL = URL(string: urlString)
                    }
                }
            }
        }.resume()
    }

    func openDownload() {
        if let url = latestURL { NSWorkspace.shared.open(url) }
    }
}
