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
    @State private var sysAudio = Settings.bool(.recordSystemAudio, default: false)
    @State private var audioCopies = Settings.bool(.recordAudioCopies, default: false)
    @State private var chapters = Settings.bool(.recordChapters, default: false)
    @State private var keystrokes = Settings.bool(.recordKeystrokes, default: false)
    @State private var autoPlay = Settings.bool(.recordAutoPlayPrompter, default: true)
    @State private var keepAwake = Settings.bool(.recordKeepAwake, default: true)
    @State private var autoRestart = Settings.bool(.recordAutoRestart, default: true)
    @State private var failureSound = Settings.bool(.recordFailureSound, default: true)
    @State private var countdown = Settings.int(.recordCountdown, default: 3)
    @State private var cameraDevice = Settings.string(.recordCameraDevice, default: "")
    @State private var cameras: [(id: String, name: String)] = []
    @State private var editor = Settings.bool(.videoEditorEnabled, default: false)
    @State private var mountParts = Settings.bool(.editorMountParts, default: true)

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
                    Toggle("Sonido del sistema (va en el archivo de pantalla)", isOn: $sysAudio)
                        .onChange(of: sysAudio) { v in Settings.set(v, .recordSystemAudio) }
                    Text("Con el sonido del sistema grabado, el editor puede mezclar la vista "
                         + "del escritorio con el audio que quieras: micrófono, sistema o ambos.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Si grabas el sonido del sistema Y hablas por el micrófono a la "
                         + "vez, el micrófono captará también lo que suena por los altavoces. "
                         + "Está medido: macOS no puede borrarlo del micrófono. Para separar "
                         + "de verdad tu voz del sonido del Mac, usa auriculares.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Toggle("Guardar además copias solo-audio (.m4a)", isOn: $audioCopies)
                        .onChange(of: audioCopies) { v in Settings.set(v, .recordAudioCopies) }
                    Text("El audio siempre va dentro de los vídeos; esto extrae ADEMÁS "
                         + "audio-webcam y audio-sistema como archivos sueltos, para no perder nada.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Comportamiento") {
                    Picker("Cuenta regresiva", selection: $countdown) {
                        Text("Sin conteo").tag(0)
                        Text("3 segundos").tag(3)
                        Text("5 segundos").tag(5)
                        Text("10 segundos").tag(10)
                    }
                    .onChange(of: countdown) { v in Settings.set(v, .recordCountdown) }
                    Toggle("Arrancar el teleprompter al empezar a grabar", isOn: $autoPlay)
                        .onChange(of: autoPlay) { v in Settings.set(v, .recordAutoPlayPrompter) }
                    Toggle("Registrar los atajos de teclado para mostrarlos en el vídeo",
                           isOn: $keystrokes)
                        .onChange(of: keystrokes) { v in Settings.set(v, .recordKeystrokes) }
                    Text("Solo se apuntan ATAJOS (⌘S, ⌥⇧F…) y teclas que no escriben "
                         + "(Esc, flechas, Intro). El texto que teclees NO se registra nunca: "
                         + "podría ser una contraseña. Requiere permiso de Accesibilidad.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Capítulos automáticos al cruzar cada guía", isOn: $chapters)
                        .onChange(of: chapters) { v in Settings.set(v, .recordChapters) }
                    Text("Queda un capitulos.txt junto a los vídeos con la hora de cada sección.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Blindaje de la grabación") {
                    Toggle("Mantener el Mac despierto mientras se graba", isOn: $keepAwake)
                        .onChange(of: keepAwake) { v in Settings.set(v, .recordKeepAwake) }
                    Text("Ni la pantalla se apaga ni el Mac se duerme, a batería o enchufado. "
                         + "Sin esto, la captura de pantalla muere cuando la pantalla se apaga.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Reanudar solo si una captura se corta", isOn: $autoRestart)
                        .onChange(of: autoRestart) { v in Settings.set(v, .recordAutoRestart) }
                    Text("Si la pantalla o la cámara se cortan (cambio de resolución, monitor "
                         + "desconectado, bloqueo…), se reintenta hasta recuperarlas y la toma "
                         + "sigue en un archivo nuevo (parte2, parte3…) sin perder lo grabado. "
                         + "Incluye un vigilante que detecta escrituras congeladas.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Aviso sonoro si una pieza deja de grabarse", isOn: $failureSound)
                        .onChange(of: failureSound) { v in Settings.set(v, .recordFailureSound) }
                    Text("Un pitido insistente mientras falte una pieza. Se cuela en el "
                         + "micrófono: mejor eso que descubrir al final que falta media toma.")
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
                    Toggle("Montar las partes recuperadas tras un corte", isOn: $mountParts)
                        .onChange(of: mountParts) { v in Settings.set(v, .editorMountParts) }
                    Text("Si una toma tuvo cortes (parte2, parte3…), cada parte se coloca en "
                         + "su instante real del montaje y el hueco queda a la vista (fondo). "
                         + "Apagado: se monta solo la parte 1 y el editor avisa del resto.")
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
