import SwiftUI

// Tema visual único de la app: colores y métricas en un solo lugar.
enum Theme {
    static let accent = Color.yellow                                    // marca y palabra actual
    static let guide = Color(red: 0.45, green: 0.78, blue: 1.0)         // líneas guía
    static let heading = Color(red: 1.0, green: 0.92, blue: 0.6)        // títulos leíbles
    static let dimmed = Color.white.opacity(0.32)                       // palabras ya leídas
    static let spyOn = Color.green
    static let spyOff = Color.red
    static let editorBackgroundOpacity = 0.94
    static let panelSize = NSSize(width: 980, height: 580)
    static let panelMinSize = NSSize(width: 640, height: 360)
}
