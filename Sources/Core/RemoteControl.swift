import AppKit
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
        case "/input":
            // Control del ordenador: solo si está autorizado explícitamente.
            guard RemoteInput.enabled else {
                return httpResponse(status: "403 Forbidden",
                                    body: "control del ordenador desactivado", type: "text/plain")
            }
            guard RemoteInput.isTrusted else {
                return httpResponse(status: "428 Precondition Required",
                                    body: "falta permiso de Accesibilidad en el Mac", type: "text/plain")
            }
            let kind = query.first(where: { $0.name == "do" })?.value ?? ""
            let value = query.first(where: { $0.name == "v" })?.value ?? ""
            let dx = Double(query.first(where: { $0.name == "dx" })?.value ?? "") ?? 0
            let dy = Double(query.first(where: { $0.name == "dy" })?.value ?? "") ?? 0
            // El sentido vertical es preferencia del usuario: hay quien espera
            // que el dedo arrastre el contenido y quien espera que mueva el cursor.
            let pointerSign: Double = Settings.bool(.remoteInvertPointer, default: false) ? -1 : 1
            let scrollSign: Double = Settings.bool(.remoteInvertScroll, default: false) ? -1 : 1
            DispatchQueue.main.async {
                switch kind {
                case "key": RemoteInput.key(value)
                case "click": RemoteInput.click(value.isEmpty ? "left" : value)
                case "dblclick": RemoteInput.click("left", double: true)
                case "move": RemoteInput.movePointer(dx: dx, dy: dy * pointerSign)
                case "scroll": RemoteInput.scroll(dx: Int(dx), dy: Int(dy * scrollSign))
                case "type": RemoteInput.type(value)
                default: break
                }
            }
            return httpResponse(status: "200 OK", body: "ok", type: "text/plain")
        case "/status":
            let m = PrompterModel.shared
            var json = ""
            DispatchQueue.main.sync {
                json = """
                {"playing": \(m.isPlaying), "index": \(m.currentIndex), "total": \(m.totalWords), "wpm": \(m.wpm), "voice": \(m.voiceActive), "mode": "\(m.mode == .prompting ? "prompter" : "editor")"}
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
        case "start":
            // Trae la ventana al frente aunque estuviera minimizada o detrás.
            NSApp.activate(ignoringOtherApps: true)
            if let w = NSApp.windows.first {
                if w.isMiniaturized { w.deminiaturize(nil) }
                w.makeKeyAndOrderFront(nil)
            }
            if m.mode == .editing { m.startPrompter() }
        case "mic": m.voiceFollow.toggle()
        case "mini": m.toggleMiniMode()
        case "opacityup": m.changeOpacity(+0.1)
        case "opacitydown": m.changeOpacity(-0.1)
        case "hide":
            if let w = NSApp.windows.first { w.miniaturize(nil) }
        case "show":
            NSApp.activate(ignoringOtherApps: true)
            if let w = NSApp.windows.first {
                if w.isMiniaturized { w.deminiaturize(nil) }
                w.makeKeyAndOrderFront(nil)
            }
        default: break
        }
    }

    private func httpResponse(status: String, body: String, type: String) -> Data {
        let bytes = Array(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + Data(bytes)
    }

    // Página de control: dos pestañas —el teleprompter y el ordenador—,
    // con botones grandes, trackpad y teclado. Oscura y sin dependencias.
    private static func page(token: String) -> String {
        """
        <!doctype html><html lang="es"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">
        <title>BtoPrompter</title><style>
        *{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
        body{background:#111;color:#fff;font-family:-apple-system,sans-serif;margin:0;padding:10px;text-align:center}
        h1{color:#ffd60a;font-size:17px;margin:4px 0 10px}
        .tabs{display:flex;gap:6px;margin-bottom:10px}
        .tabs button{flex:1;font-size:14px;padding:10px 4px;border:none;border-radius:10px;background:#2c2c2e;color:#8e8e93;font-weight:600}
        .tabs button.on{background:#ffd60a;color:#000}
        .grid{display:grid;grid-template-columns:1fr 1fr;gap:8px;max-width:460px;margin:0 auto}
        .g3{display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px;max-width:460px;margin:0 auto}
        button.k{font-size:17px;padding:15px 4px;border:none;border-radius:12px;background:#2c2c2e;color:#fff;font-weight:600}
        button.k:active{background:#48484a}
        .big{grid-column:1/3;background:#ffd60a;color:#000;font-size:22px;padding:20px 4px}
        .wide{grid-column:1/4}
        #pad{max-width:460px;margin:10px auto;height:190px;background:#1c1c1e;border:1px dashed #48484a;border-radius:14px;
             display:flex;align-items:center;justify-content:center;color:#636366;font-size:13px;touch-action:none}
        #st{color:#8e8e93;font-size:12px;margin-top:10px;min-height:16px}
        .hide{display:none}
        input{width:100%;padding:12px;border-radius:10px;border:1px solid #48484a;background:#1c1c1e;color:#fff;font-size:15px}
        </style></head><body>
        <h1>BtoPrompter</h1>
        <div class="tabs">
          <button id="t1" class="on" onclick="tab(1)">Teleprompter</button>
          <button id="t2" onclick="tab(2)">Ordenador</button>
        </div>

        <div id="p1">
          <div class="grid">
            <button class="k" onclick="cmd('start')">Iniciar</button>
            <button class="k" onclick="cmd('show')">Traer al frente</button>
            <button class="k big" onclick="cmd('toggle')">Play / Pausa</button>
            <button class="k" onclick="cmd('slower')">Mas lento</button>
            <button class="k" onclick="cmd('faster')">Mas rapido</button>
            <button class="k" onclick="cmd('back10')">-10</button>
            <button class="k" onclick="cmd('fwd10')">+10</button>
            <button class="k" onclick="cmd('back1')">-1</button>
            <button class="k" onclick="cmd('fwd1')">+1</button>
            <button class="k" onclick="cmd('reset')">Reiniciar</button>
            <button class="k" onclick="cmd('mic')" id="mic">Microfono</button>
            <button class="k" onclick="cmd('mini')">Modo mini</button>
            <button class="k" onclick="cmd('hide')">Minimizar</button>
            <button class="k" onclick="cmd('opacitydown')">Mas transparente</button>
            <button class="k" onclick="cmd('opacityup')">Menos transparente</button>
          </div>
        </div>

        <div id="p2" class="hide">
          <div class="g3">
            <button class="k" onclick="key('left')">&#8592;</button>
            <button class="k" onclick="key('up')">&#8593;</button>
            <button class="k" onclick="key('right')">&#8594;</button>
            <button class="k" onclick="key('pageup')">Pag -</button>
            <button class="k" onclick="key('down')">&#8595;</button>
            <button class="k" onclick="key('pagedown')">Pag +</button>
            <button class="k" onclick="key('space')">Espacio</button>
            <button class="k" onclick="key('escape')">Esc</button>
            <button class="k" onclick="key('return')">Enter</button>
          </div>
          <div id="pad">Desliza para mover · toca para clic · dos dedos para desplazar</div>
          <div class="g3">
            <button class="k" onclick="input('click','left')">Clic</button>
            <button class="k" onclick="input('dblclick','')">Doble</button>
            <button class="k" onclick="input('click','right')">Clic der.</button>
          </div>
          <div class="g3" style="margin-top:8px">
            <div class="wide"><input id="txt" placeholder="Escribir en el Mac"></div>
            <button class="k wide" onclick="sendText()">Enviar texto</button>
          </div>
        </div>

        <div id="st">&mdash;</div>
        <script>
        const T='\(token)';
        function cmd(a){fetch('/cmd?t='+T+'&do='+a)}
        function key(k){send('key',k)}
        function input(k,v){send(k,v)}
        function send(k,v,dx,dy){
          let u='/input?t='+T+'&do='+k+'&v='+encodeURIComponent(v||'');
          if(dx!==undefined) u+='&dx='+dx+'&dy='+dy;
          fetch(u).then(r=>{if(r.status===403) note('Activa el control del ordenador en el Mac');
                            else if(r.status===428) note('Falta permiso de Accesibilidad en el Mac')});
        }
        function sendText(){const e=document.getElementById('txt');if(e.value){send('type',e.value);e.value=''}}
        function note(m){document.getElementById('st').textContent=m}
        function tab(n){
          document.getElementById('p1').className = n===1?'':'hide';
          document.getElementById('p2').className = n===2?'':'hide';
          document.getElementById('t1').className = n===1?'on':'';
          document.getElementById('t2').className = n===2?'on':'';
        }
        (function(){
          const pad=document.getElementById('pad');
          let lx=0,ly=0,moved=0,fingers=0,t0=0;
          pad.addEventListener('touchstart',function(e){
            const t=e.touches[0]; lx=t.clientX; ly=t.clientY; moved=0; fingers=e.touches.length; t0=Date.now();
            e.preventDefault();
          },{passive:false});
          pad.addEventListener('touchmove',function(e){
            const t=e.touches[0]; const dx=t.clientX-lx, dy=t.clientY-ly;
            lx=t.clientX; ly=t.clientY; moved+=Math.abs(dx)+Math.abs(dy);
            if(e.touches.length>1) send('scroll','',Math.round(-dx),Math.round(-dy));
            else send('move','',Math.round(dx*1.8),Math.round(dy*1.8));
            e.preventDefault();
          },{passive:false});
          pad.addEventListener('touchend',function(e){
            if(moved<8 && fingers===1 && Date.now()-t0<350) input('click','left');
            e.preventDefault();
          },{passive:false});
        })();
        async function poll(){try{const r=await fetch('/status?t='+T);const s=await r.json();
        document.getElementById('st').textContent=(s.mode==='prompter'?(s.playing?'Leyendo ':'En pausa ')+s.index+'/'+s.total+' · '+s.wpm+' ppm':'En el editor')+(s.voice?' · micro ON':'');
        const mb=document.getElementById('mic'); if(mb) mb.style.background = s.voice? '#30d158' : '#2c2c2e';
        }catch(e){}}
        setInterval(poll,1500);poll();
        </script></body></html>
        """
    }
}
