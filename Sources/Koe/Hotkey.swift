import AppKit
import Carbon.HIToolbox

/// 録音のホットキー。修飾キー単独 (左右を区別) か、修飾キーとキーの組み合わせ。
struct Shortcut: Codable, Hashable {
    enum Kind: String, Codable {
        case modifierOnly   // keyCode は修飾キーそのもの (右 ⌥ なら kVK_RightOption)
        case combo          // keyCode + modifiers を Carbon で登録する
    }

    var kind: Kind
    var keyCode: UInt16
    /// combo の修飾 (NSEvent.ModifierFlags の ⌃⌥⇧⌘ のみ)
    var modifiers: UInt
    /// 押したときの文字 (配列に依存するので記録時に覚えておく)
    var keyLabel: String

    static let `default` = Shortcut(kind: .modifierOnly, keyCode: UInt16(kVK_RightOption), modifiers: 0, keyLabel: "")

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.comboModifiers)
    }

    static let comboModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    var displayName: String {
        switch kind {
        case .modifierOnly:
            return Self.modifierKeyName(keyCode) ?? "key \(keyCode)"
        case .combo:
            return Self.modifierSymbols(modifierFlags) + keyLabel
        }
    }

    // MARK: 保存

    func encoded() -> String {
        (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? ""
    }

    static func decode(_ s: String) -> Shortcut? {
        guard let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    // MARK: 表示

    /// 修飾キーの keyCode → 名前。修飾キーでなければ nil
    static func modifierKeyName(_ keyCode: UInt16) -> String? {
        switch Int(keyCode) {
        case kVK_Command: String(localized: "Left ⌘")
        case kVK_RightCommand: String(localized: "Right ⌘")
        case kVK_Option: String(localized: "Left ⌥")
        case kVK_RightOption: String(localized: "Right ⌥")
        case kVK_Control: String(localized: "Left ⌃")
        case kVK_RightControl: String(localized: "Right ⌃")
        case kVK_Shift: String(localized: "Left ⇧")
        case kVK_RightShift: String(localized: "Right ⇧")
        case kVK_Function: "fn"
        default: nil
        }
    }

    /// 修飾キーの keyCode → それが押されているときに立つフラグ
    static func modifierFlag(_ keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand: .command
        case kVK_Option, kVK_RightOption: .option
        case kVK_Control, kVK_RightControl: .control
        case kVK_Shift, kVK_RightShift: .shift
        case kVK_Function: .function
        default: nil
        }
    }

    static func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    /// 文字にならないキーの名前
    static func specialKeyName(_ keyCode: UInt16) -> String? {
        switch Int(keyCode) {
        case kVK_Space: "Space"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_Delete: "⌫"
        case kVK_ForwardDelete: "⌦"
        case kVK_Escape: "Esc"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_Home: "Home"
        case kVK_End: "End"
        case kVK_PageUp: "PageUp"
        case kVK_PageDown: "PageDown"
        case kVK_JIS_Eisu: String(localized: "Eisu")
        case kVK_JIS_Kana: String(localized: "Kana")
        default: functionKeyNumber(keyCode).map { "F\($0)" }
        }
    }

    static func functionKeyNumber(_ keyCode: UInt16) -> Int? {
        let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        return fkeys.firstIndex(of: Int(keyCode)).map { $0 + 1 }
    }

    static func keyLabel(for event: NSEvent) -> String {
        if let name = specialKeyName(event.keyCode) { return name }
        let c = event.charactersIgnoringModifiers ?? ""
        return c.isEmpty ? "key \(event.keyCode)" : c.uppercased()
    }
}

/// ホットキーの押下・解放を通知する。
/// 修飾キー単独は NSEvent のモニタで見る (アクセシビリティ権限が必要)。組み合わせは Carbon で登録する。
@MainActor
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// 修飾キーを押したまま別のキーを押した (= ショートカットの一部として使った)
    var onInterrupted: (() -> Void)?

    private var monitors: [Any] = []
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var isDown = false

    /// 登録できなければ false (他のアプリが同じ組み合わせを使っているなど)
    @discardableResult
    func start(_ shortcut: Shortcut) -> Bool {
        stop()
        switch shortcut.kind {
        case .modifierOnly:
            guard let flag = Shortcut.modifierFlag(shortcut.keyCode) else { return false }
            startModifier(keyCode: shortcut.keyCode, flag: flag)
            return true
        case .combo:
            return startCarbon(keyCode: UInt32(shortcut.keyCode), modifiers: Self.carbonModifiers(shortcut.modifierFlags))
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        isDown = false
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.shift) { m |= shiftKey }
        return UInt32(m)
    }

    // MARK: modifier-only

    private func startModifier(keyCode: UInt16, flag: NSEvent.ModifierFlags) {
        let handleFlags: (NSEvent) -> Void = { [weak self] e in
            guard let self, e.keyCode == keyCode else { return }
            let down = e.modifierFlags.contains(flag)
            if down, !isDown {
                isDown = true
                onPress?()
            } else if !down, isDown {
                isDown = false
                onRelease?()
            }
        }
        let handleKey: (NSEvent) -> Void = { [weak self] _ in
            guard let self, isDown else { return }
            onInterrupted?()
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handleFlags) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handleKey) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { handleFlags($0); return $0 }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handleKey($0); return $0 }) { monitors.append(m) }
    }

    // MARK: Carbon hotkey

    private func startCarbon(keyCode: UInt32, modifiers: UInt32) -> Bool {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
            let kind = GetEventKind(event)
            MainActor.assumeIsolated {
                if kind == UInt32(kEventHotKeyPressed), !monitor.isDown {
                    monitor.isDown = true
                    monitor.onPress?()
                } else if kind == UInt32(kEventHotKeyReleased), monitor.isDown {
                    monitor.isDown = false
                    monitor.onRelease?()
                }
            }
            return noErr
        }, types.count, &types, me, &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x4B4F_4521), id: 1) // 'KOE!'
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        return status == noErr
    }
}
