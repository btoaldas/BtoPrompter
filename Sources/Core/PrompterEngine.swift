import AppKit
import Combine
import Foundation
import IOKit.pwr_mgt

// Motor del prompter: estado global, transporte (play/pausa/saltos/velocidad),
// avance del karaoke y orquestación del Ensayo con IA.
// La UI observa este modelo; la persistencia vive en Storage/.

final class PrompterModel: ObservableObject {
    static let shared = PrompterModel()

    enum Mode { case editing, prompting }

    @Published var mode: Mode = .editing
    @Published var selectedID: UUID? {
        didSet { Settings.set(selectedID?.uuidString ?? "", .selectedID) }
    }
    @Published var chunks: [Chunk] = []
    @Published var currentIndex: Int = 0
    @Published var isPlaying: Bool = false
    @Published var wpm: Int {
        didSet { Settings.set(wpm, .wpm) }
    }
    @Published var fontSize: CGFloat {
        didSet { Settings.set(fontSize, .fontSize) }
    }
    @Published var bgOpacity: Double {
        didSet { Settings.set(bgOpacity, .bgOpacity) }
    }
    // Modo espía: la ventana no aparece en capturas ni pantalla compartida.
    @Published var spyMode: Bool {
        didSet { Settings.set(spyMode, .spyMode) }
    }
    // Títulos (#, ##) como guías visibles que el karaoke no lee.
    @Published var guideTitles: Bool {
        didSet { Settings.set(guideTitles, .guideTitles) }
    }
    // Modo minimalista: barra delgada arriba de la pantalla, karaoke en ≤2 líneas.
    @Published var miniMode: Bool {
        didSet { Settings.set(miniMode, .miniMode) }
    }
    @Published var miniFontSize: CGFloat {
        didSet { Settings.set(miniFontSize, .miniFontSize) }
    }
    // Ancho disponible para el texto del modo mini; lo publica AppDelegate al
    // aplicar el layout (evita medir geometría desde la vista, con sus races).
    @Published var miniContentWidth: CGFloat = 0

    // Cuenta regresiva antes de reproducir (0 = arrancar de inmediato).
    @Published var countdownSeconds: Int {
        didSet { Settings.set(countdownSeconds, .countdownSeconds) }
    }
    // Reproducir automáticamente al entrar al prompter.
    @Published var autoPlay: Bool {
        didSet { Settings.set(autoPlay, .autoPlay) }
    }
    // Segundos restantes de la cuenta regresiva en curso (nil = sin conteo).
    @Published var countdown: Int? = nil
    private var countdownWork: DispatchWorkItem?

    // Evitar que la pantalla se apague mientras el prompter está activo.
    @Published var keepAwake: Bool {
        didSet {
            Settings.set(keepAwake, .keepAwake)
            updateSleepAssertion()
        }
    }
    // Color del resaltado del karaoke (palabra actual).
    @Published var accentColorID: String {
        didSet { Settings.set(accentColorID, .accentColorID) }
    }
    private var sleepAssertion: IOPMAssertionID = 0

    // Ensayo con IA (parametrizable, apagado por defecto).
    @Published var aiEnabled: Bool {
        didSet { Settings.set(aiEnabled, .aiEnabled) }
    }
    @Published var aiProvider: String {
        didSet { Settings.set(aiProvider, .aiProvider) }
    }
    @Published var aiModel: String {
        didSet { Settings.set(aiModel, .aiModel) }
    }
    @Published var aiBaseURL: String {
        didSet { Settings.set(aiBaseURL, .aiBaseURL) }
    }
    @Published var aiStyle: String {
        didSet { Settings.set(aiStyle, .aiStyle) }
    }
    @Published var aiCustomPrompt: String {
        didSet { Settings.set(aiCustomPrompt, .aiCustomPrompt) }
    }
    @Published var aiStatus: String? = nil
    @Published var aiBusy: Bool = false
    @Published var showSettings: Bool = false

    private var pendingWork: DispatchWorkItem?

    private init() {
        wpm = Settings.int(.wpm, default: 130)
        fontSize = CGFloat(Settings.double(.fontSize, default: 34))
        bgOpacity = Settings.double(.bgOpacity, default: 0.85)
        var spy = Settings.bool(.spyMode, default: true)
        if CommandLine.arguments.contains("--capturable") { spy = false }
        spyMode = spy
        guideTitles = Settings.bool(.guideTitles, default: true)
        miniMode = Settings.bool(.miniMode, default: false)
        miniFontSize = CGFloat(Settings.double(.miniFontSize, default: 20))
        countdownSeconds = Settings.int(.countdownSeconds, default: 3)
        autoPlay = Settings.bool(.autoPlay, default: false)
        keepAwake = Settings.bool(.keepAwake, default: true)
        accentColorID = Settings.string(.accentColorID, default: "amarillo")
        aiEnabled = Settings.bool(.aiEnabled, default: false)
        aiProvider = Settings.string(.aiProvider, default: "groq")
        aiModel = Settings.string(.aiModel, default: "llama-3.3-70b-versatile")
        aiBaseURL = Settings.string(.aiBaseURL, default: "")
        aiStyle = Settings.string(.aiStyle, default: "conferencia")
        aiCustomPrompt = Settings.string(.aiCustomPrompt, default: "")
        let saved = Settings.string(.selectedID, default: "")
        if let uuid = UUID(uuidString: saved) { selectedID = uuid }
    }

    // MARK: Derivados

    var totalWords: Int { chunks.last?.range.upperBound ?? 0 }

    var currentChunkID: Int? { chunkAt(currentIndex)?.id }

    func chunkAt(_ index: Int) -> Chunk? {
        chunks.first(where: { $0.range.contains(index) })
    }

    var remainingTimeText: String {
        guard totalWords > 0 else { return "--:--" }
        let remaining = max(0, totalWords - currentIndex)
        let seconds = Int(Double(remaining) / Double(wpm) * 60.0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func wordAt(_ index: Int) -> String {
        guard let chunk = chunkAt(index) else { return "" }
        return chunk.words[index - chunk.range.lowerBound]
    }

    // MARK: Transporte

    func startPrompter() {
        guard let doc = SpeechStore.shared.speech(selectedID) else { return }
        chunks = ScriptParser.parse(doc.body, guideTitles: guideTitles)
        guard totalWords > 0 else { return }
        currentIndex = 0
        isPlaying = false
        mode = .prompting
        NSApp.keyWindow?.makeFirstResponder(nil)
        GlobalHotKeys.shared.register()
        updateSleepAssertion()
        if autoPlay { play() }
    }

    func backToEditor() {
        pause()
        mode = .editing
        GlobalHotKeys.shared.unregister()
        updateSleepAssertion()
    }

    // MARK: Pantalla despierta

    func updateSleepAssertion() {
        let shouldHold = keepAwake && mode == .prompting
        if shouldHold && sleepAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "BtoPrompter presentando" as CFString,
                                        &sleepAssertion)
        } else if !shouldHold && sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }

    // MARK: Marcadores: saltar a la n-ésima sección (títulos # / ##)

    func jumpToSection(_ n: Int) {
        let sections = chunks.filter { $0.style == .h1 || $0.style == .h2 }
        guard n >= 1, n <= sections.count else { return }
        let section = sections[n - 1]
        if !section.isGuide {
            jump(to: section.range.lowerBound)
            return
        }
        // La sección es guía (no leíble): saltar al primer chunk leíble posterior.
        if let next = chunks.first(where: { $0.id > section.id && !$0.isGuide }) {
            jump(to: next.range.lowerBound)
        }
    }

    func play() {
        guard mode == .prompting, totalWords > 0, countdown == nil else { return }
        if currentIndex >= totalWords - 1 { currentIndex = 0 }
        if countdownSeconds > 0 {
            countdown = countdownSeconds
            tickCountdown()
        } else {
            isPlaying = true
            scheduleNext()
        }
    }

    private func tickCountdown() {
        guard let current = countdown else { return }
        if current <= 0 {
            countdown = nil
            isPlaying = true
            scheduleNext()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.countdown != nil else { return }
            self.countdown = (self.countdown ?? 1) - 1
            self.tickCountdown()
        }
        countdownWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func pause() {
        isPlaying = false
        pendingWork?.cancel()
        pendingWork = nil
        countdownWork?.cancel()
        countdownWork = nil
        countdown = nil
    }

    func togglePlay() {
        if isPlaying || countdown != nil { pause() } else { play() }
    }

    func reset() {
        pause()
        currentIndex = 0
    }

    func skip(_ delta: Int) {
        guard totalWords > 0 else { return }
        currentIndex = min(max(0, currentIndex + delta), totalWords - 1)
        if isPlaying { reschedule() }
    }

    func jump(to index: Int) {
        guard totalWords > 0 else { return }
        currentIndex = min(max(0, index), totalWords - 1)
        if isPlaying { reschedule() }
    }

    func changeSpeed(_ delta: Int) {
        let r = Settings.Limits.wpmRange
        wpm = min(max(r.lowerBound, wpm + delta), r.upperBound)
        if isPlaying { reschedule() }
    }

    func changeFont(_ delta: CGFloat) {
        if miniMode && mode == .prompting {
            let r = Settings.Limits.miniFontRange
            miniFontSize = min(max(r.lowerBound, miniFontSize + delta), r.upperBound)
        } else {
            let r = Settings.Limits.fontRange
            fontSize = min(max(r.lowerBound, fontSize + delta), r.upperBound)
        }
    }

    func toggleMiniMode() {
        miniMode.toggle()
    }

    func changeOpacity(_ delta: Double) {
        bgOpacity = min(max(0.0, bgOpacity + delta), 1.0)
    }

    private func reschedule() {
        pendingWork?.cancel()
        scheduleNext()
    }

    private func scheduleNext() {
        guard isPlaying, currentIndex < totalWords - 1 else {
            if currentIndex >= totalWords - 1 { isPlaying = false }
            return
        }
        let limits = Settings.Limits.self
        let effectiveWpm = min(max(limits.wpmRange.lowerBound,
                                   wpm + (chunkAt(currentIndex)?.speedDelta ?? 0)),
                               limits.wpmRange.upperBound)
        let base = 60.0 / Double(effectiveWpm)
        var multiplier = 1.0
        if let last = wordAt(currentIndex).last {
            if limits.sentenceEnders.contains(last) { multiplier = limits.sentencePauseMultiplier }
            else if limits.commaEnders.contains(last) { multiplier = limits.commaPauseMultiplier }
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isPlaying else { return }
            self.currentIndex += 1
            self.scheduleNext()
        }
        pendingWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + base * multiplier, execute: item)
    }

    // MARK: Teclado local (solo en modo prompter)

    func handleKey(_ event: NSEvent) -> Bool {
        guard mode == .prompting, !event.modifierFlags.contains(.command) else { return false }
        let fine = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 49: togglePlay(); return true          // espacio
        case 123: skip(fine ? -1 : -10); return true    // ← (⇧: palabra a palabra)
        case 124: skip(fine ? +1 : +10); return true    // → (⇧: palabra a palabra)
        case 126: changeSpeed(+Settings.Limits.wpmStep); return true   // ↑
        case 125: changeSpeed(-Settings.Limits.wpmStep); return true   // ↓
        case 53: backToEditor(); return true        // esc
        default: break
        }
        let chars = event.charactersIgnoringModifiers?.lowercased()
        if let c = chars, c.count == 1, let d = Int(c), d >= 1 {
            jumpToSection(d)
            return true
        }
        switch chars {
        case "r": reset(); return true
        case "m": toggleMiniMode(); return true
        case "+", "=": changeFont(+Settings.Limits.fontStep); return true
        case "-": changeFont(-Settings.Limits.fontStep); return true
        case "[": changeOpacity(-0.1); return true
        case "]": changeOpacity(+0.1); return true
        default: return false
        }
    }

    // MARK: Ensayo con IA

    // Una key por proveedor: cambiar de proveedor no borra las demás.
    func aiKey(for provider: String) -> String {
        SecretsStore.get("aiKey_\(provider)")
    }
    func setAIKey(_ key: String, for provider: String) {
        SecretsStore.set(key, for: "aiKey_\(provider)")
    }

    var aiEffectiveBaseURL: String {
        if aiProvider == "custom" { return aiBaseURL }
        return AIRehearsal.providers.first(where: { $0.id == aiProvider })?.baseURL ?? ""
    }

    func runAIRehearsal() {
        guard let doc = SpeechStore.shared.speech(selectedID) else { return }
        let key = aiKey(for: aiProvider)
        guard !key.isEmpty, !aiEffectiveBaseURL.isEmpty, !aiModel.isEmpty else {
            aiStatus = "Configura proveedor, modelo y API key."
            return
        }
        aiBusy = true
        aiStatus = "Marcando ritmo con IA…"
        AIRehearsal.run(text: doc.body, baseURL: aiEffectiveBaseURL, apiKey: key,
                        model: aiModel, styleID: aiStyle, customPrompt: aiCustomPrompt) { result in
            DispatchQueue.main.async {
                self.aiBusy = false
                switch result {
                case .success(let marked):
                    let store = SpeechStore.shared
                    let doc2 = store.newSpeech(title: doc.title + " (ensayo IA)",
                                               body: marked, folder: doc.folder)
                    self.selectedID = doc2.id
                    self.aiStatus = "✓ Listo: se creó el discurso marcado"
                case .failure(let error):
                    self.aiStatus = "Error: \(error.localizedDescription)"
                }
            }
        }
    }
}
