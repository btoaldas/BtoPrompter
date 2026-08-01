import AppKit
import Foundation
import Network
import Security

// Control remoto desde el teléfono: mini servidor HTTP en la red local con una
// página de botones grandes (play/pausa, velocidad, saltos). Protegido con un
// token aleatorio en la URL. Apagado por defecto; solo escucha en la LAN.
final class RemoteControl: ObservableObject {
    static let shared = RemoteControl()

    @Published var running = false
    @Published var status: String? = nil

    private var listener: NWListener?
    // Teléfonos escuchando el karaoke. Reciben la posición sin tener que
    // preguntar, por una conexión que se queda abierta.
    private var mirrorClients: [NWConnection] = []
    private let mirrorLock = NSLock()

    var port: Int {
        get { Settings.int(.remotePort, default: 8737) }
        set { Settings.set(newValue, .remotePort) }
    }

    // Código de acceso de 128 bits. Los 32 bits de antes eran adivinables por
    // fuerza bruta en una red compartida, y ahora por aquí viaja el discurso
    // entero, no solo órdenes de play y pausa.
    var token: String {
        let stored = Settings.string(.remoteToken, default: "")
        if stored.count >= 32 { return stored }
        let fresh = Self.newToken()
        Settings.set(fresh, .remoteToken)
        return fresh
    }

    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // Renueva el código: invalida al instante cualquier dispositivo conectado.
    func regenerateToken() {
        Settings.set(Self.newToken(), .remoteToken)
        objectWillChange.send()
    }

    // Comparación en tiempo constante: comparar con == permite adivinar el
    // código midiendo cuánto tarda en responder.
    private func tokenMatches(_ candidate: String) -> Bool {
        let a = Array(candidate.utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
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
        closeMirrorClients()
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

            // El canal del karaoke no se cierra: queda abierto recibiendo la
            // posición. El resto de rutas responden y cierran, como siempre.
            if let comps = URLComponents(string: path), comps.path == "/events" {
                let given = comps.queryItems?.first(where: { $0.name == "t" })?.value ?? ""
                guard self.tokenMatches(given) else {
                    conn.send(content: self.httpResponse(status: "403 Forbidden",
                                                         body: "código inválido", type: "text/plain"),
                              completion: .contentProcessed { _ in conn.cancel() })
                    return
                }
                self.beginMirrorStream(conn)
                return
            }

            let response = self.route(path)
            conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    // Abre el canal de eventos con un teléfono y le manda el estado actual.
    private func beginMirrorStream(_ conn: NWConnection) {
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream; charset=utf-8\r
        Cache-Control: no-store\r
        Connection: keep-alive\r
        \r

        """
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        mirrorLock.lock()
        mirrorClients.append(conn)
        mirrorLock.unlock()
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.dropMirrorClient(conn)
            default: break
            }
        }
        sendToMirror(conn, event: RemoteMirror.stateJSON())
    }

    private func dropMirrorClient(_ conn: NWConnection) {
        mirrorLock.lock()
        mirrorClients.removeAll { $0 === conn }
        mirrorLock.unlock()
    }

    private func sendToMirror(_ conn: NWConnection, event: String) {
        let frame = "data: " + event + "\n\n"
        conn.send(content: Data(frame.utf8), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.dropMirrorClient(conn) }
        })
    }

    // Atajo seguro para llamar desde cualquier didSet del motor.
    func broadcastIfRunning() {
        guard running else { return }
        broadcastState()
    }

    // Avisa a todos los teléfonos conectados. Se llama al cambiar de palabra.
    func broadcastState() {
        mirrorLock.lock()
        let clients = mirrorClients
        mirrorLock.unlock()
        guard !clients.isEmpty else { return }
        let payload = RemoteMirror.stateJSON()
        for c in clients { sendToMirror(c, event: payload) }
    }

    private func closeMirrorClients() {
        mirrorLock.lock()
        let clients = mirrorClients
        mirrorClients = []
        mirrorLock.unlock()
        for c in clients { c.cancel() }
    }

    private func route(_ path: String) -> Data {
        let comps = URLComponents(string: path)
        let query = comps?.queryItems ?? []
        let t = query.first(where: { $0.name == "t" })?.value ?? ""
        guard tokenMatches(t) else {
            return httpResponse(status: "403 Forbidden", body: "código inválido", type: "text/plain")
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
        case "/script":
            return httpResponse(status: "200 OK", body: RemoteMirror.scriptJSON(),
                                type: "application/json")
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
        case "reframe":
            (NSApp.delegate as? AppDelegate)?.resetWindowFrame()
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
        #guionbar{display:flex;gap:5px;justify-content:center;margin-bottom:8px;flex-wrap:wrap}
        button.mini{font-size:13px;padding:9px 11px;border:none;border-radius:9px;background:#2c2c2e;color:#fff;font-weight:600}
        #wrap{height:68vh;overflow:hidden;position:relative;text-align:left;background:#000;border-radius:12px;padding:10px}
        #script{position:absolute;left:10px;right:10px;transition:transform .25s ease-out;font-size:26px;line-height:1.5;font-weight:600}
        #script.mir{transform-origin:center;}
        .w{color:#fff}.done{color:#ffffff52}.now{color:#ffd60a;text-decoration:underline}
        .guide{color:#74c7ff;font-style:italic;display:block;margin:6px 0}
        .h1{font-size:1.35em;font-weight:800;display:block;margin:8px 0}
        .h2{font-size:1.15em;font-weight:800;display:block;margin:6px 0}
        #warn{font-size:11px;color:#8e8e93;margin-top:8px}
        </style></head><body>
        <h1>BtoPrompter</h1>
        <div class="tabs">
          <button id="t1" class="on" onclick="tab(1)">Teleprompter</button>
          <button id="t2" onclick="tab(2)">Ordenador</button>
          <button id="t3" onclick="tab(3)">Guion</button>
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
            <button class="k" onclick="cmd('reframe')">Encuadrar</button>
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

        <div id="p3" class="hide">
          <div id="guionbar">
            <button class="mini" onclick="cmd('toggle')">&#9199;</button>
            <button class="mini" onclick="fs(-2)">A-</button>
            <button class="mini" onclick="fs(2)">A+</button>
            <button class="mini" onclick="mirror()">Espejo</button>
            <button class="mini" onclick="cmd('back10')">-10</button>
            <button class="mini" onclick="cmd('fwd10')">+10</button>
          </div>
          <div id="wrap"><div id="script"></div></div>
          <div id="warn">Para que la pantalla no se apague: Ajustes &rarr; Pantalla y brillo &rarr; Bloqueo autom&aacute;tico &rarr; Nunca</div>
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
          for(let k=1;k<=3;k++){
            document.getElementById('p'+k).className = n===k?'':'hide';
            document.getElementById('t'+k).className = n===k?'on':'';
          }
          if(n===3) loadScript();
        }

        // ---- Guion con karaoke ----
        let SC=null, SPANS=[], LAST=-1, FS=26, MIR=false, REV=-1;
        function fs(d){FS=Math.max(14,Math.min(64,FS+d));
          document.getElementById('script').style.fontSize=FS+'px'; paint(LAST,true);}
        function mirror(){MIR=!MIR;
          document.getElementById('script').style.transform=
            (MIR?'scaleX(-1) ':'')+'translateY('+CURY+'px)';}
        let CURY=0;
        async function loadScript(){
          try{
            const r=await fetch('/script?t='+T); SC=await r.json();
            const box=document.getElementById('script');
            box.innerHTML=''; SPANS=[];
            for(const c of SC.chunks){
              if(c.guide){
                const g=document.createElement('span');
                g.className='guide'; g.textContent='\u{25B8} '+c.text; box.appendChild(g);
                continue;
              }
              const line=document.createElement('span');
              line.className = c.style==='h1'?'h1':(c.style==='h2'?'h2':'');
              c.words.forEach((w,k)=>{
                const s=document.createElement('span');
                s.className='w'; s.textContent=w+' ';
                SPANS[c.from+k]=s; line.appendChild(s);
              });
              box.appendChild(line);
              if(c.style==='normal'||c.style==='bullet') box.appendChild(document.createTextNode(' '));
            }
            LAST=-1; paint(0,true);
          }catch(e){ document.getElementById('script').textContent='No se pudo cargar el guion'; }
        }
        function paint(i,force){
          if(!SPANS.length||i==null) return;
          if(i===LAST&&!force) return;
          if(LAST>=0&&SPANS[LAST]) SPANS[LAST].className='w done';
          for(let k=0;k<i;k++) if(SPANS[k]) SPANS[k].className='w done';
          for(let k=i+1;k<SPANS.length;k++) if(SPANS[k]&&SPANS[k].className!=='w') SPANS[k].className='w';
          const cur=SPANS[i];
          if(cur){
            cur.className='w now';
            const wrap=document.getElementById('wrap');
            CURY = wrap.clientHeight/2 - cur.offsetTop - cur.offsetHeight/2;
            document.getElementById('script').style.transform=
              (MIR?'scaleX(-1) ':'')+'translateY('+CURY+'px)';
          }
          LAST=i;
        }

        // ---- Canal en vivo: la posición llega sola ----
        let ES=null;
        function connect(){
          if(ES) ES.close();
          ES=new EventSource('/events?t='+T);
          ES.onmessage=function(ev){
            try{
              const s=JSON.parse(ev.data);
              if(SC && s.rev!==undefined && REV!==-1 && s.rev!==REV){ loadScript(); }
              if(s.rev!==undefined) REV=s.rev;
              paint(s.i);
              show(s);
            }catch(e){}
          };
          ES.onerror=function(){ setTimeout(connect,2000); };
        }
        function show(s){
          document.getElementById('st').textContent =
            (s.mode==='prompter'?(s.playing?'Leyendo ':'En pausa ')+(s.i+1)+'/'+s.total+' \u{00B7} '+s.wpm+' ppm':'En el editor')
            + (s.voice?' \u{00B7} micro ON':'');
          const mb=document.getElementById('mic'); if(mb) mb.style.background = s.voice? '#30d158' : '#2c2c2e';
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
        connect();
        </script></body></html>
        """
    }
}
