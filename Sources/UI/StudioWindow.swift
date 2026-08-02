import AppKit
import AVFoundation
import SwiftUI

// Modo Estudio: grabar sin teleprompter. Una ventana propia con la cámara en
// vivo, los interruptores de qué grabar a mano y un botón grande. Para
// tutoriales, clases y demos donde no hay guion que leer — que es la mitad de
// las veces.
//
// No duplica el motor: usa el mismo RecordingEngine, la misma carpeta y el
// mismo editor. Solo cambia por dónde se entra.

@MainActor
final class StudioWindowController: NSObject, NSWindowDelegate {
    static let shared = StudioWindowController()
    private var window: NSWindow?

    func open() {
        guard Settings.bool(.recordingEnabled, default: false) else {
            let alert = NSAlert()
            alert.messageText = "La grabación está desactivada"
            alert.informativeText = "Actívala en Configuración → Grabación y vuelve a abrir el estudio."
            alert.runModal()
            return
        }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Estudio"
            w.center()
            w.delegate = self
            w.isReleasedWhenClosed = false
            // El estudio no sale en la grabación: es el panel de control de
            // quien graba, igual que el mando y el teleprompter.
            w.sharingType = .none
            window = w
        }
        window?.contentView = NSHostingView(rootView: StudioView())
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Soltar la cámara de la vista previa al cerrar: apagado = inerte.
        window?.contentView = nil
    }
}

struct StudioView: View {
    @ObservedObject private var engine = RecordingEngine.shared

    @State private var camera = Settings.bool(.recordCamera, default: true)
    @State private var screen = Settings.bool(.recordScreen, default: false)
    @State private var mic = Settings.bool(.recordMicInRecording, default: true)
    @State private var systemAudio = Settings.bool(.recordSystemAudio, default: false)
    @State private var countdown = Settings.int(.recordCountdown, default: 3)

    var body: some View {
        VStack(spacing: 0) {
            CameraPreview(enabled: camera && engine.phase == .idle)
                .frame(height: 300)
                .background(Color.black)
                .overlay {
                    if !camera {
                        Text("Cámara desactivada")
                            .foregroundStyle(.secondary)
                    }
                }

            Form {
                Section("Qué grabar") {
                    Toggle("Cámara", isOn: $camera)
                        .onChange(of: camera) { v in Settings.set(v, .recordCamera) }
                    Toggle("Pantalla", isOn: $screen)
                        .onChange(of: screen) { v in Settings.set(v, .recordScreen) }
                    Toggle("Micrófono", isOn: $mic)
                        .onChange(of: mic) { v in Settings.set(v, .recordMicInRecording) }
                    Toggle("Sonido del sistema", isOn: $systemAudio)
                        .onChange(of: systemAudio) { v in Settings.set(v, .recordSystemAudio) }
                    Picker("Preparación", selection: $countdown) {
                        Text("Sin espera").tag(0)
                        Text("3 s").tag(3)
                        Text("5 s").tag(5)
                        Text("10 s").tag(10)
                        Text("15 s").tag(15)
                    }
                    .onChange(of: countdown) { v in Settings.set(v, .recordCountdown) }
                }
                if let err = engine.lastError {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)

            bigButton
                .padding(14)
        }
        .frame(minWidth: 520, minHeight: 560)
    }

    private var bigButton: some View {
        VStack(spacing: 6) {
            switch engine.phase {
            case .idle:
                Button(action: { engine.start() }) {
                    Label("Grabar", systemImage: "record.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!camera && !screen)
                if !camera && !screen {
                    Text("Elige al menos una fuente")
                        .font(.caption).foregroundStyle(.orange)
                }
            case .countdown(let n):
                Button(action: { engine.toggle() }) {
                    Text("Cancelar (\(n))")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
            case .recording, .paused:
                HStack(spacing: 10) {
                    Button(action: { engine.togglePause() }) {
                        Label(engine.phase == .paused ? "Reanudar" : "Pausar",
                              systemImage: engine.phase == .paused ? "play.fill" : "pause.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    Button(action: { engine.stop() }) {
                        Label("Parar", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                Text(engine.elapsedText)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
            case .stopping:
                ProgressView("Guardando…")
            }
            if let s = engine.status, engine.phase != .idle {
                Text(s).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// Cámara en vivo para encuadrarse antes de grabar. Se apaga sola mientras se
// graba: la sesión de grabación necesita la cámara para ella.
private struct CameraPreview: NSViewRepresentable {
    let enabled: Bool

    final class PreviewView: NSView {
        private var session: AVCaptureSession?
        private var layerRef: AVCaptureVideoPreviewLayer?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { nil }

        func setEnabled(_ on: Bool) {
            if on {
                guard session == nil else { return }
                let s = AVCaptureSession()
                s.sessionPreset = .high
                let deviceID = Settings.string(.recordCameraDevice, default: "")
                let device = deviceID.isEmpty
                    ? AVCaptureDevice.default(for: .video)
                    : AVCaptureDevice(uniqueID: deviceID)
                guard let device, let input = try? AVCaptureDeviceInput(device: device),
                      s.canAddInput(input) else { return }
                s.addInput(input)
                let l = AVCaptureVideoPreviewLayer(session: s)
                l.videoGravity = .resizeAspect
                l.frame = bounds
                layer?.addSublayer(l)
                layerRef = l
                session = s
                DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
            } else {
                session?.stopRunning()
                layerRef?.removeFromSuperlayer()
                layerRef = nil
                session = nil
            }
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layerRef?.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> PreviewView {
        let v = PreviewView(frame: .zero)
        v.setEnabled(enabled)
        return v
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.setEnabled(enabled)
    }

    static func dismantleNSView(_ view: PreviewView, coordinator: ()) {
        view.setEnabled(false)
    }
}
