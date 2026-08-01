import SwiftUI

// Formulario de configuración del Ensayo con IA — reutilizado por la hoja
// rápida (botón "Ensayo IA" del editor) y por Configuración → pestaña IA.
// La API key se guarda en SecretsStore en cada cambio.

struct AIConfigForm: View {
    @EnvironmentObject var model: PrompterModel
    @State private var keyDraft: String = ""

    private var keyBinding: Binding<String> {
        Binding(
            get: { keyDraft },
            set: { v in
                keyDraft = v
                model.setAIKey(v, for: model.aiProvider)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Activar Ensayo con IA", isOn: $model.aiEnabled)
                .toggleStyle(.switch)
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
            SecureField("API key del proveedor (se guarda solo en tu Mac)", text: keyBinding)
                .textFieldStyle(.roundedBorder)

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
        }
        .onAppear { keyDraft = model.aiKey(for: model.aiProvider) }
    }

    var hasKey: Bool { !keyDraft.isEmpty }
}

// Hoja rápida desde el editor: formulario + botón de ejecutar.
struct AISheet: View {
    @EnvironmentObject var model: PrompterModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Ensayo con IA", systemImage: "sparkles")
                .font(.system(size: 15, weight: .bold))
            AIConfigForm()
            HStack {
                Button("Cerrar") { dismiss() }
                Spacer()
                Button {
                    model.runAIRehearsal()
                } label: {
                    Label("Preparar discurso", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.aiEnabled || model.aiBusy || model.aiKey(for: model.aiProvider).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}
