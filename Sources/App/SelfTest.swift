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
        expect(VoiceMatcher.findPosition(heard: ["presentarles"], script: script, current: 4) == 6,
               "palabra única distintiva")
        expect(VoiceMatcher.findPosition(heard: ["a"], script: script, current: 0) == nil,
               "palabra única corta no dispara")

        print(failures.isEmpty ? "SELFTEST OK" : "SELFTEST FALLÓ: \(failures.count)")
        return failures.isEmpty
    }
}
