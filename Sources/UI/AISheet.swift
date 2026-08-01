import SwiftUI

// Hoja de configuración y ejecución del Ensayo con IA.

struct AISheet: View {
    @EnvironmentObject var model: PrompterModel
    @Environment(\.dismiss) private var dismiss
    @State private var keyDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Ensayo con IA", systemImage: "sparkles")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Toggle("Activar", isOn: $model.aiEnabled)
                    .toggleStyle(.switch)
            }
            Text("La IA marca el ritmo del discurso — pausas (…), guías de actuación (//) y velocidades por tramo [v+20] — sin cambiar ninguna de tus palabras. El resultado se guarda como un discurso nuevo; el original queda intacto.")
                .font(.system(size: 11))
                .foregroundColor(.gray)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Proveedor", selection: $model.aiProvider) {
                ForEach(AIRehearsal.providers, id: \.id) { p in
                    Text(p.name).tag(p.id)
                }
            }
            .onReceive(model.$aiProvider.dropFirst().removeDuplicates()) { newValue in
                if let p = AIRehearsal.providers.first(where: { $0.id == newValue }), p.id != "custom" {
                    model.aiModel = p.defaultModel
                }
                keyDraft = model.aiKey(for: newValue)
            }
            if model.aiProvider == "custom" {
                TextField("URL base (compatible OpenAI, ej. https://mi-servidor/v1)", text: $model.aiBaseURL)
                    .textFieldStyle(.roundedBorder)
            }
            TextField("Modelo", text: $model.aiModel)
                .textFieldStyle(.roundedBorder)
            SecureField("API key del proveedor", text: $keyDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.setAIKey(keyDraft, for: model.aiProvider) }

            Picker("Estilo", selection: $model.aiStyle) {
                ForEach(AIRehearsal.styles, id: \.id) { s in
                    Text(s.name).tag(s.id)
                }
            }
            if model.aiStyle == "personalizado" {
                TextEditor(text: $model.aiCustomPrompt)
                    .font(.system(size: 12))
                    .frame(height: 60)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.4)))
                    .overlay(alignment: .topLeading) {
                        if model.aiCustomPrompt.isEmpty {
                            Text("Describe cómo quieres que suene: ritmo, tono, dónde enfatizar…")
                                .font(.system(size: 11)).foregroundColor(.gray)
                                .padding(6).allowsHitTesting(false)
                        }
                    }
            }

            if let status = model.aiStatus {
                HStack(spacing: 6) {
                    if model.aiBusy { ProgressView().controlSize(.small) }
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundColor(model.aiBusy ? .orange : (status.hasPrefix("✓") ? .green : .red))
                }
            }

            HStack {
                Button("Cerrar") { dismiss() }
                Spacer()
                Button {
                    model.setAIKey(keyDraft, for: model.aiProvider)
                    model.runAIRehearsal()
                } label: {
                    Label("Preparar discurso", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.aiEnabled || model.aiBusy || keyDraft.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 440)
        .onAppear { keyDraft = model.aiKey(for: model.aiProvider) }
    }
}
