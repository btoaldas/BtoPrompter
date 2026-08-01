import Foundation
import Network

// Control remoto desde el teléfono: mini servidor HTTP en la red local con una
// página de botones grandes (play/pausa, velocidad, saltos). Protegido con un
// token aleatorio en la URL. Apagado por defecto; solo escucha en la LAN.
final class RemoteControl: ObservableObject {
    static let shared = RemoteControl()

    @Published var running = false
    @Published var status: String? = nil

    private var listener: NWListener?

    var port: Int {
        get { Settings.int(.remotePort, default: 8737) }
        set { Settings.set(newValue, .remotePort) }
    }

    var token: String {
        var t = Settings.string(.remoteToken, default: "")
        if t.isEmpty {
            t = String(UUID().uuidString.prefix(8)).lowercased()
            Settings.set(t, .remoteToken)
        }
        return t
    }

    // IP local (en0 típico en portátiles; recorre interfaces si no).
    var localIP: String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if !ip.isEmpty && ip != "127.0.0.1" {
                if name == "en0" { return ip }
                if address == nil { address = ip }
            }
        }
        return address
    }

    var url: String? {
        guard let ip = localIP else { return nil }
        return "http://\(ip):\(port)/?t=\(token)"
    }

    func start() {
        guard listener == nil else { return }
        _ = token   // genera y persiste el token si aún no existe
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(integerLiteral: UInt16(port)))
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.running = true
                        self?.status = nil
                    case .failed(let error):
                        self?.running = false
                        self?.status = "Servidor falló: \(error.localizedDescription)"
                        self?.listener = nil
                    default: break
                    }
                }
            }
            l.start(queue: .global(qos: .userInitiated))
            listener = l
        } catch {
            status = "No se pudo abrir el puerto \(port): \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            let firstLine = request.split(separator: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            let path = parts.count > 1 ? String(parts[1]) : "/"
            let response = self.route(path)
            conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    private func route(_ path: String) -> Data {
        let comps = URLComponents(string: path)
        let query = comps?.queryItems ?? []
        let t = query.first(where: { $0.name == "t" })?.value ?? ""
        guard t == token else {
            return httpResponse(status: "403 Forbidden", body: "token inválido", type: "text/plain")
        }
        let route = comps?.path ?? "/"
        switch route {
        case "/":
            return httpResponse(status: "200 OK", body: Self.page(token: token), type: "text/html; charset=utf-8")
        case "/cmd":
            let action = query.first(where: { $0.name == "do" })?.value ?? ""
            DispatchQueue.main.async { Self.perform(action) }
            return httpResponse(status: "200 OK", body: "ok", type: "text/plain")
        case "/status":
            let m = PrompterModel.shared
            var json = ""
            DispatchQueue.main.sync {
                json = """
                {"playing": \(m.isPlaying), "index": \(m.currentIndex), "total": \(m.totalWords), "wpm": \(m.wpm), "mode": "\(m.mode == .prompting ? "prompter" : "editor")"}
                """
            }
            return httpResponse(status: "200 OK", body: json, type: "application/json")
        default:
            return httpResponse(status: "404 Not Found", body: "no existe", type: "text/plain")
        }
    }

    private static func perform(_ action: String) {
        let m = PrompterModel.shared
        switch action {
        case "toggle": m.togglePlay()
        case "play": m.play()
        case "pause": m.pause()
        case "faster": m.changeSpeed(+Settings.Limits.wpmStep)
        case "slower": m.changeSpeed(-Settings.Limits.wpmStep)
        case "back1": m.skip(-1)
        case "fwd1": m.skip(+1)
        case "back10": m.skip(-10)
        case "fwd10": m.skip(+10)
        case "reset": m.reset()
        case "start": if m.mode == .editing { m.startPrompter() }
        default: break
        }
    }

    private func httpResponse(status: String, body: String, type: String) -> Data {
        let bytes = Array(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + Data(bytes)
    }

    // Página de control: botones grandes, oscura, sin dependencias.
    private static func page(token: String) -> String {
        """
        <!doctype html><html lang="es"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">
        <title>BtoPrompter</title><style>
        body{background:#111;color:#fff;font-family:-apple-system,sans-serif;margin:0;padding:16px;text-align:center}
        h1{color:#ffd60a;font-size:20px;margin:8px 0 16px}
        .grid{display:grid;grid-template-columns:1fr 1fr;gap:12px;max-width:420px;margin:0 auto}
        button{font-size:22px;padding:22px 8px;border:none;border-radius:14px;background:#2c2c2e;color:#fff;font-weight:700}
        button:active{background:#48484a}
        .big{grid-column:1/3;background:#ffd60a;color:#000;font-size:28px;padding:28px 8px}
        #st{color:#8e8e93;font-size:13px;margin-top:14px}
        </style></head><body>
        <h1>🎤 BtoPrompter</h1>
        <div class="grid">
        <button class="big" onclick="cmd('toggle')">⏯ Play / Pausa</button>
        <button onclick="cmd('slower')">🐢 Más lento</button>
        <button onclick="cmd('faster')">🐇 Más rápido</button>
        <button onclick="cmd('back10')">⏪ −10</button>
        <button onclick="cmd('fwd10')">⏩ +10</button>
        <button onclick="cmd('back1')">◀︎ −1</button>
        <button onclick="cmd('fwd1')">▶︎ +1</button>
        <button onclick="cmd('reset')">🔄 Reiniciar</button>
        <button onclick="cmd('start')">🎬 Iniciar</button>
        </div>
        <div id="st">—</div>
        <script>
        const T='\(token)';
        function cmd(a){fetch('/cmd?t='+T+'&do='+a)}
        async function poll(){try{const r=await fetch('/status?t='+T);const s=await r.json();
        document.getElementById('st').textContent=(s.mode==='prompter'?(s.playing?'▶︎ Leyendo ':'⏸ En pausa ')+s.index+'/'+s.total+' · '+s.wpm+' ppm':'En el editor');}catch(e){}}
        setInterval(poll,1500);poll();
        </script></body></html>
        """
    }
}
