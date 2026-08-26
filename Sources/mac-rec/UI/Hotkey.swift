import AppKit
import Carbon.HIToolbox

/// A parsed hotkey: Carbon registration data + NSMenuItem display data.
/// Spec format: "opt+cmd+r", "cmd+shift+2", "ctrl+f9", "opt+cmd+left".
struct Hotkey {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let menuKeyEquivalent: String
    let menuModifiers: NSEvent.ModifierFlags
    let display: String

    static func parse(_ spec: String) -> Hotkey? {
        var carbonMods: UInt32 = 0
        var menuMods: NSEvent.ModifierFlags = []
        var displayMods = ""
        var key: String?

        for rawPart in spec.lowercased().split(separator: "+") {
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            switch part {
            case "cmd", "command":
                carbonMods |= UInt32(cmdKey); menuMods.insert(.command); displayMods += "⌘"
            case "opt", "option", "alt":
                carbonMods |= UInt32(optionKey); menuMods.insert(.option); displayMods += "⌥"
            case "ctrl", "control":
                carbonMods |= UInt32(controlKey); menuMods.insert(.control); displayMods += "⌃"
            case "shift":
                carbonMods |= UInt32(shiftKey); menuMods.insert(.shift); displayMods += "⇧"
            default:
                guard key == nil else { return nil }
                key = part
            }
        }
        guard let key, let (code, equivalent, keyDisplay) = keyInfo(key), carbonMods != 0 else {
            return nil
        }
        // Reorder modifier symbols to the macOS convention ⌃⌥⇧⌘.
        let order = ["⌃", "⌥", "⇧", "⌘"]
        let sortedMods = order.filter { displayMods.contains($0) }.joined()
        return Hotkey(
            keyCode: code,
            carbonModifiers: carbonMods,
            menuKeyEquivalent: equivalent,
            menuModifiers: menuMods,
            display: sortedMods + keyDisplay
        )
    }

    private static func keyInfo(_ key: String) -> (UInt32, String, String)? {
        let letters: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
            "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        ]
        if let code = letters[key] {
            return (UInt32(code), key, key.uppercased())
        }
        switch key {
        case "left": return (UInt32(kVK_LeftArrow), String(UnicodeScalar(NSLeftArrowFunctionKey)!), "←")
        case "right": return (UInt32(kVK_RightArrow), String(UnicodeScalar(NSRightArrowFunctionKey)!), "→")
        case "up": return (UInt32(kVK_UpArrow), String(UnicodeScalar(NSUpArrowFunctionKey)!), "↑")
        case "down": return (UInt32(kVK_DownArrow), String(UnicodeScalar(NSDownArrowFunctionKey)!), "↓")
        case "space": return (UInt32(kVK_Space), " ", "Space")
        default: break
        }
        let fKeys: [String: (Int, Int)] = [
            "f1": (kVK_F1, NSF1FunctionKey), "f2": (kVK_F2, NSF2FunctionKey),
            "f3": (kVK_F3, NSF3FunctionKey), "f4": (kVK_F4, NSF4FunctionKey),
            "f5": (kVK_F5, NSF5FunctionKey), "f6": (kVK_F6, NSF6FunctionKey),
            "f7": (kVK_F7, NSF7FunctionKey), "f8": (kVK_F8, NSF8FunctionKey),
            "f9": (kVK_F9, NSF9FunctionKey), "f10": (kVK_F10, NSF10FunctionKey),
            "f11": (kVK_F11, NSF11FunctionKey), "f12": (kVK_F12, NSF12FunctionKey),
        ]
        if let (code, fn) = fKeys[key] {
            return (UInt32(code), String(UnicodeScalar(fn)!), key.uppercased())
        }
        return nil
    }
}

/// The four bindable actions, resolved from config (with defaults for
/// anything missing or unparseable).
@MainActor
enum HotkeyMap {
    static let bindings: [HotkeyManager.Action: Hotkey] = {
        let specs = Config.load().hotkeyBindings()
        var out: [HotkeyManager.Action: Hotkey] = [:]
        let names: [(HotkeyManager.Action, String)] = [
            (.toggle, "toggle"), (.area, "area"), (.rewind, "rewind"), (.stop, "stop"),
        ]
        for (action, name) in names {
            if let spec = specs[name], let hk = Hotkey.parse(spec) {
                out[action] = hk
            } else if let fallback = Hotkey.parse(Config.defaultHotkeys[name]!) {
                if specs[name] != Config.defaultHotkeys[name] {
                    log("invalid hotkey \"\(specs[name] ?? "")\" for \(name); using default")
                }
                out[action] = fallback
            }
        }
        return out
    }()

    static func display(_ action: HotkeyManager.Action) -> String {
        bindings[action]?.display ?? ""
    }
}
