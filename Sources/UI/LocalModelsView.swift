import SwiftUI

// Gestión de modelos locales de reconocimiento: descargar, cancelar,
// continuar donde quedó y eliminar. Todo el proceso ocurre en el Mac.
struct LocalModelsView: View {
    @ObservedObject private var store = LocalModelStore.shared

    var body: some View {
        Section("Modelos locales de reconocimiento (Whisper)") {
            Text("Se descargan una vez y quedan en tu Mac. Puedes cancelar y continuar más tarde: la descarga sigue donde quedó.")
                .font(.system(size: 10)).foregroundColor(.secondary)
            ForEach(LocalModelStore.catalog) { model in
                row(model)
            }
        }
    }

    @ViewBuilder
    private func row(_ model: LocalSTTModel) -> some View {
        let state = store.states[model.id]
        let installed = store.isInstalled(model)
        let partial = store.partialBytes(model)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: installed ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundColor(installed ? .green : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.name).font(.system(size: 12, weight: .medium))
                    Text(model.detail).font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer()
                Text(installed
                     ? byteText(store.installedSize(model))
                     : "~\(model.approxMB) MB")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            if let state, state.running {
                HStack(spacing: 8) {
                    ProgressView(value: state.progress)
                    Text("\(Int(state.progress * 100)) %")
                        .font(.system(size: 10, design: .monospaced))
                    Button("Cancelar") { store.cancel(model) }
                        .font(.system(size: 11))
                }
            } else {
                HStack(spacing: 8) {
                    if installed {
                        Button("Eliminar", role: .destructive) { store.remove(model) }
                            .font(.system(size: 11))
                    } else if partial > 0 {
                        Button("Continuar (\(byteText(partial)) descargados)") { store.start(model) }
                            .font(.system(size: 11))
                        Button("Descartar") { store.remove(model) }
                            .font(.system(size: 11))
                    } else {
                        Button("Descargar") { store.start(model) }
                            .font(.system(size: 11))
                    }
                    if let error = state?.error {
                        Text(error).font(.system(size: 10)).foregroundColor(.red)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func byteText(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}
