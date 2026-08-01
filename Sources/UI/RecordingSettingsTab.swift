import AVFoundation
import SwiftUI

// Ajustes de la grabación de presentaciones. Todo apagado por defecto; cada
// pieza se activa por separado y ninguna interfiere con el resto de la app.

struct RecordingSettingsTab: View {
    @ObservedObject private var engine = RecordingEngine.shared

    @State private var enabled = Settings.bool(.recordingEnabled, default: false)
    @State private var camera = Settings.bool(.recordCamera, default: true)
    @State private var screen = Settings.bool(.recordScreen, default: false)
    @State private var mic = Settings.bool(.recordMicInRecording, default: true)
    @State private var chapters = Settings.bool(.recordChapters, default: false)
    @State private var countdown = Settings.int(.recordCountdown, default: 3)
    @State private var cameraDevice = Settings.string(.recordCameraDevice, default: "")
    @State private var cameras: [(id: String, name: String)] = []
    @State private var editor = Settings.bool(.videoEditorEnabled, default: false)

    var body: some View {
        Form {
            Section("Grabación de presentaciones") {
                Toggle("Activar la grabación", isOn: $enabled)
                    .onChange(of: enabled) { v in Settings.set(v, .recordingEnabled) }
                Text("Cámara y pantalla se guardan como archivos SEPARADOS que arrancan "
                     + "a la vez, listos para juntar en cualquier editor. El teleprompter "
                     + "jamás aparece en la grabación de pantalla.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if enabled {
                Section("Qué grabar") {
                    Toggle("Cámara", isOn: $camera)
                        .onChange(of: camera) { v in Settings.set(v, .recordCamera) }
                    if camera && !cameras.isEmpty {
                        Picker("Dispositivo", selection: $cameraDevice) {
                            Text("Cámara por defecto").tag("")
                            ForEach(cameras, id: \.id) { c in
                                Text(c.name).tag(c.id)
                            }
                        }
                        .onChange(of: cameraDevice) { v in Settings.set(v, .recordCameraDevice) }
                    }
                    Toggle("Pantalla (sin el teleprompter)", isOn: $screen)
                        .onChange(of: screen) { v in Settings.set(v, .recordScreen) }
                    Toggle("Micrófono (va en el archivo de cámara)", isOn: $mic)
                        .onChange(of: mic) { v in Settings.set(v, .recordMicInRecording) }
                }

                Section("Comportamiento") {
                    Picker("Cuenta regresiva", selection: $countdown) {
                        Text("Sin conteo").tag(0)
                        Text("3 segundos").tag(3)
                        Text("5 segundos").tag(5)
                        Text("10 segundos").tag(10)
                    }
                    .onChange(of: countdown) { v in Settings.set(v, .recordCountdown) }
                    Toggle("Capítulos automáticos al cruzar cada guía", isOn: $chapters)
                        .onChange(of: chapters) { v in Settings.set(v, .recordChapters) }
                    Text("Queda un capitulos.txt junto a los vídeos con la hora de cada sección.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Archivos") {
                    HStack {
                        Text(RecordingEngine.baseFolder.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Abrir carpeta") {
                            try? FileManager.default.createDirectory(
                                at: RecordingEngine.baseFolder, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(RecordingEngine.baseFolder)
                        }
                        Button("Cambiar…") { chooseFolder() }
                    }
                }

                Section("Editor de composición") {
                    Toggle("Activar el editor (menú «Componer grabación…», ⌘E)", isOn: $editor)
                        .onChange(of: editor) { v in Settings.set(v, .videoEditorEnabled) }
                    Text("Junta cámara y pantalla en un solo vídeo con presets (círculo, "
                         + "lado a lado…) y exporta MP4. El cambio en el menú se aplica al reabrir la app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let s = engine.status {
                    Section {
                        Text(s).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loadCameras() }
    }

    private func loadCameras() {
        // .external y .continuityCamera existen desde macOS 14; en 13 basta
        // la integrada más lo que el sistema dé como cámara por defecto.
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types.append(contentsOf: [.external, .continuityCamera])
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified)
        cameras = discovery.devices.map { ($0.uniqueID, $0.localizedName) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Usar esta carpeta"
        if panel.runModal() == .OK, let url = panel.url {
            Settings.set(url.path, .recordFolder)
        }
    }
}
