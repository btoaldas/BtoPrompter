import AppKit
import AVFoundation
import SwiftUI

// La previsualización VIVA: los componentes se tocan sobre el vídeo mismo.
// Clic selecciona, arrastrar mueve, los tiradores de las esquinas cambian el
// tamaño y el clic derecho da el orden (al frente, atrás, detrás de la
// cámara, quitar). El panel de la derecha sigue existiendo para el ajuste
// fino; esto es para organizar con las manos.
//
// Geometría: el lienzo es SIEMPRE 16:9 (1920×1080). El overlay calcula el
// rectángulo real del vídeo dentro de la vista (letterbox) y convierte entre
// puntos de pantalla y coordenadas normalizadas 0..1 del modelo en un único
// lugar.

struct LiveCanvasOverlay: View {
    @ObservedObject var state: VideoProjectState
    @Binding var playhead: Double

    // Arrastre en curso: rect al empezar el gesto, para acumular la traslación.
    @State private var dragOrigin: NRect? = nil

    var body: some View {
        GeometryReader { geo in
            let canvas = Self.videoRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                // Cámara flotante del tramo BAJO EL CURSOR (lo que se ve).
                let segIdx = state.project.segmentIndex(at: playhead)
                if state.project.layouts.indices.contains(segIdx),
                   state.project.layouts[segIdx].mode == .overlay {
                    cameraBox(segIdx: segIdx, canvas: canvas)
                }
                // Capas visibles en este instante, en su orden.
                ForEach(Array(state.project.extraLayers.enumerated()), id: \.element.id) { i, layer in
                    if layer.isVisible(at: playhead) {
                        layerBox(i, layer, canvas: canvas)
                    }
                }
            }
        }
    }

    // Rect del vídeo 16:9 centrado dentro de la vista (letterbox manual).
    static func videoRect(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let aspect: CGFloat = 16.0 / 9.0
        let w = min(size.width, size.height * aspect)
        let h = w / aspect
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func points(_ n: NRect, in canvas: CGRect) -> CGRect {
        CGRect(x: canvas.minX + n.x * canvas.width,
               y: canvas.minY + n.y * canvas.height,
               width: n.width * canvas.width,
               height: n.height * canvas.height)
    }

    // MARK: Cámara

    private func cameraBox(segIdx: Int, canvas: CGRect) -> some View {
        let layout = state.project.layouts[segIdx]
        let rect = points(layout.camRect, in: canvas)
        let selected = state.selectedLayerID == nil && state.selectedSegment == segIdx
        return editBox(rect: rect, selected: selected, label: "Cámara",
                       shape: layout.shape,
                       onSelect: {
                           state.selectedLayerID = nil
                           state.selectedSegment = segIdx
                       },
                       read: { layout.camRect },
                       write: { newRect in
                           var p = state.project
                           guard p.layouts.indices.contains(segIdx) else { return }
                           p.layouts[segIdx].camRect = newRect.clamped(minSide: 0.06)
                           state.project = p
                           state.selectedSegment = segIdx
                       },
                       menu: { AnyView(EmptyView()) },
                       canvas: canvas)
    }

    // MARK: Capas

    private func layerBox(_ i: Int, _ layer: ExtraLayer, canvas: CGRect) -> some View {
        let rect = points(layer.rect, in: canvas)
        return editBox(rect: rect, selected: state.selectedLayerID == layer.id,
                       label: layer.name, shape: layer.shape,
                       onSelect: { state.selectedLayerID = layer.id },
                       read: { layer.rect },
                       write: { newRect in
                           var p = state.project
                           guard i < p.extraLayers.count, p.extraLayers[i].id == layer.id else { return }
                           p.extraLayers[i].rect = newRect.clamped(minSide: 0.03)
                           state.project = p
                       },
                       menu: { AnyView(layerMenu(i, layer)) },
                       canvas: canvas)
    }

    private func layerMenu(_ i: Int, _ layer: ExtraLayer) -> some View {
        let segIdx = state.project.segmentIndex(at: playhead)
        let count = state.project.extraLayers.count
        // Posición actual de la capa EN el orden del tramo bajo el cursor.
        let orderNow = state.project.orderedLayers(at: playhead).map(\.id)
        let posNow = orderNow.firstIndex(of: layer.id) ?? i
        return Group {
            Section("Solo en este tramo") {
                Button("Traer al frente") {
                    changePos(layer.id, to: count - 1, segment: segIdx)
                }
                .disabled(posNow == count - 1)
                Button("Traer adelante") { changePos(layer.id, to: posNow + 1, segment: segIdx) }
                    .disabled(posNow == count - 1)
                Button("Enviar atrás") { changePos(layer.id, to: posNow - 1, segment: segIdx) }
                    .disabled(posNow == 0)
                Button("Enviar al fondo") { changePos(layer.id, to: 0, segment: segIdx) }
                    .disabled(posNow == 0)
                if count > 2 {
                    Menu("Posición…") {
                        ForEach(0..<count, id: \.self) { pos in
                            Button("\(pos + 1) de \(count)"
                                   + (pos == posNow ? " ✓" : "")) {
                                changePos(layer.id, to: pos, segment: segIdx)
                            }
                        }
                    }
                }
            }
            Section("En todo el vídeo") {
                Button("Traer al frente en todo") {
                    var p = state.project
                    p.setLayerPositionGlobal(layer.id, to: count - 1)
                    state.project = p
                }
                Button("Enviar al fondo en todo") {
                    var p = state.project
                    p.setLayerPositionGlobal(layer.id, to: 0)
                    state.project = p
                }
            }
            Button(layer.behindCamera ? "Delante de la cámara" : "Detrás de la cámara") {
                mutateLayer(i) { $0.behindCamera.toggle() }
            }
            Divider()
            Button("Ocultar desde aquí") {
                mutateLayer(i) { l in
                    if l.appearances.isEmpty {
                        l.appearances = [LayerAppearance(from: 0, to: playhead)]
                    } else {
                        for k in l.appearances.indices
                        where l.appearances[k].from <= playhead && playhead < l.appearances[k].to {
                            l.appearances[k].to = playhead
                        }
                    }
                }
            }
            Divider()
            Button("Quitar capa", role: .destructive) {
                var p = state.project
                guard i < p.extraLayers.count, p.extraLayers[i].id == layer.id else { return }
                if state.selectedLayerID == layer.id { state.selectedLayerID = nil }
                p.extraLayers.remove(at: i)
                state.project = p
            }
        }
    }

    // El orden del clic derecho es POR TRAMO: en este corte la capa va
    // arriba, en el siguiente puede ir abajo. "En todo el vídeo" usa el global.
    private func changePos(_ id: UUID, to position: Int, segment: Int) {
        var p = state.project
        p.setLayerPosition(id, to: position, inSegment: segment)
        state.project = p
    }

    private func mutateLayer(_ i: Int, _ change: (inout ExtraLayer) -> Void) {
        var p = state.project
        guard i < p.extraLayers.count else { return }
        change(&p.extraLayers[i])
        state.project = p
    }

    // MARK: La caja editable

    // Recuadro con cuerpo arrastrable y 4 tiradores de esquina. read/write
    // van en coordenadas normalizadas; la conversión vive aquí.
    private func editBox(rect: CGRect, selected: Bool, label: String,
                         shape: SegmentLayout.Shape,
                         onSelect: @escaping () -> Void,
                         read: @escaping () -> NRect,
                         write: @escaping (NRect) -> Void,
                         menu: @escaping () -> AnyView,
                         canvas: CGRect) -> some View {
        let stroke: Color = selected ? .yellow : .white.opacity(0.55)
        return ZStack(alignment: .topLeading) {
            boxShape(shape)
                .stroke(stroke, style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [5, 4]))
                .background(Color.white.opacity(0.001))   // superficie clicable
                .frame(width: rect.width, height: rect.height)
                .overlay(alignment: .top) {
                    if selected {
                        Text(label)
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.yellow)
                            .foregroundColor(.black)
                            .clipShape(Capsule())
                            .offset(y: -16)
                    }
                }
                .contentShape(Rectangle())
                .contextMenu { menu() }
                // El tap seco también selecciona (el drag ya lo hace, pero un
                // clic sin movimiento no siempre dispara el DragGesture).
                .onTapGesture { onSelect() }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if dragOrigin == nil {
                                onSelect()
                                dragOrigin = read()
                            }
                            guard let origin = dragOrigin else { return }
                            var r = origin
                            r.x = origin.x + g.translation.width / canvas.width
                            r.y = origin.y + g.translation.height / canvas.height
                            write(r)
                        }
                        .onEnded { _ in dragOrigin = nil }
                )
            if selected {
                ForEach(Corner.allCases, id: \.self) { corner in
                    handle(corner: corner, rect: rect, read: read, write: write, canvas: canvas)
                }
            }
        }
        .offset(x: rect.minX, y: rect.minY)
    }

    private func boxShape(_ s: SegmentLayout.Shape) -> AnyShape {
        switch s {
        case .circle: return AnyShape(Ellipse())
        case .rounded: return AnyShape(RoundedRectangle(cornerRadius: 10))
        case .rect: return AnyShape(Rectangle())
        }
    }

    enum Corner: CaseIterable { case tl, tr, bl, br }

    // Tirador de esquina: redimensiona anclando la esquina opuesta.
    private func handle(corner: Corner, rect: CGRect,
                        read: @escaping () -> NRect,
                        write: @escaping (NRect) -> Void,
                        canvas: CGRect) -> some View {
        let pos: CGPoint
        switch corner {
        case .tl: pos = CGPoint(x: 0, y: 0)
        case .tr: pos = CGPoint(x: rect.width, y: 0)
        case .bl: pos = CGPoint(x: 0, y: rect.height)
        case .br: pos = CGPoint(x: rect.width, y: rect.height)
        }
        // El punto se VE de 9 px pero se AGARRA en 20: pescar un tirador
        // diminuto con el trackpad es un castigo innecesario.
        return Circle()
            .fill(Color.yellow)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
            .frame(width: 20, height: 20)
            .contentShape(Circle())
            .position(pos)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragOrigin == nil { dragOrigin = read() }
                        guard let o = dragOrigin else { return }
                        let dx = g.translation.width / canvas.width
                        let dy = g.translation.height / canvas.height
                        var r = o
                        switch corner {
                        case .br:
                            r.width = o.width + dx
                            r.height = o.height + dy
                        case .tl:
                            r.x = o.x + dx
                            r.y = o.y + dy
                            r.width = o.width - dx
                            r.height = o.height - dy
                        case .tr:
                            r.y = o.y + dy
                            r.width = o.width + dx
                            r.height = o.height - dy
                        case .bl:
                            r.x = o.x + dx
                            r.width = o.width - dx
                            r.height = o.height + dy
                        }
                        write(r)
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
    }
}

// Superficie del reproductor SIN controles del sistema: los gestos son del
// lienzo vivo. El transporte vive en la barra inferior y la tecla espacio.
struct PlainPlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    final class PlayerHostView: NSView {
        let playerLayer = AVPlayerLayer()
        init() {
            super.init(frame: .zero)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }
        required init?(coder: NSCoder) { nil }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)   // sin animación: el recuadro no "persigue"
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> PlayerHostView {
        let v = PlayerHostView()
        v.playerLayer.player = player
        return v
    }

    func updateNSView(_ view: PlayerHostView, context: Context) {
        view.playerLayer.player = player
    }
}
