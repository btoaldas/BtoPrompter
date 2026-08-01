import AppKit
import Foundation

// Pruebas rápidas del parser, sin frameworks: `BtoPrompter --selftest`.
// Se ejecutan antes de arrancar la UI y salen con código 0/1.

enum SelfTest {
    static func run() -> Bool {
        var failures: [String] = []

        func expect(_ cond: Bool, _ name: String) {
            if !cond { failures.append(name) }
            print("\(cond ? "✓" : "✗") \(name)")
        }

        // Texto normal: oraciones separadas, todas las palabras cuentan.
        let t1 = ScriptParser.parse("Hola a todos. Esto es una prueba.", guideTitles: true)
        expect(t1.count == 2, "dos oraciones → dos chunks")
        expect(t1.last?.range.upperBound == 7, "siete palabras leíbles")

        // Guías: // nunca se lee; títulos según el parámetro.
        let t2 = ScriptParser.parse("// Diapositiva 1\n# Título\nTexto real aquí.", guideTitles: true)
        expect(t2.filter(\.isGuide).count == 2, "guía // y título como guía")
        expect(t2.last?.range.upperBound == 3, "solo el texto real cuenta palabras")

        let t3 = ScriptParser.parse("# Título\nTexto.", guideTitles: false)
        expect(t3.filter(\.isGuide).isEmpty, "con guideTitles=false el título se lee")
        expect(t3.last?.range.upperBound == 2, "título leído suma sus palabras")

        // Marcas de velocidad: afectan al tramo y desaparecen del texto.
        let t4 = ScriptParser.parse("[v+20] Rápido aquí.\n[v=] Normal otra vez.", guideTitles: true)
        expect(t4.first?.speedDelta == 20, "marca [v+20] aplicada")
        expect(t4.last?.speedDelta == 0, "marca [v=] resetea")
        expect(!(t4.first?.words.first?.contains("[v") ?? true), "la marca no aparece como palabra")

        // Viñetas y limpieza de marcadores inline.
        let t5 = ScriptParser.parse("- Punto **importante**", guideTitles: true)
        expect(t5.first?.style == .bullet, "viñeta detectada")
        expect(t5.first?.words.contains("importante") == true, "negrita limpiada")

        // Clamp de deltas fuera de rango.
        let t6 = ScriptParser.parse("[v+99] Texto.", guideTitles: true)
        expect((t6.first?.speedDelta ?? 0) <= Settings.Limits.speedDeltaRange.upperBound,
               "delta fuera de rango se recorta")

        // Seguimiento por voz: normalizador y matcher.
        expect(VoiceMatcher.normalize("¡Tecnológica!") == "tecnologica", "normaliza tildes y signos")
        let script = "buenas tardes a todos hoy quiero presentarles el avance del proyecto"
            .split(separator: " ").map(String.init)
        expect(VoiceMatcher.findPosition(heard: ["Buenas", "tardes,", "a"], script: script, current: 0) == 2,
               "match de 3 palabras al inicio")
        expect(VoiceMatcher.findPosition(heard: ["blabla", "el", "avance"], script: script, current: 2) == 8,
               "salto adelante dentro de la ventana")
        expect(VoiceMatcher.findPosition(heard: ["improvisando", "cosas", "raras"], script: script, current: 3) == nil,
               "sin match espera (improvisación)")
        expect(VoiceMatcher.findPosition(heard: ["presentarles"], script: script, current: 4) == nil,
               "una palabra sola no mueve el guion")
        expect(VoiceMatcher.findPosition(heard: ["a"], script: script, current: 0) == nil,
               "palabra única corta no dispara")
        expect(VoiceMatcher.findPosition(heard: ["quiero", "presentarle", "el"],
                                         script: script, current: 4) == 7,
               "tolera un error pequeño del reconocedor")

        // Frases repetidas: nunca adivina cuál aparición quiso decir el orador.
        let repeated = "inicio tema comun para todos cierre primero pausa inicio tema comun para todos cierre segundo"
            .split(separator: " ").map(String.init)
        let guardrail = VoiceAlignmentGuard()
        guardrail.reset(at: 0)
        let repeated1 = guardrail.evaluate(text: "inicio tema común para todos", isFinal: false,
                                           script: repeated, current: 0,
                                           maxJump: 30, sensitivity: 0.72,
                                           confirmLargeJumps: true)
        expect(repeated1.kind == .ambiguous, "frase repetida espera contexto único")
        let repeated2 = guardrail.evaluate(text: "inicio tema común para todos", isFinal: false,
                                           script: repeated, current: 0,
                                           maxJump: 30, sensitivity: 0.72,
                                           confirmLargeJumps: true)
        expect(repeated2.kind == .ignored, "parcial duplicado no cuenta como confirmación")
        let repeated3 = guardrail.evaluate(text: "inicio tema común para todos cierre primero",
                                           isFinal: false, script: repeated, current: 0,
                                           maxJump: 30, sensitivity: 0.72,
                                           confirmLargeJumps: true)
        expect(repeated3.kind == .pending, "salto grande único pide evidencia progresiva")
        let repeated4 = guardrail.evaluate(text: "inicio tema común para todos cierre primero pausa",
                                           isFinal: false, script: repeated, current: 0,
                                           maxJump: 30, sensitivity: 0.72,
                                           confirmLargeJumps: true)
        expect(repeated4.kind == .advanced && repeated4.to == 8,
               "contexto creciente confirma sin saltar a la segunda aparición")
        guardrail.reset(at: 13)
        let backward = guardrail.evaluate(text: "inicio tema común para todos cierre primero",
                                          isFinal: true, script: repeated, current: 13,
                                          maxJump: 30, sensitivity: 0.72,
                                          confirmLargeJumps: true)
        expect(backward.kind != .advanced, "el seguidor jamás retrocede")

        let farScript = "uno dos tres cuatro cinco seis siete ocho nueve diez ahora cambiamos al cierre final"
            .split(separator: " ").map(String.init)
        guardrail.reset(at: 0)
        let far1 = guardrail.evaluate(text: "ahora cambiamos", isFinal: false,
                                      script: farScript, current: 0, maxJump: 30,
                                      sensitivity: 0.72, confirmLargeJumps: true)
        let farDuplicate = guardrail.evaluate(text: "ahora cambiamos", isFinal: false,
                                              script: farScript, current: 0, maxJump: 30,
                                              sensitivity: 0.72, confirmLargeJumps: true)
        let far2 = guardrail.evaluate(text: "ahora cambiamos al", isFinal: false,
                                      script: farScript, current: 0, maxJump: 30,
                                      sensitivity: 0.72, confirmLargeJumps: true)
        expect(far1.kind == .pending && farDuplicate.kind == .ignored && far2.kind == .advanced,
               "salto grande requiere dos parciales distintos")
        guardrail.reset(at: 0)
        let strongFinal = guardrail.evaluate(text: "ahora cambiamos al cierre", isFinal: true,
                                             script: farScript, current: 0, maxJump: 30,
                                             sensitivity: 0.72, confirmLargeJumps: true)
        expect(strongFinal.kind == .advanced && strongFinal.to == 14,
               "resultado final con cuatro palabras confirma el salto")

        // Proyecto de composición: tramos sin huecos, por construcción.
        var project = VideoProject()
        project.duration = 10
        expect(project.segmentIndex(at: 5) == 0, "sin cortes todo es el tramo 0")
        expect(project.addCut(at: 4) == 1, "cortar crea el tramo 1")
        expect(project.addCut(at: 7) == 2, "segundo corte crea el tramo 2")
        expect(project.layouts.count == 3 && project.cuts == [4, 7],
               "tres tramos, dos cortes ordenados")
        expect(project.segmentIndex(at: 3.9) == 0 && project.segmentIndex(at: 4.0) == 1
               && project.segmentIndex(at: 8) == 2, "cada instante cae en su tramo")
        expect(project.addCut(at: 4.05) == nil, "corte pegado a otro se rechaza")
        expect(project.addCut(at: 9.95) == nil, "corte pegado al final se rechaza")
        var beforeRemove = project
        beforeRemove.removeSegment(1)
        expect(beforeRemove.layouts.count == 2 && beforeRemove.cuts == [7],
               "borrar el tramo 1 lo fusiona con el 0")
        var removeFirst = project
        removeFirst.removeSegment(0)
        expect(removeFirst.layouts.count == 2 && removeFirst.cuts == [7],
               "borrar el primero lo fusiona con el siguiente")
        project.moveCut(0, to: 6.5)
        expect(project.cuts[0] == 6.5, "mover un corte dentro de su hueco")
        project.moveCut(0, to: 9)
        expect(project.cuts[0] < 7, "mover un corte no invade al vecino")
        // Cambiar el layout de un tramo no toca a los demás.
        var layoutEdit = project
        layoutEdit.layouts[1].mode = .sideBySide
        layoutEdit.layouts[1].splitRatio = 0.3
        expect(layoutEdit.layouts[0].mode == .overlay, "editar un tramo no contagia al resto")
        expect(layoutEdit.layouts[1].sanitized().splitRatio == 0.3, "reparto 30/70 se conserva")
        var wild = SegmentLayout()
        wild.splitRatio = 7
        wild.camRect = NRect(x: -3, y: 9, width: 0.001, height: 44)
        wild.camera.crop = SourceCrop(x: 5, y: -2, width: 0, height: 33)
        let tamed = wild.sanitized()
        expect(tamed.splitRatio == 0.8 && tamed.camRect.x >= 0 && tamed.camRect.width >= 0.06
               && tamed.camera.crop.width >= 0.05 && tamed.camera.crop.x <= 1,
               "valores salvajes quedan domesticados")
        // Ida y vuelta por JSON: el proyecto sobrevive intacto.
        if let data = try? JSONEncoder().encode(project),
           let back = try? JSONDecoder().decode(VideoProject.self, from: data) {
            expect(back == project, "el proyecto sobrevive al viaje por JSON")
        } else {
            expect(false, "el proyecto sobrevive al viaje por JSON")
        }
        var broken = project
        broken.layouts = [SegmentLayout()]   // invariante roto adrede
        expect(broken.sanitized().layouts.count == broken.sanitized().cuts.count + 1,
               "sanitized repara un project.json manipulado")
        // Regresión del blocker: cargar un proyecto ANTES de conocer la
        // duración (duration=0) jamás puede destruir los cortes guardados.
        var unknownDuration = project
        unknownDuration.duration = 0
        let survived = unknownDuration.sanitized()
        expect(survived.cuts.count == project.cuts.count
               && survived.layouts.count == project.layouts.count,
               "duración desconocida conserva cortes y tramos")

        let failover = VoiceProviderCatalog.configuredOrder(
            primary: .deepgram,
            rawFallbacks: "soniox,deepgram,apple_local",
            failover: true
        )
        expect(failover.prefix(3).elementsEqual([.deepgram, .soniox, .appleLocal]),
               "failover respeta prioridad y elimina duplicados")
        expect(VoiceProviderCatalog.configuredOrder(primary: .gladia,
                                                     rawFallbacks: "apple_local",
                                                     failover: false) == [.gladia],
               "failover desactivado usa solo el proveedor elegido")

        // El contexto extra (perfil del orador) debe llegar también a los
        // estilos predefinidos, no solo al personalizado.
        let perfil = "Perfil local del orador: 140 ppm."
        expect(AIRehearsal.systemPrompt(styleID: "conferencia", customPrompt: perfil).contains(perfil),
               "el perfil llega con estilo predefinido")
        expect(AIRehearsal.systemPrompt(styleID: "personalizado", customPrompt: perfil).contains(perfil),
               "el perfil llega con estilo personalizado")
        expect(AIRehearsal.systemPrompt(styleID: "conferencia", customPrompt: "").contains("sobrio"),
               "sin contexto extra el estilo predefinido se mantiene")

        // Marcas de diapositiva en guías.
        let t7 = ScriptParser.parse("// Diapositiva 2\nTexto normal.\n// mirar al público", guideTitles: true)
        expect(t7.first?.isSlideMark == true, "guía 'Diapositiva' detectada como marca")
        expect(t7.last?.isSlideMark == false, "guía normal no es marca de diapositiva")

        print(failures.isEmpty ? "SELFTEST OK" : "SELFTEST FALLÓ: \(failures.count)")
        return failures.isEmpty
    }

    // Comprobación de la invisibilidad al compartir pantalla. Se ejecuta con
    // `--test-sharing` y debe pasar antes de publicar cualquier versión: es la
    // seña de identidad de la app y un descuido la rompería en silencio.
    //
    // Levanta dos ventanas de color idéntico, una excluida de las capturas y
    // otra no, hace una captura del sistema y mira el píxel del centro de cada
    // una. La excluida debe mostrar el escritorio; la otra, su color.
    @MainActor
    static func runSharingCheck() -> Bool {
        let color = NSColor.systemPink
        func makeWindow(hidden: Bool, x: CGFloat) -> NSWindow {
            let w = NSWindow(contentRect: NSRect(x: x, y: 200, width: 220, height: 220),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            w.backgroundColor = color
            w.isOpaque = true
            w.level = .statusBar
            w.sharingType = hidden ? .none : .readOnly
            w.orderFrontRegardless()
            return w
        }
        let hiddenWindow = makeWindow(hidden: true, x: 100)
        let visibleWindow = makeWindow(hidden: false, x: 400)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            hiddenWindow.orderOut(nil)
            visibleWindow.orderOut(nil)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))

        guard let screen = NSScreen.main else { return false }

        // Se captura el rectángulo exacto de cada ventana, en coordenadas de
        // pantalla (origen arriba-izquierda), y se mira el color medio.
        func averageColor(of window: NSWindow) -> NSColor? {
            let f = window.frame
            let rect = CGRect(x: f.minX + 40, y: screen.frame.height - f.maxY + 40,
                              width: f.width - 80, height: f.height - 80)
            guard let img = CGWindowListCreateImage(rect, .optionAll, kCGNullWindowID,
                                                    [.bestResolution]) else { return nil }
            let bitmap = NSBitmapImageRep(cgImage: img)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
            var samples = 0
            for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 8)) {
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 8)) {
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    r += c.redComponent; g += c.greenComponent; b += c.blueComponent
                    samples += 1
                }
            }
            guard samples > 0 else { return nil }
            return NSColor(deviceRed: r / CGFloat(samples), green: g / CGFloat(samples),
                           blue: b / CGFloat(samples), alpha: 1)
        }
        func isPink(_ c: NSColor?) -> Bool {
            guard let c, let ref = color.usingColorSpace(.deviceRGB) else { return false }
            return abs(c.redComponent - ref.redComponent) < 0.2
                && abs(c.greenComponent - ref.greenComponent) < 0.2
                && abs(c.blueComponent - ref.blueComponent) < 0.2
        }

        let hiddenColor = averageColor(of: hiddenWindow)
        let visibleColor = averageColor(of: visibleWindow)
        let hiddenPink = isPink(hiddenColor)
        let visiblePink = isPink(visibleColor)
        print(hiddenPink ? "✗ la ventana invisible SÍ salió en la captura"
                         : "✓ la ventana invisible no aparece en la captura")
        print(visiblePink ? "✓ la ventana de control sí aparece (la captura funciona)"
                          : "✗ la ventana de control no apareció: la captura no es fiable")
        let ok = !hiddenPink && visiblePink
        print(ok ? "INVISIBILIDAD OK" : "INVISIBILIDAD FALLÓ")
        return ok
    }
}
