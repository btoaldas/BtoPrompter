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

        // Marcas de diapositiva en guías.
        let t7 = ScriptParser.parse("// Diapositiva 2\nTexto normal.\n// mirar al público", guideTitles: true)
        expect(t7.first?.isSlideMark == true, "guía 'Diapositiva' detectada como marca")
        expect(t7.last?.isSlideMark == false, "guía normal no es marca de diapositiva")

        print(failures.isEmpty ? "SELFTEST OK" : "SELFTEST FALLÓ: \(failures.count)")
        return failures.isEmpty
    }
}
