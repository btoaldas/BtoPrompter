import AppKit
import SwiftUI

// Informe de cómo se leyó realmente cada sesión: ritmo, pausas, tramos
// rápidos y lentos, y avance por voz frente a avance por tiempo.
struct SessionAnalysisView: View {
    @State private var sessions: [URL] = []
    @State private var selected: URL?
    @State private var report: SessionReport?
    @State private var message: String?

    var body: some View {
        Section("Análisis de mis ensayos") {
            if sessions.isEmpty {
                Text("Todavía no hay sesiones con alineación palabra a palabra. Activa el diagnóstico detallado y haz un ensayo.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                Picker("Sesión", selection: $selected) {
                    ForEach(sessions, id: \.self) { url in
                        Text(label(for: url)).tag(Optional(url))
                    }
                }
                .onChange(of: selected) { analyze($0) }

                if let report {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(report.summaryText)
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if !report.transcriptSample.isEmpty {
                            Text("Últimas palabras reconocidas: «\(report.transcriptSample.suffix(160))»")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 8) {
                            Button("Copiar informe") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(report.summaryText, forType: .string)
                            }
                            Button("Abrir carpeta de la sesión") {
                                if let selected { NSWorkspace.shared.activateFileViewerSelecting([selected]) }
                            }
                        }
                        .font(.system(size: 11))
                    }
                } else if let message {
                    Text(message).font(.system(size: 11)).foregroundColor(.orange)
                }
            }
            Button("Actualizar lista") { reload() }
                .font(.system(size: 11))
        }
        .onAppear { reload() }
    }

    private func label(for url: URL) -> String {
        let id = url.lastPathComponent
        let manifest = (try? Data(contentsOf: url.appendingPathComponent("manifest.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let title = (manifest?["title"] as? String) ?? ""
        return title.isEmpty ? id : "\(title) · \(id.prefix(13))"
    }

    private func reload() {
        sessions = SessionAnalyzer.availableSessions()
        if selected == nil || !sessions.contains(selected!) {
            selected = sessions.first
        }
        analyze(selected)
    }

    private func analyze(_ url: URL?) {
        guard let url else { report = nil; return }
        report = SessionAnalyzer.analyze(session: url)
        message = report == nil
            ? "Esta sesión no tiene datos de alineación suficientes."
            : nil
    }
}
