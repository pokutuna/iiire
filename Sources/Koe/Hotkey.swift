import AppKit
import Carbon.HIToolbox

/// 録音のホットキー。修飾キー単独、または Carbon で登録するキーの組み合わせ。
enum Hotkey: String, CaseIterable, Identifiable {
    case rightOption, rightCommand, rightControl, fn
    case optionSpace, controlOptionSpace, f5

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rightOption: "右 ⌥ Option"
        case .rightCommand: "右 ⌘ Command"
        case .rightControl: "右 ⌃ Control"
        case .fn: "fn / 🌐"
        case .optionSpace: "⌥ Space"
        case .controlOptionSpace: "⌃⌥ Space"
        case .f5: "F5"
        }
    }

    /// 修飾キー単独のときの keyCode と、そのキーが押されているときのフラグ
    fileprivate var modifier: (keyCode: UInt16, flag: NSEvent.ModifierFlags)? {
        switch self {
        case .rightOption: (UInt16(kVK_RightOption), .option)
        case .rightCommand: (UInt16(kVK_RightCommand), .command)
        case .rightControl: (UInt16(kVK_RightControl), .control)
        case .fn: (UInt16(kVK_Function), .function)
        default: nil
        }
    }

    /// Carbon RegisterEventHotKey 用のキーと修飾
    fileprivate var carbon: (keyCode: UInt32, modifiers: UInt32)? {
        switch self {
        case .optionSpace: (UInt32(kVK_Space), UInt32(optionKey))
        case .controlOptionSpace: (UInt32(kVK_Space), UInt32(optionKey | controlKey))
        case .f5: (UInt32(kVK_F5), 0)
        default: nil
        }
    }
}

/// ホットキーの押下・解放を通知する。
/// 修飾キー単独は NSEvent のモニタで見る (アクセシビリティ権限が必要)。
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

    func start(_ hotkey: Hotkey) {
        stop()
        if let m = hotkey.modifier {
            startModifier(keyCode: m.keyCode, flag: m.flag)
        } else if let c = hotkey.carbon {
            startCarbon(keyCode: c.keyCode, modifiers: c.modifiers)
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

    private func startCarbon(keyCode: UInt32, modifiers: UInt32) {
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
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
