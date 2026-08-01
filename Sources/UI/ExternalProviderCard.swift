import AppKit
import SwiftUI

// Tarjeta de configuración por proveedor externo de voz: API key, modelo y
// prueba de conexión. Cada proveedor se configura por separado, como pide el
// flujo de trabajo del usuario (elegir proveedor → poner clave → elegir modelo).
struct ExternalProviderCard: View {
    let provider: VoiceProviderID

    @State private var key: String = ""
    @State private var model: String = ""
    @State private var expanded = false
    @State private var testing = false
    @State private var testResult: String? = nil

    private var secretName: String { provider.secretName ?? "" }
    private var hasKey: Bool { !key.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                SecureField("API key de \(provider.name)", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: key) { newValue in
                        SecretsStore.set(newValue.trimmingCharacters(in: .whitespaces), for: secretName)
                    }

                if provider.availableModels.isEmpty {
                    TextField("Modelo", text: $model)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: model) { saveModel($0) }
                } else {
                    Picker("Modelo", selection: $model) {
                        ForEach(provider.availableModels, id: \.self) { m in
                            Text(m).tag(m)
                        }
                    }
                    .onChange(of: model) { saveModel($0) }
                }

                HStack(spacing: 8) {
                    Button {
                        test()
                    } label: {
                        if testing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Probar clave", systemImage: "checkmark.seal")
                        }
                    }
                    .disabled(!hasKey || testing)

                    if let url = provider.docsURL {
                        Link("Obtener clave", destination: url)
                            .font(.system(size: 11))
                    }
                    Spacer()
                    if hasKey {
                        Button("Borrar clave") {
                            key = ""
                            SecretsStore.set("", for: secretName)
                            testResult = nil
                        }
                        .font(.system(size: 11))
                    }
                }

                if let testResult {
                    Text(testResult)
                        .font(.system(size: 10))
                        .foregroundColor(testResult.hasPrefix("✓") ? .green : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(provider.privacyNote)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: hasKey ? "key.fill" : "key")
                    .foregroundColor(hasKey ? .green : .secondary)
                    .font(.system(size: 11))
                Text(provider.name)
                Spacer()
                Text(hasKey ? model : "sin clave")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            key = SecretsStore.get(secretName)
            model = provider.configuredModel
        }
    }

    private func saveModel(_ value: String) {
        UserDefaults.standard.set(value, forKey: provider.modelSettingKey)
    }

    // Comprobación ligera: pide un token/sesión al proveedor sin enviar audio.
    private func test() {
        testing = true
        testResult = nil
        CloudSpeechProvider.validateCredentials(provider: provider, apiKey: key) { result in
            DispatchQueue.main.async {
                testing = false
                switch result {
                case .success(let detail):
                    testResult = "✓ Clave válida" + (detail.isEmpty ? "" : " · \(detail)")
                case .failure(let error):
                    testResult = "✗ \(error.localizedDescription)"
                }
            }
        }
    }
}
