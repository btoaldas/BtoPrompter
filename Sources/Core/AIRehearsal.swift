import Foundation

// Ensayo con IA: marca el ritmo del discurso (pausas, énfasis, velocidades por
// tramo) SIN cambiar ninguna palabra. Compatible con cualquier API estilo
// OpenAI (Groq, OpenAI, OpenRouter o servidor propio). Parametrizable y
// apagado por defecto. Para añadir un proveedor: una línea en `providers`.

struct AIRehearsal {
    struct Provider {
        let id: String
        let name: String
        let baseURL: String
        let defaultModel: String
    }

    static let providers: [Provider] = [
        Provider(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1",
                 defaultModel: "llama-3.3-70b-versatile"),
        Provider(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1",
                 defaultModel: "gpt-4o-mini"),
        Provider(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",
                 defaultModel: "openai/gpt-4o-mini"),
        Provider(id: "custom", name: "Personalizado", baseURL: "", defaultModel: ""),
    ]

    static let styles: [(id: String, name: String, hint: String)] = [
        ("conferencia", "Conferencia formal",
         "Ritmo sobrio y claro. Pausas marcadas entre ideas. Énfasis en cifras y conclusiones."),
        ("clase", "Clase / docencia",
         "Ritmo dinámico con preguntas retóricas al público. Baja la velocidad en definiciones y sube en ejemplos."),
        ("dictado", "Dictado",
         "Muy pausado: puntos suspensivos frecuentes para que la audiencia escriba. Repetir ritmo lento en datos clave."),
        ("motivacional", "Motivacional",
         "Enérgico: exclamaciones, subidas de velocidad en momentos altos y silencios dramáticos antes de frases clave."),
        ("personalizado", "Personalizado", ""),
    ]

    static func systemPrompt(styleID: String, customPrompt: String) -> String {
        let styleHint = styleID == "personalizado"
            ? customPrompt
            : (styles.first(where: { $0.id == styleID })?.hint ?? "")
        return """
        Eres un director de oratoria. Recibirás el texto de un discurso para un teleprompter.
        Tu trabajo es marcarle el RITMO para que suene natural y elocuente, como habla una persona real.

        REGLA ABSOLUTA: no cambies, añadas, quites ni reordenes NINGUNA palabra del discurso.
        Las palabras deben quedar idénticas y en el mismo orden. Solo puedes:

        1. Insertar puntos suspensivos pegados al final de una palabra ("palabra…") para crear pausas de respiración o de ritmo.
        2. Ajustar signos de puntuación (comas, ¡exclamaciones!, ¿preguntas?) sin tocar las palabras: eso cambia la entonación y las esperas.
        3. Insertar líneas nuevas que empiecen con "// " como guías de actuación que el orador ve pero no lee. Ejemplos: "// Aquí más enfático", "// Mirar al público", "// Silencio 2 segundos antes de seguir".
        4. Insertar marcas de velocidad al INICIO de una línea para ese tramo: [v+20] más rápido, [v-30] más lento, [v=] volver a velocidad normal. Valores entre 10 y 60. Úsalas cuando el contenido lo pida: fluido en historias, lento en datos, rápido en entusiasmo.
        5. Separar en párrafos donde ayude al ritmo (los saltos de línea no son palabras).

        Estilo solicitado: \(styleHint)

        Responde ÚNICAMENTE con el texto marcado. Sin explicaciones, sin comentarios, sin bloques de código.
        """
    }

    static func run(text: String, baseURL: String, apiKey: String, model: String,
                    styleID: String, customPrompt: String,
                    completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                                        .appending("/chat/completions")) else {
            completion(.failure(NSError(domain: "BtoPrompter", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "URL base inválida"])))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": systemPrompt(styleID: styleID, customPrompt: customPrompt)],
                ["role": "user", "content": text],
            ],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data else {
                completion(.failure(NSError(domain: "BtoPrompter", code: 2,
                                            userInfo: [NSLocalizedDescriptionKey: "Respuesta vacía"])))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                let detail = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
                completion(.failure(NSError(domain: "BtoPrompter", code: status,
                                            userInfo: [NSLocalizedDescriptionKey: "HTTP \(status): \(detail)"])))
                return
            }
            completion(.success(content.trimmingCharacters(in: .whitespacesAndNewlines)))
        }.resume()
    }
}
