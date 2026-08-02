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

        // Capas: visibilidad por tiempo y saneo.
        var capa = ExtraLayer(kind: .image, path: "/tmp/x.png", name: "x")
        expect(capa.isVisible(at: 0) && capa.isVisible(at: 99),
               "capa sin intervalos se ve siempre")
        capa.appearances = [LayerAppearance(from: 1, to: 3), LayerAppearance(from: 5, to: 6)]
        expect(capa.isVisible(at: 2) && !capa.isVisible(at: 4) && capa.isVisible(at: 5.5),
               "capa con intervalos aparece y desaparece")
        expect(!capa.isVisible(at: 3), "el intervalo es [desde, hasta): en el corte ya no se ve")
        expect(capa.firstAppearance == 1, "el vídeo de la capa arranca en su primera aparición")
        capa.appearances = [LayerAppearance(from: -2, to: 99), LayerAppearance(from: 4, to: 2)]
        let capaS = capa.sanitized(duration: 10)
        expect(capaS.appearances.count == 1 && capaS.appearances[0].from == 0
               && capaS.appearances[0].to == 10,
               "saneo de capas recorta al vídeo y tira intervalos invertidos")
        // Un project.json de la versión anterior (sin capas) carga sin fallar.
        let v1JSON = #"{"cuts":[2],"duration":8,"layouts":[{"mode":"overlay","camRect":{"x":0.7,"y":0.6,"width":0.25,"height":0.34},"shape":"circle","borderWidth":0.01,"splitRatio":0.5,"camera":{"fit":"fill","crop":{"x":0,"y":0,"width":1,"height":1}},"screen":{"fit":"fill","crop":{"x":0,"y":0,"width":1,"height":1}}},{"mode":"sideBySide","camRect":{"x":0.7,"y":0.6,"width":0.25,"height":0.34},"shape":"rounded","borderWidth":0.01,"splitRatio":0.3,"camera":{"fit":"fill","crop":{"x":0,"y":0,"width":1,"height":1}},"screen":{"fit":"fill","crop":{"x":0,"y":0,"width":1,"height":1}}}],"background":{"color":{"_0":{"r":0.1,"g":0.1,"b":0.1,"a":1}}}}"#
        if let old = try? JSONDecoder().decode(VideoProject.self, from: Data(v1JSON.utf8)) {
            expect(old.cuts == [2] && old.extraLayers.isEmpty && old.cameraOverridePath == nil,
                   "project.json v1 carga con capas vacías")
        } else {
            expect(false, "project.json v1 carga con capas vacías")
        }

        // Orden de capas por tramo: cada corte con su propio arriba/abajo.
        var zp = VideoProject()
        zp.duration = 10
        _ = zp.addCut(at: 5)
        let cA = ExtraLayer(kind: .image, path: "/tmp/a.png", name: "A")
        let cB = ExtraLayer(kind: .image, path: "/tmp/b.png", name: "B")
        zp.extraLayers = [cA, cB]
        expect(zp.orderedLayers(at: 2).map(\.name) == ["A", "B"],
               "sin orden propio rige el global")
        zp.setLayerPosition(cA.id, to: 1, inSegment: 1)
        expect(zp.orderedLayers(at: 7).map(\.name) == ["B", "A"],
               "el tramo 2 invierte el orden")
        expect(zp.orderedLayers(at: 2).map(\.name) == ["A", "B"],
               "el tramo 1 conserva el global")
        let cC = ExtraLayer(kind: .image, path: "/tmp/c.png", name: "C")
        zp.extraLayers.append(cC)
        expect(zp.orderedLayers(at: 7).map(\.name) == ["B", "A", "C"],
               "capa nueva entra al final del orden del tramo")
        zp.extraLayers.removeFirst()   // muere A
        let zps = zp.sanitized()
        expect(zps.layouts[1].layerOrder?.contains(cA.id) != true,
               "el saneo limpia ids muertos del orden del tramo")

        // Subtítulos: palabras con tiempo → frases; y el parser SRT.
        typealias TW = SubtitleBuilder.TimedWord
        let habla = [TW(w: "Hola", t: 0.0), TW(w: "a", t: 0.4), TW(w: "todos.", t: 0.8),
                     TW(w: "Hoy", t: 3.5), TW(w: "presentamos", t: 4.0), TW(w: "esto", t: 4.4)]
        let frases = SubtitleBuilder.group(habla)
        expect(frases.count == 2, "el punto cierra la primera frase")
        expect(frases[0].text == "Hola a todos." && frases[0].from == 0.0,
               "la frase junta sus palabras con su tiempo")
        expect(frases[0].to <= frases[1].from, "las frases no se solapan")
        expect(frases[1].from == 3.5, "la pausa larga abre frase nueva")
        let muchos = (0..<20).map { TW(w: "p\($0)", t: Double($0) * 0.3) }
        expect(SubtitleBuilder.group(muchos).allSatisfy {
            $0.text.split(separator: " ").count <= 8
        }, "ninguna frase pasa de ocho palabras")

        let srt = """
        1
        00:00:01,500 --> 00:00:04,000
        Primera frase
        del subtítulo

        2
        00:00:05,000 --> 00:00:07,250
        Segunda frase
        """
        let parsed = SubtitleBuilder.parseSRT(srt)
        expect(parsed.count == 2, "dos bloques SRT")
        expect(parsed[0].from == 1.5 && parsed[0].to == 4.0
               && parsed[0].text == "Primera frase del subtítulo",
               "tiempos y texto multilínea del SRT")
        expect(parsed[1].to == 7.25, "milisegundos con coma bien leídos")
        expect(SubtitleBuilder.parseSRT("basura sin bloques").isEmpty,
               "SRT inválido devuelve vacío sin reventar")

        // Presets: los placeholders no arrastran rutas de otros proyectos.
        let realLayers = [ExtraLayer(kind: .video, path: "/Users/x/privado.mov", name: "mío"),
                          ExtraLayer(kind: .image, path: "/tmp/logo.png", name: "logo")]
        let demos = VideoPresetStore.placeholdered(realLayers)
        expect(demos.allSatisfy { VideoPresetStore.isPlaceholder($0) },
               "las plantillas guardan demo N, jamás rutas reales")
        expect(!demos.contains { $0.path.contains("privado") },
               "ninguna ruta original sobrevive en el preset")
        var lib = VideoPresetLibrary()
        lib.templates.append(ProjectTemplate(name: "t", cuts: [2], layouts: [SegmentLayout()],
                                             layers: demos, background: .default,
                                             subtitleStyle: SubtitleStyle()))
        if let data = try? JSONEncoder().encode(lib),
           let back = try? JSONDecoder().decode(VideoPresetLibrary.self, from: data) {
            expect(back == lib, "la biblioteca de presets sobrevive al viaje por JSON")
        } else {
            expect(false, "la biblioteca de presets sobrevive al viaje por JSON")
        }

        // SRT de ida y vuelta, y el casado de textos de la IA.
        let outSRT = SubtitleBuilder.toSRT([
            SubtitleChunk(from: 0.1, to: 2.5, text: "Hola mundo"),
            SubtitleChunk(from: 3, to: 5.25, text: "Segunda frase"),
        ])
        let reparsed = SubtitleBuilder.parseSRT(outSRT)
        expect(reparsed.count == 2 && reparsed[1].to == 5.25
               && reparsed[0].text == "Hola mundo",
               "el SRT generado se vuelve a leer intacto")
        let baseChunks = [SubtitleChunk(from: 0, to: 2, text: "uno"),
                          SubtitleChunk(from: 2, to: 4, text: "dos")]
        if case .success(let mapped) = SubtitleAI.mapTexts(
            "```json\n[\"one\", \"two\"]\n```", onto: baseChunks) {
            expect(mapped[0].text == "one" && mapped[0].from == 0 && mapped[1].to == 4,
                   "la traducción conserva los tiempos y limpia el markdown")
        } else {
            expect(false, "la traducción conserva los tiempos y limpia el markdown")
        }
        if case .failure = SubtitleAI.mapTexts("[\"solo uno\"]", onto: baseChunks) {
            expect(true, "longitud distinta = error honesto, no subtítulos corridos")
        } else {
            expect(false, "longitud distinta = error honesto, no subtítulos corridos")
        }

        // Alineación de las piezas de una grabación: el que arrancó ANTES es
        // el que tiene metraje de sobra, no al revés (ese era el fallo que
        // dejaba la voz, la imagen y el escritorio cada uno por su lado).
        let d1 = CompositionBuilder.alignmentDelays(
            offsets: ["camara": 0, "pantalla": 0.3])
        expect(d1["camara"] == 0.3 && d1["pantalla"] == 0,
               "el que arrancó antes se salta la diferencia; el último no se toca")
        let d2 = CompositionBuilder.alignmentDelays(
            offsets: ["camara": 2.0, "pantalla": 0.5, "voz": 0])
        expect(d2["voz"] == 2.0 && d2["pantalla"] == 1.5 && d2["camara"] == 0,
               "con tres piezas todas se alinean al arranque más tardío")
        expect(CompositionBuilder.alignmentDelays(offsets: ["camara": 1.2]) == ["camara": 0],
               "una sola pieza no se recorta")
        expect(CompositionBuilder.alignmentDelays(offsets: [:]).isEmpty,
               "sin piezas no hay nada que alinear")

        // Rampa del zoom: el acercamiento va del encuadre completo al recorte.
        let destino = SourceCrop(x: 0.3, y: 0.2, width: 0.4, height: 0.4)
        let inicio = destino.ramped(progress: 0)
        expect(inicio.x == 0 && inicio.width == 1 && inicio.height == 1,
               "al empezar la rampa se ve el fotograma entero")
        let medio = destino.ramped(progress: 0.5)
        expect(abs(medio.width - 0.7) < 0.001 && abs(medio.x - 0.15) < 0.001,
               "a mitad de rampa el encuadre va a medio camino")
        expect(destino.ramped(progress: 1) == destino,
               "al terminar la rampa manda el recorte elegido")
        expect(destino.ramped(progress: 2) == destino, "el progreso se recorta a 1")

        // Cancelación de audio: el retardo se encuentra por correlación.
        // El ruido es PSEUDOaleatorio con semilla fija: con Float.random la
        // prueba pasaba casi siempre y fallaba de vez en cuando, que es la
        // peor clase de prueba — nadie sabe si el fallo es real.
        var semilla: UInt64 = 12345
        let siguiente: () -> Float = {
            semilla = semilla &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: Int(semilla >> 33))) / Float(Int32.max)
        }
        let ruido = (0..<8000).map { _ in siguiente() * 0.5 }
        var eco = [Float](repeating: 0, count: 8000)
        let retardoReal = 1600
        for i in retardoReal..<8000 { eco[i] = ruido[i - retardoReal] * 0.7 }
        let detectado = AudioEchoRemover.estimateDelay(mic: eco, reference: ruido)
        expect(abs(detectado - retardoReal) <= 64,
               "el retardo entre el sistema y el micrófono se encuentra solo")
        let limpio = AudioEchoRemover.nlms(mic: eco, reference: ruido, delay: detectado)
        func nivel(_ s: [Float]) -> Float {
            let mitad = Array(s[(s.count / 2)...])
            return sqrtf(mitad.reduce(0) { $0 + $1 * $1 } / Float(mitad.count))
        }
        expect(nivel(limpio) < nivel(eco) * 0.5,
               "el filtro resta al menos la mitad del eco cuando puede seguirlo")
        expect(limpio.allSatisfy { $0.isFinite },
               "el filtro nunca escupe valores rotos (era NaN antes del arreglo)")
        let solaVoz = (0..<4000).map { _ in siguiente() * 0.3 }
        let sinReferencia = AudioEchoRemover.nlms(
            mic: solaVoz, reference: [Float](repeating: 0, count: 4000), delay: 0)
        expect(abs(nivel(sinReferencia) - nivel(solaVoz)) < 0.02,
               "sin sonido del sistema la voz sale intacta")

        // Cursor resaltado: la posición se interpola entre muestras.
        var cur = CursorHighlight()
        cur.points = [[0, 0.0, 0.0], [1, 1.0, 0.5], [2, 0.5, 1.0]]
        expect(cur.position(at: 0)?.x == 0, "en el primer instante manda la primera muestra")
        if let mid = cur.position(at: 0.5) {
            expect(abs(mid.x - 0.5) < 0.01 && abs(mid.y - 0.25) < 0.01,
                   "entre dos muestras el halo va a medio camino")
        } else {
            expect(false, "entre dos muestras el halo va a medio camino")
        }
        expect(cur.position(at: 99)?.y == 1.0, "pasado el final se queda en la última")
        expect(CursorHighlight().position(at: 1) == nil, "sin recorrido no hay halo")
        var salvaje = CursorHighlight()
        salvaje.radius = 9; salvaje.ringWidth = -1
        expect(salvaje.sanitized().radius <= 0.2 && salvaje.sanitized().ringWidth >= 0,
               "el tamaño del halo se mantiene en lo razonable")

        // Teclas en pantalla: el atajo se ve el tiempo que dura y luego se va.
        var teclas = KeystrokeOverlay()
        teclas.seconds = 1.5
        teclas.events = [["1.00", "⌘S"], ["5.00", "⌥⇧F"]]
        expect(teclas.label(at: 1.2) == "⌘S", "el atajo se ve mientras dura")
        expect(teclas.label(at: 3.0) == nil, "pasado su tiempo desaparece")
        expect(teclas.label(at: 0.5) == nil, "antes de pulsarlo no hay nada")
        expect(teclas.label(at: 5.4) == "⌥⇧F", "el siguiente atajo llega a su hora")

        // Silencios: los huecos largos entre frases, con margen.
        let conHuecos = [SubtitleChunk(from: 2.0, to: 4.0, text: "hola"),
                         SubtitleChunk(from: 9.0, to: 11.0, text: "adiós")]
        let huecos = SubtitleBuilder.silences(in: conHuecos, duration: 15)
        expect(huecos.count == 3, "silencio al principio, en medio y al final")
        expect(huecos[1].from > 4.0 && huecos[1].to < 9.0,
               "el hueco deja margen para no cortar la respiración")
        let seguidas = [SubtitleChunk(from: 0, to: 2, text: "a"),
                        SubtitleChunk(from: 2.2, to: 4, text: "b")]
        expect(SubtitleBuilder.silences(in: seguidas, duration: 4).isEmpty,
               "hablando seguido no hay silencios que quitar")

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
