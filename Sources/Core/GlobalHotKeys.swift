import AppKit
import Carbon.HIToolbox

// Atajos globales del sistema (Carbon): funcionan aunque el foco esté en
// PowerPoint/Keynote/Adobe. No requieren permisos de accesibilidad.
// Solo se registran mientras el prompter está activo.
final class GlobalHotKeys {
    static let shared = GlobalHotKeys()
    private var refs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private(set) var active = false

    func register() {
        guard !active else { return }
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
                var hkID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                DispatchQueue.main.async {
                    let m = PrompterModel.shared
                    switch hkID.id {
                    case 1: m.togglePlay()
                    case 2: m.changeSpeed(+Settings.Limits.wpmStep)
                    case 3: m.changeSpeed(-Settings.Limits.wpmStep)
                    default: break
                    }
                }
                return noErr
            }, 1, &spec, nil, &handlerRef)
        }
        let sig = OSType(0x42746F50) // "BtoP"
        let mods = UInt32(cmdKey | optionKey)
        let keys: [(UInt32, UInt32)] = [
            (UInt32(kVK_ANSI_P), 1),
            (UInt32(kVK_UpArrow), 2),
            (UInt32(kVK_DownArrow), 3),
        ]
        for (code, id) in keys {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(code, mods, EventHotKeyID(signature: sig, id: id),
                                GetEventDispatcherTarget(), 0, &ref)
            if let ref { refs.append(ref) }
        }
        active = true
    }

    func unregister() {
        for r in refs { UnregisterEventHotKey(r) }
        refs = []
        active = false
    }
}
