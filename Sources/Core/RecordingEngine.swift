import AppKit
import AVFoundation
import Foundation
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

        if Self.wantCamera {
            ready.enter()
            prepareCamera { ok in
                if ok { pieces.append("cámara") }
                ready.leave()
            }
        }
        if Self.wantScreen {
            ready.enter()
            prepareScreen { ok in
                if ok { pieces.append("pantalla") }
                ready.leave()
            }
        }

        ready.notify(queue: .main) { [weak self] in
            guard let self else { return }
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
                    self?.startPendingScreen()
                }
            } else {
                self.pendingScreenURL = screenURL
                self.startPendingScreen()
            }
            // Lo que el usuario pidió y no salió: se dice, no se oculta tras
            // un «Grabando…» tranquilizador.
            var missing: [String] = []
            if wantedCamera, !pieces.contains("cámara") { missing.append("cámara") }
            if wantedScreen, !pieces.contains("pantalla") { missing.append("pantalla") }
            self.missingPieces = missing
            self.phase = .recording
            self.status = "Grabando " + pieces.sorted().joined(separator: " + ")
            if !missing.isEmpty {
                let falta = missing.joined(separator: " y ")
                self.lastError = "NO se está grabando: \(falta). "
                    + (self.lastError ?? "")
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
        guard firstFrameTimes.count > 1, let folder = lastFolder else { return }
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
        let group = DispatchGroup()

        if let out = cameraOutput, out.isRecording {
            group.enter()
            cameraDone = { _ in group.leave() }
            out.stopRecording()
        }
        if let stream = screenStream {
            group.enter()
            stream.stopCapture { _ in group.leave() }
        }
        writeSyncFile()
        group.notify(queue: .main) { [weak self] in
            self?.finishStop()
        }
    }

    private func finishStop() {
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

    private func prepareCamera(_ done: @escaping (Bool) -> Void) {
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
            done(false)
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
        guard session.canAddOutput(output) else {
            status = "No se pudo preparar la grabación de cámara"
            done(false)
            return
        }
        session.addOutput(output)
        cameraSession = session
        cameraOutput = output
        // Centinela de fotogramas: "lista" = imagen fluyendo, no solo isRunning.
        let sentinelOutput = AVCaptureVideoDataOutput()
        sentinelOutput.alwaysDiscardsLateVideoFrames = true
        let watcher = FrameSentinel()
        var finished = false
        watcher.onFirstFrame = { [weak self] in
            guard !finished else { return }
            finished = true
            self?.sentinel = nil
            done(true)
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
                done(session.isRunning)
            }
        }
    }

    // MARK: - Pantalla

    // Deja la captura corriendo SIN escribir; la escritura llega después.
    private func prepareScreen(_ done: @escaping (Bool) -> Void) {
        // El permiso se comprueba ANTES: sin él, la captura fallaba y la
        // grabación seguía solo con cámara sin que nadie se enterara.
        guard CGPreflightScreenCaptureAccess() else {
            lastError = "Falta el permiso de Grabación de pantalla. "
                + "Actívalo en Ajustes del Sistema → Privacidad y seguridad → "
                + "Grabación de pantalla, y reinicia BtoPrompter."
            CGRequestScreenCaptureAccess()
            done(false)
            return
        }
        guard #available(macOS 15.0, *) else {
            status = "Grabar la pantalla necesita macOS 15 o superior (la cámara sí funciona)"
            done(false)
            return
        }
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                                   onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    status = "No se encontró la pantalla"
                    lastError = "No se encontró ninguna pantalla que grabar"
                    done(false)
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
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
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
                screenStream = stream
                done(true)
            } catch {
                status = "Pantalla: \(error.localizedDescription)"
                lastError = "La pantalla no se pudo preparar: \(error.localizedDescription)"
                done(false)
            }
        }
    }

    // La captura ya corre: añadir la salida de archivo empieza a escribir ya.
    private func startScreenWriting(to url: URL) {
        guard let stream = screenStream else { return }
        guard #available(macOS 15.0, *) else { return }
        do {
            let recConfig = SCRecordingOutputConfiguration()
            recConfig.outputURL = url
            recConfig.outputFileType = .mov
            let recording = SCRecordingOutput(configuration: recConfig, delegate: self)
            try stream.addRecordingOutput(recording)
            screenOutput = recording
        } catch {
            status = "Pantalla: \(error.localizedDescription)"
            lastError = "La pantalla NO se está grabando: \(error.localizedDescription)"
            missingPieces.append("pantalla")
            screenStream?.stopCapture { _ in }
            screenStream = nil
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
        screenStream = nil
        screenOutput = nil
        if !missingPieces.contains("pantalla") { missingPieces.append("pantalla") }
        lastError = "La captura de pantalla se cortó: \(error.localizedDescription)"
        status = lastError
    }

    // MARK: - Copias solo-audio

    // El audio SIEMPRE viaja embebido en los .mov (silenciarlo es cosa de la
    // mezcla, nada se pierde). Con la opción activada, además se extraen
    // copias sueltas: el micrófono de la webcam y el sonido del sistema de la
    // pantalla, listos para usar donde sea sin abrir el editor.
    private func extractAudioCopies() {
        guard Self.wantAudioCopies, let folder = lastFolder else { return }
        let stamp = folder.lastPathComponent
        let jobs: [(source: String, output: String)] = [
            ("camara-\(stamp).mov", "audio-webcam-\(stamp).m4a"),
            ("pantalla-\(stamp).mov", "audio-sistema-\(stamp).m4a"),
        ]
        for job in jobs {
            let src = folder.appendingPathComponent(job.source)
            let dst = folder.appendingPathComponent(job.output)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
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
            if let error {
                status = "Cámara: \(error.localizedDescription)"
            }
            cameraDone?(error == nil)
            cameraDone = nil
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                                from connections: [AVCaptureConnection]) {
        Task { @MainActor in
            noteFirstFrame("camara")
            startPendingScreen()   // la cámara ya escribe: pantalla, ahora
        }
    }
}

@available(macOS 15.0, *)
extension RecordingEngine: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in noteFirstFrame("pantalla") }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput,
                                     didFailWithError error: Error) {
        Task { @MainActor in RecordingEngine.shared.handleScreenFailure(error) }
    }
}

// Si la captura de pantalla se cae a mitad de la grabación, había que
// enterarse: antes moría en silencio y el vídeo quedaba truncado.
extension RecordingEngine: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in RecordingEngine.shared.handleScreenFailure(error) }
    }
}
