import AppKit
import Carbon.HIToolbox

/// Global hotkey that toggles recording; Carbon key code and modifiers, saved under `defaultsKey` (JSON; `null` = off).
struct Hotkey: Codable, Equatable {
    static let defaultsKey = "v2.hotkey"
    static let standard = Hotkey(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey | cmdKey))

    var keyCode: UInt32
    var modifiers: UInt32

    @MainActor static var saved: Hotkey? {
        get {
            guard let data = AppModel.shared.settings.defaults.data(forKey: defaultsKey) else { return standard }
            return try? JSONDecoder().decode(Hotkey?.self, from: data) ?? nil
        }
        set {
            AppModel.shared.settings.defaults.set(try? JSONEncoder().encode(newValue), forKey: defaultsKey)
            HotkeyMonitor.register(newValue)
        }
    }

    /// A key-down with at least one of ⌃⌥⌘ (shift alone would swallow typing), or nil.
    init?(_ event: NSEvent) {
        let flags = event.modifierFlags
        let pairs: [(NSEvent.ModifierFlags, Int)] = [(.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)]
        modifiers = UInt32(pairs.filter { flags.contains($0.0) }.reduce(0) { $0 | $1.1 })
        keyCode = UInt32(event.keyCode)
        guard !flags.intersection([.control, .option, .command]).isEmpty, Self.keyNames[Int(keyCode)] != nil else { return nil }
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// e.g. "⌃⌥⌘R".
    var label: String {
        let symbols = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        let key = Self.keyNames[Int(keyCode)] ?? "?"
        return symbols.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + key
    }

    private static let keyNames: [Int: String] = Dictionary(uniqueKeysWithValues: zip(
        [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J,
         kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T,
         kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z],
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)
    ))
}

@MainActor
enum HotkeyMonitor {
    private static var ref: EventHotKeyRef?
    private static var installed = false

    /// Replaces the registered hotkey (Settings calls this after saving one); nil turns it off.
    static func register(_ hotkey: Hotkey?) {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                MainActor.assumeIsolated { AppModel.shared.toggleRecording() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        guard let hotkey else { return }
        RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, EventHotKeyID(signature: 0x4F_41_54_53, id: 1), GetApplicationEventTarget(), 0, &ref)
    }
}
