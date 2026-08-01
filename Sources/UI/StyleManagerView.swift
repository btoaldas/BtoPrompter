import AppKit
import SwiftUI

// Gestión de estilos de ensayo: crear con nombre, editar, eliminar y generar
// uno a partir de lo medido en el diagnóstico (con o sin ayuda de la IA).
struct StyleManagerView: View {
    @EnvironmentObject var model: PrompterModel
    @ObservedObject private var store = CustomStylesStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selected: UUID?
    @State private var name = ""
    @State private var prompt = ""
    @State private var status: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mis estilos de ensayo")
                .font(.system(size: 15, weight: .bold))
            HStack(alignment: .top, spacing: 12) {
                list
                editor
            }
            HStack {
                Button("Cerrar") { dismiss() }
                Spacer()
                if let status {
                    Text(status)
                        .font(.system(size: 10))
                        .foregroundColor(status.hasPrefix("✓") ? .green : .red)
                        .lineLimit(2)
                }
            }
        }
        .padding(16)
        .frame(width: 640, height: 460)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            List(selection: $selected) {
                ForEach(store.styles) { style in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(style.name).font(.system(size: 12, weight: .medium))
                        Text(originLabel(style.origin))
                            .font(.system(size: 9)).foregroundColor(.secondary)
                    }
                    .tag(style.id)
                }
            }
            .frame(width: 200)
            .onChange(of: selected) { load($0) }

            Button {
                let s = store.add(name: "Estilo personalizado",
                                  prompt: "Describe aquí cómo quieres que suene tu discurso.")
                selected = s.id
                load(s.id)
            } label: { Label("Nuevo", systemImage: "plus") }
                .font(.system(size: 11))

            if let selected {
                Button("Eliminar", role: .destructive) {
                    store.delete(selected)
                    self.selected = nil
                    name = ""; prompt = ""
                }
                .font(.system(size: 11))
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Nombre del estilo", text: $name)
                .textFieldStyle(.roundedBorder)
                .disabled(selected == nil)
            TextEditor(text: $prompt)
                .font(.system(size: 12))
                .frame(minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.4)))
                .disabled(selected == nil)
            HStack(spacing: 8) {
                Button("Guardar") {
                    if let selected {
                        store.update(selected, name: name, prompt: prompt)
                        status = "✓ Estilo guardado"
                    }
                }
                .disabled(selected == nil)
                Spacer()
                Menu("Crear desde mi diagnóstico") {
                    Button("Con mis datos medidos (local)") { createFromDiagnostics(useAI: false) }
                    Button("Redactado por la IA a partir de mis datos") { createFromDiagnostics(useAI: true) }
                }
                .frame(width: 230)
                .disabled(busy)
            }
            if busy { ProgressView().controlSize(.small) }
            Text("Los estilos aparecen en la lista de Ensayo IA junto a los predefinidos. Puedes actualizarlos cuando tu diagnóstico mejore.")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private func originLabel(_ origin: String) -> String {
        switch origin {
        case "diagnostico": return "desde mi diagnóstico"
        case "ia": return "redactado por la IA"
        case "perfil": return "desde mi perfil"
        default: return "escrito a mano"
        }
    }

    private func load(_ id: UUID?) {
        guard let id, let style = store.styles.first(where: { $0.id == id }) else {
            name = ""; prompt = ""
            return
        }
        name = style.name
        prompt = style.prompt
    }

    // Construye un estilo con lo que se midió realmente en los ensayos.
    private func createFromDiagnostics(useAI: Bool) {
        let combined = SessionAnalyzer.combinedReport(limit: 5)
        guard !combined.reports.isEmpty else {
            status = "Todavía no hay sesiones analizables. Activa el diagnóstico y ensaya."
            return
        }
        var evidence = combined.text
        let profile = SpeakingProfileStore.shared
        if !profile.stylePrompt.isEmpty {
            evidence += "\n\n" + profile.stylePrompt
        }
        guard useAI else {
            let s = store.add(name: "Mi ritmo real",
                              prompt: "Instrucción basada en mis ensayos medidos:\n\n" + evidence,
                              origin: "diagnostico")
            selected = s.id
            load(s.id)
            status = "✓ Estilo creado con tus datos medidos"
            return
        }
        let key = model.aiKey(for: model.aiProvider)
        guard model.aiEnabled, !key.isEmpty, !model.aiEffectiveBaseURL.isEmpty else {
            status = "Activa el Ensayo IA y pon la API key para que la IA lo redacte."
            return
        }
        busy = true
        status = "Analizando tus ensayos con la IA…"
        AIRehearsal.buildSpeakerStyle(evidence: evidence, baseURL: model.aiEffectiveBaseURL,
                                      apiKey: key, model: model.aiModel) { result in
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .success(let text):
                    let s = store.add(name: "Mi estilo según la IA", prompt: text, origin: "ia")
                    selected = s.id
                    load(s.id)
                    status = "✓ Estilo creado a partir de tus ensayos"
                case .failure(let error):
                    status = "✗ \(error.localizedDescription)"
                }
            }
        }
    }
}
