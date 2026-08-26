import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys via Carbon RegisterEventHotKey — works from an
/// accessory app with no Accessibility permission. Bindings come from
/// config (`hotkeys` in ~/.config/mac-rec/config.json); defaults:
///   ⌥⌘R  start / pause / resume    ⌥⌘A  record area
///   ⌥⌘←  rewind 10s               ⌥⌘S  stop & save
final class HotkeyManager {
    enum Action: UInt32 {
        case toggle = 1
        case stop = 2
        case rewind = 3
        case area = 4
    }

    var onAction: ((Action) -> Void)?

    private var refs: [EventHotKeyRef?] = []
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x4D52_4543  // "MREC"

    init(bindings: [Action: Hotkey]) {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var hkID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                if let action = Action(rawValue: hkID.id) {
                    DispatchQueue.main.async { manager.onAction?(action) }
                }
                return noErr
            },
            1,
            &spec,
            selfPtr,
            &handlerRef
        )

        for (action, hk) in bindings {
            register(keyCode: hk.keyCode, modifiers: hk.carbonModifiers, action: action)
        }
    }

    private func register(keyCode: UInt32, modifiers: UInt32, action: Action) {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(
            keyCode, modifiers, id, GetEventDispatcherTarget(), 0, &ref
        )
        if status == noErr {
            refs.append(ref)
        } else {
            log("hotkey registration failed for action \(action) (status \(status))")
        }
    }

    deinit {
        for ref in refs.compactMap({ $0 }) { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
