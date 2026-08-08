import AppKit
import AVFoundation
import Foundation
import IOKit.pwr_mgt
import ScreenCaptureKit

// Grabación de la presentación: cámara y pantalla como DOS archivos separados,
// arrancados en el mismo instante para que cuadren en el editor. Apagada por
// defecto; cada pieza (cámara, pantalla, micro, capítulos) se activa por su
// cuenta y ninguna toca el resto de la app.
//
// El teleprompter NUNCA sale en la grabación de pantalla: la captura excluye
// la ventana igual que el compartir pantalla. Eso no se negocia.

@MainActor
final class RecordingEngine: NSObject, ObservableObject {
    static let shared = RecordingEngine()

    enum Phase: Equatable {
        case idle
        case countdown(Int)
        case recording
        case paused
        case stopping
    }

    @Published var phase: Phase = .idle {
        didSet { RemoteControl.shared.broadcastIfRunning() }
    }
    @Published var status: String? = nil
    // Canal de ERROR separado del estado: el estado se sobrescribe con
    // «Grabando…» y los avisos se perdían. Este no se pisa y lo pinta el
    // mando flotante, que es donde el usuario está mirando.
    @Published var lastError: String? = nil
    // Piezas que el usuario pidió y NO se están grabando.
    @Published var missingPieces: [String] = []
    @Published var lastFolder: URL? = nil
    // Marca de tiempo del inicio real, para los capítulos.
    private var startedAt: Date? = nil
    private var chapterMarks: [(seconds: Double, label: String)] = []
    // Palabra↔segundo mientras se graba con el prompter en marcha: la base
    // de los subtítulos automáticos del editor. Pocas KB, sin audio.
    private var subtitleWords: [(seconds: Double, word: String)] = []
    // Recorrido del puntero durante la grabación, para poder resaltarlo
    // después en el montaje. Son unos pocos KB: t, x, y varias veces por
    // segundo, normalizados a la pantalla.
    private var cursorTrack: [(t: Double, x: Double, y: Double)] = []
    private var cursorTimer: Timer?

    // Cámara.
    private var cameraSession: AVCaptureSession?
    private var cameraOutput: AVCaptureMovieFileOutput?
    private var cameraDone: ((Bool) -> Void)?

    // Pantalla. El tipo concreto de la salida existe solo en macOS 15+,
    // así que se guarda sin tipo; la cámara funciona en cualquier versión.
    private var screenStream: SCStream?
    private var screenOutput: Any?

    // Garantía de grabación continua. Una toma de casi una hora se quedó en
    // seis minutos porque el Mac estaba a batería y apagó la pantalla por
    // inactividad: ScreenCaptureKit muere cuando la pantalla se apaga y nadie
    // reintentaba. De aquí en adelante: mientras se graba, el Mac no se
    // duerme; y si una captura igual se corta (cambio de resolución, monitor
    // desconectado, bloqueo), se reintenta sola y continúa en un archivo
    // nuevo (pantalla-<fecha>.parte2.mov, parte3…) sin perder lo ya escrito.
    private var awakeAssertions: [IOPMAssertionID] = []
    private var currentStamp = ""
    private var screenSegment = 1
    private var cameraSegment = 1
    private var screenSegmentStarts: [(file: String, start: Date)] = []
    private var cameraSegmentStarts: [(file: String, start: Date)] = []
    private var currentScreenFile = ""
    private var screenPixelSize = (width: 0, height: 0)
    private var screenRestartPending = false
    private var cameraRestartPending = false
    // La cámara reporta isRecording pero el vigilante la vio congelada:
    // permiso para tirar la sesión aunque «parezca» viva.
    private var cameraStalled = false
    private var watchdogTimer: Timer?
    private var lastScreenDuration = -1.0
    private var lastCameraDuration = -1.0
    private var screenDeadTicks = 0
    private var cameraDeadTicks = 0
    private var alertScheduled = false
    // Número de sesión: los reintentos encolados de una grabación vieja no
    // pueden dispararse dentro de la siguiente (encenderían piezas que nadie
    // pidió o matarían una sesión sana).
    private var sessionGeneration = 0

    private var countdownWork: DispatchWorkItem?
    // Detecta el PRIMER fotograma real de la cámara. session.isRunning se pone
    // en true antes de que fluya imagen; grabar en ese hueco pierde el inicio.
    private final class FrameSentinel: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        var onFirstFrame: (() -> Void)?
        private var fired = false
        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            guard !fired else { return }
            fired = true
            let cb = onFirstFrame
            onFirstFrame = nil
            DispatchQueue.main.async { cb?() }
        }
    }
    private var sentinel: FrameSentinel?

    // MARK: - Configuración

    static var enabled: Bool { Settings.bool(.recordingEnabled, default: false) }
    static var wantCamera: Bool { Settings.bool(.recordCamera, default: true) }
    static var wantScreen: Bool { Settings.bool(.recordScreen, default: false) }
    static var wantMic: Bool { Settings.bool(.recordMicInRecording, default: true) }
    static var wantChapters: Bool { Settings.bool(.recordChapters, default: false) }
    static var wantSystemAudio: Bool { Settings.bool(.recordSystemAudio, default: false) }
    static var wantAudioCopies: Bool { Settings.bool(.recordAudioCopies, default: false) }
    // Al terminar la cuenta regresiva, el teleprompter arranca solo: si
    // estás grabando es porque vas a hablar. Se puede apagar en Ajustes.
    static var wantAutoPlayPrompter: Bool {
        Settings.bool(.recordAutoPlayPrompter, default: true)
    }
    static var countdownSeconds: Int { Settings.int(.recordCountdown, default: 3) }
    // Mientras se graba, ni la pantalla se apaga ni el sistema se duerme
    // (a batería o enchufado): es la causa número uno de capturas muertas.
    static var wantKeepAwake: Bool { Settings.bool(.recordKeepAwake, default: true) }
    // Si una pieza se corta a mitad de toma, se reintenta sola en un archivo
    // nuevo; incluye al vigilante que detecta escrituras congeladas.
    static var wantAutoRestart: Bool { Settings.bool(.recordAutoRestart, default: true) }
    // Pitido de alarma si una pieza lleva unos segundos sin grabarse. Se cuela
    // en el micrófono, sí: mejor eso que descubrir al final que falta media
    // grabación.
    static var wantFailureSound: Bool { Settings.bool(.recordFailureSound, default: true) }

    // Carpeta accesible sin abrir la app: Películas/BtoPrompter.
    static var baseFolder: URL {
        let custom = Settings.string(.recordFolder, default: "")
        if !custom.isEmpty { return URL(fileURLWithPath: custom, isDirectory: true) }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BtoPrompter", isDirectory: true)
    }

    // MARK: - Ciclo

    func toggle() {
        switch phase {
        case .idle: start()
        case .countdown: cancelCountdown()
        case .recording, .paused: stop()
        case .stopping: break
        }
    }

    // Pausa LÓGICA: las cámaras siguen rodando (pararlas y rearrancarlas
    // desincronizaría cámara y pantalla, que es lo que más costó cuadrar),
    // pero el tramo queda marcado y el teleprompter se detiene. El editor
    // recibe las marcas para poder cortarlas.
    @Published var elapsedText = "0:00"
    private var pausedRanges: [(from: Double, to: Double)] = []
    private var pauseStartedAt: Double? = nil
    private var tickTimer: Timer?

    func togglePause() {
        guard let start = startedAt else { return }
        let now = Date().timeIntervalSince(start)
        switch phase {
        case .recording:
            pauseStartedAt = now
            phase = .paused
            if Self.wantAutoPlayPrompter, PrompterModel.shared.isPlaying {
                PrompterModel.shared.pause()
            }
        case .paused:
            if let from = pauseStartedAt {
                pausedRanges.append((from, now))
            }
            pauseStartedAt = nil
            phase = .recording
            let model = PrompterModel.shared
            if Self.wantAutoPlayPrompter, model.mode == .prompting, !model.isPlaying {
                model.play()
            }
        default: break
        }
    }

    private func startTicking() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startedAt else { return }
                let s = Int(Date().timeIntervalSince(start))
                self.elapsedText = String(format: "%d:%02d", s / 60, s % 60)
            }
        }
    }

    private func writePauses() {
        guard !pausedRanges.isEmpty, let folder = lastFolder else { return }
        let payload = pausedRanges.map { ["from": $0.from, "to": $0.to] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted]) else { return }
        try? data.write(to: folder.appendingPathComponent("pausas.json"))
    }

    func start() {
        guard Self.enabled else { return }
        guard phase == .idle else { return }
        guard Self.wantCamera || Self.wantScreen else {
            status = "Nada que grabar: activa cámara o pantalla en Ajustes"
            return
        }
        let n = Self.countdownSeconds
        if n > 0 {
            runCountdown(n)
        } else {
            beginRecording()
        }
    }

    private func runCountdown(_ n: Int) {
        phase = .countdown(n)
        guard n > 0 else {
            CountdownWindowController.shared.hide()
            beginRecording()
            return
        }
        // El 3, 2, 1 a pantalla completa: con teleprompter o sin él.
        CountdownWindowController.shared.show(n)
        let work = DispatchWorkItem { [weak self] in self?.runCountdown(n - 1) }
        countdownWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func cancelCountdown() {
        countdownWork?.cancel()
        countdownWork = nil
        CountdownWindowController.shared.hide()
        // Invalida las preparaciones en vuelo: sin esto, cancelar durante el
        // calentamiento de cámara/pantalla mostraba «cancelada»… y la
        // grabación arrancaba igual unos segundos después.
        sessionGeneration += 1
        phase = .idle
        status = "Grabación cancelada"
    }

    private func beginRecording() {
        let stamp = Self.timestamp()
        let folder = Self.baseFolder.appendingPathComponent(stamp, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            phase = .idle
            status = "No se pudo crear la carpeta: \(error.localizedDescription)"
            return
        }
        lastFolder = folder
        chapterMarks = []
        subtitleWords = []
        firstFrameTimes = [:]
        lastError = nil
        missingPieces = []
        currentStamp = stamp
        sessionGeneration += 1
        screenSegment = 1
        cameraSegment = 1
        screenSegmentStarts = []
        cameraSegmentStarts = []
        currentScreenFile = ""
        screenRestartPending = false
        cameraRestartPending = false
        cameraStalled = false
        let wantedCamera = Self.wantCamera
        let wantedScreen = Self.wantScreen
        status = nil

        // El hardware tarda segundos en despertar. Primero se PREPARA todo
        // (cámara encendida, captura de pantalla lista) y solo cuando ambos
        // responden se da la orden de escribir, una tras otra en el mismo
        // instante. Si se escribiera al arrancar, los primeros segundos del
        // discurso se perderían y los dos archivos no cuadrarían.
        let ready = DispatchGroup()
        var pieces: [String] = []

        // Mientras el hardware calienta, el toggle debe CANCELAR (no arrancar
        // otra grabación): fase de cuenta cero + número de sesión para que
        // una preparación cancelada muera de verdad.
        if phase == .idle { phase = .countdown(0) }
        let gen = sessionGeneration

        if Self.wantCamera {
            ready.enter()
            prepareCamera { [weak self] pair in
                guard let self, gen == self.sessionGeneration else {
                    pair?.session.stopRunning()
                    ready.leave()
                    return
                }
                if let pair {
                    self.cameraSession = pair.session
                    self.cameraOutput = pair.output
                    pieces.append("cámara")
                }
                ready.leave()
            }
        }
        if Self.wantScreen {
            ready.enter()
            prepareScreen { [weak self] stream in
                guard let self, gen == self.sessionGeneration else {
                    stream?.stopCapture { _ in }
                    ready.leave()
                    return
                }
                if let stream {
                    self.screenStream = stream
                    pieces.append("pantalla")
                }
                ready.leave()
            }
        }

        ready.notify(queue: .main) { [weak self] in
            guard let self else { return }
            guard gen == self.sessionGeneration, self.phase != .idle else {
                // Cancelada durante la preparación: apagar lo que llegó a
                // encenderse y no arrancar nada.
                self.cameraSession?.stopRunning()
                self.cameraSession = nil
                self.cameraOutput = nil
                self.screenStream?.stopCapture { _ in }
                self.screenStream = nil
                return
            }
            guard !pieces.isEmpty else {
                self.phase = .idle
                if self.status == nil { self.status = "No se pudo preparar ninguna captura" }
                return
            }
            self.startedAt = Date()
            self.startCursorTracking()
            KeystrokeRecorder.shared.start(at: Date())
            self.pausedRanges = []
            self.pauseStartedAt = nil
            self.elapsedText = "0:00"
            self.startTicking()
            // La cámara es la lenta: arranca primero, y la pantalla (que
            // escribe al instante porque su captura ya corre) espera a que la
            // cámara confirme su primer fotograma. Así los dos archivos
            // empiezan casi en el mismo instante.
            let screenURL = folder.appendingPathComponent("pantalla-\(stamp).mov")
            if let out = self.cameraOutput {
                self.pendingScreenURL = screenURL
                out.startRecording(to: folder.appendingPathComponent("camara-\(stamp).mov"),
                                   recordingDelegate: self)
                // Tope: si la cámara nunca confirma, la pantalla no se pierde.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, gen == self.sessionGeneration else { return }
                    self.startPendingScreen()
                }
            } else {
                self.pendingScreenURL = screenURL
                self.startPendingScreen()
            }
            // Lo que el usuario pidió y no salió: se dice, no se oculta tras
            // un «Grabando…» tranquilizador. Se FUSIONA (no se pisa): la
            // escritura de pantalla pudo fallar ya y haberse apuntado sola.
            var missing: [String] = []
            if wantedCamera, !pieces.contains("cámara") { missing.append("cámara") }
            if wantedScreen, !pieces.contains("pantalla") { missing.append("pantalla") }
            for m in missing where !self.missingPieces.contains(m) {
                self.missingPieces.append(m)
            }
            self.phase = .recording
            self.holdAwakeAssertions()
            self.startWatchdog()
            self.status = "Grabando " + pieces.sorted().joined(separator: " + ")
            if !self.missingPieces.isEmpty {
                let falta = self.missingPieces.joined(separator: " y ")
                self.lastError = "NO se está grabando: \(falta). "
                    + (self.lastError ?? "")
                // Las piezas que fallaron al ARRANCAR también se reintentan
                // y hacen sonar la alarma: antes quedaban muertas y mudas
                // toda la toma.
                if self.missingPieces.contains("pantalla"), wantedScreen {
                    self.scheduleScreenRestart(after: 3)
                }
                if self.missingPieces.contains("cámara"), wantedCamera {
                    self.scheduleCameraRestart(after: 3)
                }
                self.scheduleFailureAlert()
            }
            // El prompter arranca con la grabación: nada de grabar diez
            // segundos de silencio buscando la tecla de play. Solo si ya
            // estás en el prompter y no se está reproduciendo.
            if Self.wantAutoPlayPrompter {
                let model = PrompterModel.shared
                if model.mode == .prompting, !model.isPlaying {
                    model.play()
                }
            }
        }
    }

    // Hora del primer fotograma real de cada archivo, para alinear en el editor.
    private var firstFrameTimes: [String: Date] = [:]
    // URL de pantalla en espera de que la cámara confirme su arranque.
    private var pendingScreenURL: URL?

    private func startPendingScreen() {
        guard let url = pendingScreenURL else { return }
        pendingScreenURL = nil
        startScreenWriting(to: url)
    }

    func noteFirstFrame(_ piece: String) {
        if firstFrameTimes[piece] == nil { firstFrameTimes[piece] = Date() }
    }

    private func writeSyncFile() {
        // También con UNA sola pieza si hubo cortes: los instantes de cada
        // parte son el único registro del hueco y no se pueden perder.
        guard let folder = lastFolder, !firstFrameTimes.isEmpty,
              firstFrameTimes.count > 1
                || screenSegmentStarts.count > 1
                || cameraSegmentStarts.count > 1 else { return }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = ["# Inicio real de cada archivo (para alinear en el editor)", ""]
        for (piece, date) in firstFrameTimes.sorted(by: { $0.key < $1.key }) {
            lines.append("\(piece): \(f.string(from: date))")
        }
        if let cam = firstFrameTimes["camara"], let scr = firstFrameTimes["pantalla"] {
            let ms = Int((scr.timeIntervalSince(cam)) * 1000)
            lines.append("")
            lines.append("desfase pantalla-camara: \(ms) ms"
                         + (abs(ms) < 100 ? " (despreciable)" : " → recorta este desfase al montar"))
        }
        if screenSegmentStarts.count > 1 || cameraSegmentStarts.count > 1 {
            lines.append("")
            lines.append("# Hubo cortes: la grabación siguió en partes (inicio real de cada una)")
            for s in cameraSegmentStarts { lines.append("\(s.file): \(f.string(from: s.start))") }
            for s in screenSegmentStarts { lines.append("\(s.file): \(f.string(from: s.start))") }
        }
        try? lines.joined(separator: "\n")
            .write(to: folder.appendingPathComponent("sync.txt"), atomically: true, encoding: .utf8)
        // Versión para máquinas: el editor de composición la lee para alinear.
        // La referencia es la primera pieza que arrancó: todo se mide contra
        // ella, así el montaje puede correr cada archivo lo justo.
        if let base = firstFrameTimes.values.min() {
            var payload: [String: Any] = [
                "cameraOffset": (firstFrameTimes["camara"] ?? base).timeIntervalSince(base),
                "screenOffset": (firstFrameTimes["pantalla"] ?? base).timeIntervalSince(base),
            ]
            if let mic = firstFrameTimes["microfono"] {
                payload["micOffset"] = mic.timeIntervalSince(base)
            }
            // Compatibilidad con los proyectos ya grabados.
            if let cam = firstFrameTimes["camara"], let scr = firstFrameTimes["pantalla"] {
                payload["offsetSeconds"] = scr.timeIntervalSince(cam)
            }
            // Si hubo cortes, cada parte lleva su instante de arranque: el
            // montaje puede colocar los segmentos en su sitio exacto.
            if screenSegmentStarts.count > 1 {
                payload["screenSegments"] = screenSegmentStarts.map {
                    ["file": $0.file, "offsetSeconds": $0.start.timeIntervalSince(base)]
                }
            }
            if cameraSegmentStarts.count > 1 {
                payload["cameraSegments"] = cameraSegmentStarts.map {
                    ["file": $0.file, "offsetSeconds": $0.start.timeIntervalSince(base)]
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
                try? data.write(to: folder.appendingPathComponent("sync.json"))
            }
        }
    }

    func stop() {
        guard phase == .recording || phase == .paused else { return }
        if phase == .paused, let start = startedAt, let from = pauseStartedAt {
            pausedRanges.append((from, Date().timeIntervalSince(start)))
            pauseStartedAt = nil
        }
        tickTimer?.invalidate()
        tickTimer = nil
        phase = .stopping
        let gen = sessionGeneration
        let group = DispatchGroup()

        if let out = cameraOutput, out.isRecording {
            group.enter()
            cameraDone = { _ in group.leave() }
            out.stopRecording()
        }
        if let stream = screenStream {
            group.enter()
            // Primero deja de fluir la captura; después el escritor remata el
            // archivo (moov final). El orden importa: al revés se pierden los
            // últimos fotogramas en vuelo.
            var finishWriter: ((@escaping () -> Void) -> Void)?
            if #available(macOS 15.0, *), let w = screenOutput as? ScreenSegmentWriter {
                finishWriter = w.finish
            }
            stream.stopCapture { _ in
                DispatchQueue.main.async {
                    if let finishWriter {
                        finishWriter { group.leave() }
                    } else {
                        group.leave()
                    }
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            // Un cierre atascado puede confirmar DESPUÉS del remate forzado,
            // incluso con otra grabación ya en marcha: solo vale para la suya.
            guard let self, gen == self.sessionGeneration else { return }
            self.finishStop()
        }
        // Tope: un escritor colgado (disco de red, kernel atascado) puede no
        // confirmar el cierre JAMÁS; sin esto la app quedaba clavada en
        // «deteniendo» con el Mac insomne y sin escribir ningún sidecar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, gen == self.sessionGeneration,
                  self.phase == .stopping else { return }
            self.lastError = "El cierre se atascó: se forzó el remate. "
                + "Revisa la carpeta; los vídeos llegan hasta el último fragmento."
            self.finishStop()
        }
    }

    private func finishStop() {
        guard phase == .stopping else { return }
        stopWatchdog()
        releaseAwakeAssertions()
        // Restos de un cierre (quizá forzado): un callback rancio de cámara o
        // una pantalla en espera no pueden colarse en la sesión siguiente.
        cameraDone = nil
        pendingScreenURL = nil
        // Aquí, no en stop(): los registros de segmento llegan por saltos
        // asíncronos y escribir antes de que el grupo confirme podía dejar
        // sync.json sin la última parte.
        writeSyncFile()
        cameraSession?.stopRunning()
        cameraSession = nil
        cameraOutput = nil
        screenStream = nil
        screenOutput = nil
        writeChapters()
        writeCursorTrack()
        if let folder = lastFolder {
            KeystrokeRecorder.shared.write(toFolder: folder, anchor: firstFrameTimes["pantalla"])
        }
        writePauses()
        writeSubtitleTrack()
        extractAudioCopies()
        phase = .idle
        // No se declara «guardada» sin mirar: si no hay archivos, se dice.
        let saved = (try? FileManager.default.contentsOfDirectory(
            atPath: lastFolder?.path ?? ""))?.filter { $0.hasSuffix(".mov") } ?? []
        if saved.isEmpty {
            status = "No se guardó ningún vídeo"
            lastError = "La grabación terminó sin producir ningún archivo de vídeo"
        } else {
            status = "Grabación guardada (\(saved.count) archivo\(saved.count == 1 ? "" : "s"))"
        }
        if let f = lastFolder {
            // Con el editor activado y las DOS piezas grabadas, se ofrece
            // componer de una vez; si no, se enseña la carpeta como siempre.
            if VideoEditorWindowController.enabled,
               CompositionBuilder.sources(inFolder: f) != nil {
                VideoEditorWindowController.shared.open(folder: f)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([f])
            }
        }
    }

    // MARK: - Cámara

    // Devuelve la pieza por el callback en vez de asignarla aquí: quien pide
    // decide dónde guardarla. Un callback rezagado de una sesión vieja ya no
    // puede pisar la cámara de la sesión nueva.
    typealias CameraPair = (session: AVCaptureSession, output: AVCaptureMovieFileOutput)

    private func prepareCamera(_ done: @escaping (CameraPair?) -> Void) {
        let session = AVCaptureSession()
        session.sessionPreset = .high
        let deviceID = Settings.string(.recordCameraDevice, default: "")
        let device: AVCaptureDevice?
        if !deviceID.isEmpty {
            device = AVCaptureDevice(uniqueID: deviceID)
        } else {
            device = AVCaptureDevice.default(for: .video)
        }
        guard let cam = device, let input = try? AVCaptureDeviceInput(device: cam),
              session.canAddInput(input) else {
            status = "Cámara no disponible"
            lastError = "La cámara elegida no está disponible (¿desconectada?)"
            done(nil)
            return
        }
        session.addInput(input)
        // El micrófono va SIEMPRE dentro del archivo de cámara: así comparte
        // reloj con la imagen y la voz cuadra con los labios por construcción.
        // Se intentó grabarlo aparte con la cancelación de eco de macOS y se
        // retiró: medido, macOS NO borra del micrófono el sonido que otras
        // apps sacan por los altavoces (solo lo atenúa, dejando mudo lo que
        // hay que conservar), y el archivo aparte arrancaba dos segundos
        // antes que la cámara, descuadrando todo el montaje.
        if Self.wantMic,
           let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }
        let output = AVCaptureMovieFileOutput()
        // Fragmentos cada 5 s (por defecto son 10): si la app muere de golpe,
        // el archivo de cámara queda legible hasta el último fragmento.
        output.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
        guard session.canAddOutput(output) else {
            status = "No se pudo preparar la grabación de cámara"
            done(nil)
            return
        }
        session.addOutput(output)
        // Centinela de fotogramas: "lista" = imagen fluyendo, no solo isRunning.
        let sentinelOutput = AVCaptureVideoDataOutput()
        sentinelOutput.alwaysDiscardsLateVideoFrames = true
        let watcher = FrameSentinel()
        var finished = false
        watcher.onFirstFrame = { [weak self] in
            guard !finished else { return }
            finished = true
            self?.sentinel = nil
            done((session, output))
        }
        sentinel = watcher
        if session.canAddOutput(sentinelOutput) {
            sentinelOutput.setSampleBufferDelegate(watcher,
                queue: DispatchQueue(label: "recording.sentinel"))
            session.addOutput(sentinelOutput)
        }
        // startRunning bloquea segundos: fuera del hilo principal. Tope de
        // seguridad por si el centinela nunca dispara (cámara rara).
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard !finished else { return }
                finished = true
                self?.sentinel = nil
                done(session.isRunning ? (session, output) : nil)
            }
        }
    }

    // MARK: - Pantalla

    // Deja la captura corriendo SIN escribir; la escritura llega después.
    // Devuelve el stream por el callback en vez de asignarlo aquí: quien
    // pide decide, y un callback rezagado no pisa la sesión nueva.
    private func prepareScreen(_ done: @escaping (SCStream?) -> Void) {
        // El permiso se comprueba ANTES: sin él, la captura fallaba y la
        // grabación seguía solo con cámara sin que nadie se enterara.
        guard CGPreflightScreenCaptureAccess() else {
            lastError = "Falta el permiso de Grabación de pantalla. "
                + "Actívalo en Ajustes del Sistema → Privacidad y seguridad → "
                + "Grabación de pantalla, y reinicia BtoPrompter."
            CGRequestScreenCaptureAccess()
            done(nil)
            return
        }
        guard #available(macOS 15.0, *) else {
            status = "Grabar la pantalla necesita macOS 15 o superior (la cámara sí funciona)"
            done(nil)
            return
        }
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                                   onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    status = "No se encontró la pantalla"
                    lastError = "No se encontró ninguna pantalla que grabar"
                    done(nil)
                    return
                }
                // El teleprompter JAMÁS sale en la grabación: se excluye la
                // ventana propia, igual que en el compartir pantalla.
                let own = content.windows.filter {
                    $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
                }
                let filter = SCContentFilter(display: display, excludingWindows: own)
                let config = SCStreamConfiguration()
                config.width = display.width * 2
                config.height = display.height * 2
                screenPixelSize = (display.width * 2, display.height * 2)
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                // Margen de buffers: el escritor retiene el último fotograma
                // para el latido y el pool no puede quedarse sin sitio.
                config.queueDepth = 8
                // El sonido del SISTEMA (lo que suena en el Mac) es opcional:
                // con él, el editor puede mezclar la vista del escritorio con
                // el audio que se quiera. El micrófono sigue yendo con la cámara.
                config.capturesAudio = Self.wantSystemAudio
                if Self.wantSystemAudio {
                    config.excludesCurrentProcessAudio = true   // sin ecos de la propia app
                }
                config.showsCursor = true

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try await stream.startCapture()
                done(stream)
            } catch {
                status = "Pantalla: \(error.localizedDescription)"
                lastError = "La pantalla no se pudo preparar: \(error.localizedDescription)"
                done(nil)
            }
        }
    }

    // La captura ya corre: engancharle el escritor empieza a escribir ya.
    // Escritor propio con fragmentos (no SCRecordingOutput): si el proceso
    // muere de golpe, el archivo queda legible hasta el último fragmento.
    private func startScreenWriting(to url: URL) {
        guard let stream = screenStream else { return }
        guard #available(macOS 15.0, *) else { return }
        do {
            let writer = try ScreenSegmentWriter(outputURL: url,
                                                 width: screenPixelSize.width,
                                                 height: screenPixelSize.height,
                                                 withAudio: Self.wantSystemAudio)
            writer.onStart = { [weak self] in self?.noteScreenSegmentStarted() }
            writer.onError = { [weak self] error in
                guard let self else { return }
                let dying = self.screenStream
                self.screenStream = nil
                dying?.stopCapture { _ in }
                self.handleScreenFailure(error)
            }
            try writer.attach(to: stream)
            screenOutput = writer
            currentScreenFile = url.lastPathComponent
            lastScreenDuration = -1
            screenDeadTicks = 0
        } catch {
            status = "Pantalla: \(error.localizedDescription)"
            lastError = "La pantalla NO se está grabando: \(error.localizedDescription)"
            if !missingPieces.contains("pantalla") { missingPieces.append("pantalla") }
            screenStream?.stopCapture { _ in }
            screenStream = nil
            screenOutput = nil
            scheduleScreenRestart(after: 3)
            scheduleFailureAlert()
        }
    }

    // MARK: - Capítulos

    // El prompter avisa al cruzar una guía; queda un .txt con las marcas.
    func markChapter(_ label: String) {
        guard phase == .recording, Self.wantChapters, let start = startedAt else { return }
        chapterMarks.append((Date().timeIntervalSince(start), label))
    }

    // El prompter avisa en cada palabra: base de los subtítulos automáticos.
    // El tiempo va anclado al primer fotograma real de la cámara (o al
    // arranque si no hay cámara) para cuadrar con el vídeo.
    func noteWord(_ word: String) {
        guard phase == .recording, !word.isEmpty else { return }
        let anchor = firstFrameTimes["camara"] ?? startedAt
        guard let anchor else { return }
        subtitleWords.append((Date().timeIntervalSince(anchor), word))
    }

    // El puntero se muestrea 20 veces por segundo: suficiente para que el
    // halo siga al ratón sin dar saltos, y ridículo en tamaño.
    private func startCursorTracking() {
        cursorTrack = []
        cursorTimer?.invalidate()
        guard Self.wantScreen else { return }
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startedAt, self.phase == .recording,
                      let screen = NSScreen.main else { return }
                let p = NSEvent.mouseLocation
                let f = screen.frame
                guard f.width > 0, f.height > 0 else { return }
                // Normalizado y con el origen ARRIBA, como el vídeo.
                self.cursorTrack.append((
                    t: Date().timeIntervalSince(start),
                    x: (p.x - f.minX) / f.width,
                    y: 1 - (p.y - f.minY) / f.height))
            }
        }
    }

    private func writeCursorTrack() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        guard !cursorTrack.isEmpty, let folder = lastFolder else { return }
        // Se ancla al primer fotograma real de la pantalla, que es sobre la
        // que se va a dibujar el halo.
        let anchor = firstFrameTimes["pantalla"] ?? startedAt
        let shift = anchor.map { $0.timeIntervalSince(startedAt ?? $0) } ?? 0
        let lines = cursorTrack.compactMap { e -> String? in
            let t = e.t - shift
            guard t >= 0 else { return nil }
            let payload: [String: Any] = ["t": (t * 100).rounded() / 100,
                                          "x": (e.x * 1000).rounded() / 1000,
                                          "y": (e.y * 1000).rounded() / 1000]
            guard let d = try? JSONSerialization.data(withJSONObject: payload),
                  let s = String(data: d, encoding: .utf8) else { return nil }
            return s
        }
        try? lines.joined(separator: "\n")
            .write(to: folder.appendingPathComponent("cursor.jsonl"),
                   atomically: true, encoding: .utf8)
    }

    private func writeSubtitleTrack() {
        guard !subtitleWords.isEmpty, let folder = lastFolder else { return }
        let lines = subtitleWords.compactMap { entry -> String? in
            guard entry.seconds >= 0 else { return nil }
            let payload: [String: Any] = ["w": entry.word,
                                          "t": (entry.seconds * 100).rounded() / 100]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let line = String(data: data, encoding: .utf8) else { return nil }
            return line
        }
        try? lines.joined(separator: "\n")
            .write(to: folder.appendingPathComponent("subtitulos.jsonl"),
                   atomically: true, encoding: .utf8)
    }

    private func writeChapters() {
        guard Self.wantChapters, !chapterMarks.isEmpty, let folder = lastFolder else { return }
        var lines = ["# Capítulos — \(folder.lastPathComponent)", ""]
        for m in chapterMarks {
            let t = Int(m.seconds)
            lines.append(String(format: "%02d:%02d:%02d  %@", t / 3600, (t % 3600) / 60, t % 60, m.label))
        }
        let url = folder.appendingPathComponent("capitulos.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func handleScreenFailure(_ error: Error) {
        guard phase == .recording || phase == .paused else { return }
        // El escritor vive en la app: si lo que murió fue el stream, rematarlo
        // salva lo grabado hasta el instante EXACTO del corte (no solo hasta
        // el último fragmento). Si el muerto es el propio escritor, su
        // finish() ya sabe cancelar sin hacer daño.
        if #available(macOS 15.0, *), let w = screenOutput as? ScreenSegmentWriter {
            w.finish { }
        }
        screenStream = nil
        screenOutput = nil
        if !missingPieces.contains("pantalla") { missingPieces.append("pantalla") }
        lastError = "La captura de pantalla se cortó: \(error.localizedDescription)"
            + (Self.wantAutoRestart ? " Reintentando…" : "")
        status = lastError
        scheduleScreenRestart(after: 1)
        scheduleFailureAlert()
    }

    // MARK: - Recuperación automática

    // La pantalla se cayó (se apagó, cambió de resolución, se bloqueó la
    // sesión…): reintentar hasta que vuelva, y seguir en un archivo nuevo.
    // Lo ya grabado queda intacto; el hueco queda anotado en sync.json.
    // El flag *Pending se mantiene en true durante TODO el intento (no solo
    // hasta entrar): un segundo fallo a mitad de un intento en vuelo no puede
    // encolar otro solapado — dos startRecording sobre el mismo output tumban
    // la app. Y cada closure lleva su número de sesión: uno rezagado de la
    // grabación anterior no toca la siguiente.
    private func scheduleScreenRestart(after seconds: Double) {
        guard Self.wantAutoRestart, !screenRestartPending else { return }
        screenRestartPending = true
        let gen = sessionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.attemptScreenRestart(generation: gen)
        }
    }

    private func attemptScreenRestart(generation: Int) {
        guard generation == sessionGeneration else { return }
        guard phase == .recording || phase == .paused, screenStream == nil,
              let folder = lastFolder else {
            screenRestartPending = false
            return
        }
        prepareScreen { [weak self] stream in
            guard let self else { stream?.stopCapture { _ in }; return }
            guard generation == self.sessionGeneration,
                  self.phase == .recording || self.phase == .paused else {
                // Llegó tarde: este stream es huérfano, apagarlo sin tocar
                // el estado de la sesión vigente.
                stream?.stopCapture { _ in }
                if generation == self.sessionGeneration { self.screenRestartPending = false }
                return
            }
            guard let stream else {
                self.screenRestartPending = false
                self.scheduleScreenRestart(after: 3)
                return
            }
            self.screenStream = stream
            // La parte se numera por arranques REALES: si la parte 1 nunca
            // llegó a escribir, el reintento vuelve a usar el nombre base.
            let n = self.screenSegmentStarts.count + 1
            self.screenSegment = n
            let name = n == 1 ? "pantalla-\(self.currentStamp).mov"
                              : "pantalla-\(self.currentStamp).parte\(n).mov"
            let url = folder.appendingPathComponent(name)
            self.removeStaleStub(url)
            self.screenRestartPending = false
            self.startScreenWriting(to: url)
        }
    }

    // La cámara se cortó (archivo cerrado sin pedirlo, dispositivo
    // desconectado, escritura congelada): mismo trato que la pantalla.
    func handleCameraFailure(_ error: Error) {
        guard phase == .recording || phase == .paused else { return }
        if !missingPieces.contains("cámara") { missingPieces.append("cámara") }
        lastError = "La cámara se cortó: \(error.localizedDescription)"
            + (Self.wantAutoRestart ? " Reintentando…" : "")
        status = lastError
        // Margen para que el archivo anterior termine de cerrarse.
        scheduleCameraRestart(after: 1.5)
        scheduleFailureAlert()
    }

    private func scheduleCameraRestart(after seconds: Double) {
        guard Self.wantAutoRestart, !cameraRestartPending else { return }
        cameraRestartPending = true
        let gen = sessionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.attemptCameraRestart(generation: gen)
        }
    }

    private func attemptCameraRestart(generation: Int) {
        guard generation == sessionGeneration else { return }
        guard phase == .recording || phase == .paused, let folder = lastFolder else {
            cameraRestartPending = false
            return
        }
        // ¿La pieza ya está sana (reinicio duplicado o tardío)? No tocar nada:
        // un stopRunning aquí mataría una grabación viva. Si está ATASCADA
        // (isRecording pero sin avanzar, lo marcó el vigilante), sí se tira.
        if let out = cameraOutput, out.isRecording, !cameraStalled {
            cameraRestartPending = false
            return
        }
        let n = cameraSegmentStarts.count + 1
        cameraSegment = n
        let name = n == 1 ? "camara-\(currentStamp).mov"
                          : "camara-\(currentStamp).parte\(n).mov"
        let url = folder.appendingPathComponent(name)
        removeStaleStub(url)
        if !cameraStalled, let session = cameraSession, session.isRunning,
           let out = cameraOutput, !out.isRecording {
            lastCameraDuration = -1
            cameraDeadTicks = 0
            cameraRestartPending = false
            out.startRecording(to: url, recordingDelegate: self)
            return
        }
        // La sesión entera murió o quedó atascada: levantarla de cero.
        cameraStalled = false
        cameraSession?.stopRunning()
        cameraSession = nil
        cameraOutput = nil
        prepareCamera { [weak self] pair in
            guard let self else { pair?.session.stopRunning(); return }
            guard generation == self.sessionGeneration,
                  self.phase == .recording || self.phase == .paused else {
                pair?.session.stopRunning()
                if generation == self.sessionGeneration { self.cameraRestartPending = false }
                return
            }
            guard let pair else {
                self.cameraRestartPending = false
                self.scheduleCameraRestart(after: 3)
                return
            }
            self.cameraSession = pair.session
            self.cameraOutput = pair.output
            self.lastCameraDuration = -1
            self.cameraDeadTicks = 0
            self.cameraRestartPending = false
            pair.output.startRecording(to: url, recordingDelegate: self)
        }
    }

    // Borra el archivo a medias de un intento que nunca llegó a escribir:
    // solo si ningún segmento ARRANCADO lleva ese nombre (jamás un archivo
    // con contenido real).
    private func removeStaleStub(_ url: URL) {
        let name = url.lastPathComponent
        let started = screenSegmentStarts.contains { $0.file == name }
            || cameraSegmentStarts.contains { $0.file == name }
        guard !started, FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Vigilante

    // Cada 5 s comprueba que lo grabado sigue AVANZANDO: una captura puede
    // quedarse muda sin lanzar error ninguno. Si la duración escrita no se
    // mueve entre dos revisiones, esa pieza está muerta y se reinicia.
    private func startWatchdog() {
        stopWatchdog()
        guard Self.wantAutoRestart else { return }
        lastScreenDuration = -1
        lastCameraDuration = -1
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchdogTick() }
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        screenDeadTicks = 0
        cameraDeadTicks = 0
    }

    private func watchdogTick() {
        guard phase == .recording || phase == .paused else { return }
        // Dos formas de morir en silencio: duración CLAVADA (escritor
        // congelado: un tick basta) y duración que NUNCA arranca — NaN/0 con
        // isRecording en true, un dispositivo que jamás entregó media; se le
        // dan 3 ticks (~15 s) de gracia y se declara atasco. Sin esto, el
        // guard de «pieza sana» bloqueaba el reintento para siempre.
        if #available(macOS 15.0, *), let out = screenOutput as? ScreenSegmentWriter {
            let d = out.writtenSeconds
            let alive = d.isFinite && d > 0
            if alive, abs(d - lastScreenDuration) >= 0.25 {
                lastScreenDuration = d
                screenDeadTicks = 0
            } else {
                screenDeadTicks += 1
                if screenDeadTicks >= (alive ? 1 : 3) {
                    screenDeadTicks = 0
                    let stream = screenStream
                    screenStream = nil
                    stream?.stopCapture { _ in }
                    handleScreenFailure(NSError(
                        domain: "BtoPrompter", code: 1,
                        userInfo: [NSLocalizedDescriptionKey:
                                   "la escritura se congeló (vigilante)"]))
                }
            }
        }
        if let out = cameraOutput, out.isRecording {
            let d = out.recordedDuration.seconds
            let alive = d.isFinite && d > 0
            if alive, abs(d - lastCameraDuration) >= 0.25 {
                lastCameraDuration = d
                cameraDeadTicks = 0
            } else {
                cameraDeadTicks += 1
                if cameraDeadTicks >= (alive ? 1 : 3) {
                    cameraDeadTicks = 0
                    cameraStalled = true
                    out.stopRecording()
                    lastCameraDuration = -1
                    handleCameraFailure(NSError(
                        domain: "BtoPrompter", code: 2,
                        userInfo: [NSLocalizedDescriptionKey:
                                   "la escritura se congeló (vigilante)"]))
                }
            }
        }
    }

    // MARK: - Mac despierto y alarma

    // Grabando, el Mac no se apaga NI se duerme, a batería o no: una toma de
    // horas no puede depender de que alguien mueva el ratón a tiempo.
    private func holdAwakeAssertions() {
        guard Self.wantKeepAwake, awakeAssertions.isEmpty else { return }
        let wanted: [(CFString, String)] = [
            (kIOPMAssertionTypeNoDisplaySleep as CFString, "BtoPrompter grabando (pantalla)"),
            (kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, "BtoPrompter grabando"),
        ]
        for (type, name) in wanted {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           name as CFString, &id) == kIOReturnSuccess {
                awakeAssertions.append(id)
            }
        }
    }

    private func releaseAwakeAssertions() {
        for id in awakeAssertions { IOPMAssertionRelease(id) }
        awakeAssertions = []
    }

    // Pitido que se repite mientras falte una pieza: la banda sonora de
    // «para de presentar y mira el mando», que es exactamente su función.
    private func scheduleFailureAlert() {
        guard Self.wantFailureSound, !alertScheduled else { return }
        alertScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self else { return }
            self.alertScheduled = false
            guard self.phase == .recording || self.phase == .paused,
                  !self.missingPieces.isEmpty else { return }
            NSSound(named: "Basso")?.play()
            self.scheduleFailureAlert()
        }
    }

    // Un segmento de pantalla empezó a escribir de verdad (el primero o una
    // recuperación): apuntar su instante para el montaje y avisar si venía
    // de un corte.
    func noteScreenSegmentStarted() {
        noteFirstFrame("pantalla")
        screenSegmentStarts.append((currentScreenFile, Date()))
        if missingPieces.contains("pantalla") {
            missingPieces.removeAll { $0 == "pantalla" }
            lastError = "Pantalla recuperada (parte \(screenSegment)): hubo un corte."
            status = "Grabando (pantalla recuperada)"
        }
    }

    // MARK: - Copias solo-audio

    // El audio SIEMPRE viaja embebido en los .mov (silenciarlo es cosa de la
    // mezcla, nada se pierde). Con la opción activada, además se extraen
    // copias sueltas: el micrófono de la webcam y el sonido del sistema de la
    // pantalla, listos para usar donde sea sin abrir el editor.
    private func extractAudioCopies() {
        guard Self.wantAudioCopies, let folder = lastFolder else { return }
        // TODAS las partes de cada pieza, no solo la primera: tras un corte
        // el audio vive repartido entre los .parteN.mov.
        //   camara-X.mov        → audio-webcam-X.m4a
        //   camara-X.parte2.mov → audio-webcam-X.parte2.m4a
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        let mapping: [(srcPrefix: String, dstPrefix: String)] = [
            ("camara-", "audio-webcam-"), ("pantalla-", "audio-sistema-"),
        ]
        var jobs: [(source: URL, output: URL)] = []
        for m in mapping {
            for src in files where src.lastPathComponent.hasPrefix(m.srcPrefix)
                    && src.pathExtension.lowercased() == "mov" {
                let base = src.deletingPathExtension().lastPathComponent
                    .dropFirst(m.srcPrefix.count)
                jobs.append((src, folder.appendingPathComponent("\(m.dstPrefix)\(base).m4a")))
            }
        }
        for job in jobs {
            let src = job.source
            let dst = job.output
            Task.detached(priority: .utility) {
                let asset = AVURLAsset(url: src)
                guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
                      !tracks.isEmpty,
                      let session = AVAssetExportSession(asset: asset,
                                                         presetName: AVAssetExportPresetAppleM4A) else {
                    return
                }
                session.outputURL = dst
                session.outputFileType = .m4a
                session.exportAsynchronously { }
            }
        }
    }

    // MARK: - Utilidades

    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }
}

extension RecordingEngine: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in
            // Solo el output VIGENTE habla: el didFinish rezagado de un output
            // ya sustituido (reinicio tras congelación) disparaba una alarma
            // falsa imposible de apagar — pitido en bucle el resto de la toma.
            guard output === (cameraOutput as AVCaptureFileOutput?) else { return }
            if let cb = cameraDone {
                // Cierre pedido por stop(): camino normal.
                if let error { status = "Cámara: \(error.localizedDescription)" }
                cb(error == nil)
                cameraDone = nil
                return
            }
            // Nadie pidió cerrar este archivo: la cámara se cortó a mitad
            // de grabación (disco, límite del contenedor, dispositivo…).
            if let error { handleCameraFailure(error) }
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                                from connections: [AVCaptureConnection]) {
        Task { @MainActor in
            guard output === (cameraOutput as AVCaptureFileOutput?) else { return }
            noteFirstFrame("camara")
            cameraStalled = false
            cameraSegmentStarts.append((fileURL.lastPathComponent, Date()))
            if missingPieces.contains("cámara") {
                missingPieces.removeAll { $0 == "cámara" }
                lastError = "Cámara recuperada (parte \(cameraSegment)): hubo un corte."
                status = "Grabando (cámara recuperada)"
            }
            startPendingScreen()   // la cámara ya escribe: pantalla, ahora
        }
    }
}

// Si la captura de pantalla se cae a mitad de la grabación, había que
// enterarse: antes moría en silencio y el vídeo quedaba truncado.
extension RecordingEngine: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in RecordingEngine.shared.handleScreenFailure(error) }
    }
}
