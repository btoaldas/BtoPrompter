import Foundation

// IA para subtítulos: TRADUCIR a los diez idiomas más hablados (SRT por
// idioma, listos para YouTube) y REFINAR el texto (puntuación, mayúsculas,
// cortes naturales) sin tocar los tiempos, que ya son reales. Usa el
// proveedor de IA que la app tiene configurado (mismo motor del Ensayo IA):
// nada sale del equipo sin la key y la elección del usuario.

enum SubtitleAI {

    // Los diez, en orden de hablantes. El código va al nombre del archivo:
    // video.en.srt, video.zh.srt…
    static let languages: [(code: String, name: String)] = [
        ("es", "Español"), ("en", "Inglés"), ("zh", "Chino mandarín"),
        ("hi", "Hindi"), ("fr", "Francés"), ("ar", "Árabe"),
        ("bn", "Bengalí"), ("pt", "Portugués"), ("ru", "Ruso"), ("ja", "Japonés"),
    ]

    struct ProviderConfig {
        let baseURL: String
        let apiKey: String
        let model: String

        // La configuración del Ensayo IA, tal como está en Ajustes.
        static func current() -> ProviderConfig? {
            let provider = Settings.string(.aiProvider, default: "groq")
            let base = provider == "custom"
                ? Settings.string(.aiBaseURL, default: "")
                : (AIRehearsal.providers.first(where: { $0.id == provider })?.baseURL ?? "")
            let key = SecretsStore.get("aiKey_\(provider)")
            let model = Settings.string(.aiModel, default: "llama-3.3-70b-versatile")
            guard !base.isEmpty, !key.isEmpty else { return nil }
            return ProviderConfig(baseURL: base, apiKey: key, model: model)
        }
    }

    // TRADUCIR: mismos bloques, mismos tiempos, solo cambia el texto.
    static func translate(_ chunks: [SubtitleChunk], to language: String,
                          config: ProviderConfig,
                          completion: @escaping (Result<[SubtitleChunk], Error>) -> Void) {
        let system = """
        Eres un traductor profesional de subtítulos. Recibes un array JSON de \
        textos y respondes SOLO con un array JSON de la MISMA longitud con cada \
        texto traducido al idioma pedido. Naturalidad de subtítulo: frases \
        cortas, registro hablado. Sin numeración, sin comentarios, sin markdown: \
        solo el array JSON.
        """
        let texts = chunks.map(\.text)
        guard let payload = try? JSONSerialization.data(withJSONObject: texts),
              let payloadText = String(data: payload, encoding: .utf8) else {
            completion(.failure(NSError(domain: "SubtitleAI", code: 1)))
            return
        }
        let user = "Idioma destino: \(language).\nTextos:\n\(payloadText)"
        AIRehearsal.request(system: system, user: user, baseURL: config.baseURL,
                            apiKey: config.apiKey, model: config.model,
                            temperature: 0.2) { result in
            completion(result.flatMap { raw in
                mapTexts(raw, onto: chunks)
            })
        }
    }

    // REFINAR: puntuación y mayúsculas correctas, cortes naturales; los
    // tiempos medidos no se tocan.
    static func refine(_ chunks: [SubtitleChunk], config: ProviderConfig,
                       completion: @escaping (Result<[SubtitleChunk], Error>) -> Void) {
        let system = """
        Corriges subtítulos generados automáticamente. Recibes un array JSON de \
        textos en su idioma original y respondes SOLO con un array JSON de la \
        MISMA longitud: cada texto con puntuación y mayúsculas correctas y \
        redacción natural de subtítulo, SIN cambiar el idioma ni el significado \
        ni añadir palabras nuevas. Solo el array JSON, nada más.
        """
        let texts = chunks.map(\.text)
        guard let payload = try? JSONSerialization.data(withJSONObject: texts),
              let payloadText = String(data: payload, encoding: .utf8) else {
            completion(.failure(NSError(domain: "SubtitleAI", code: 1)))
            return
        }
        AIRehearsal.request(system: system, user: payloadText, baseURL: config.baseURL,
                            apiKey: config.apiKey, model: config.model,
                            temperature: 0.1) { result in
            completion(result.flatMap { raw in
                mapTexts(raw, onto: chunks)
            })
        }
    }

    // La respuesta del modelo (array JSON de textos, quizá envuelto en ```)
    // se vuelve a casar con los tiempos originales. Longitud distinta = error
    // honesto, jamás subtítulos desalineados.
    static func mapTexts(_ raw: String, onto chunks: [SubtitleChunk])
        -> Result<[SubtitleChunk], Error> {
        var clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("```") {
            clean = clean
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Tolerar prosa alrededor: quedarse con el primer array JSON.
        if let start = clean.firstIndex(of: "["), let end = clean.lastIndex(of: "]") {
            clean = String(clean[start...end])
        }
        guard let data = clean.data(using: .utf8),
              let texts = try? JSONDecoder().decode([String].self, from: data) else {
            return .failure(NSError(domain: "SubtitleAI", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "La IA no devolvió un array JSON de textos"]))
        }
        guard texts.count == chunks.count else {
            return .failure(NSError(domain: "SubtitleAI", code: 3, userInfo: [
                NSLocalizedDescriptionKey:
                    "La IA devolvió \(texts.count) textos para \(chunks.count) bloques"]))
        }
        var result = chunks
        for i in result.indices {
            result[i].text = texts[i].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return .success(result)
    }
}
