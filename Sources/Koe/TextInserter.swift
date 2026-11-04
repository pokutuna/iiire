import AppKit
import ApplicationServices

/// 書き起こした文字列をクリップボード経由でカーソル位置にペーストする。
@MainActor
enum TextInserter {
    static func insert(_ text: String, method: OutputMethod) async {
        let pb = NSPasteboard.general

        guard method != .clipboard else {
            pb.clearContents()
            pb.setString(text, forType: .string)
            return
        }

        let saved = method == .paste ? snapshot(pb) : nil
        pb.clearContents()
        pb.setString(text, forType: .string)
        let changeCount = pb.changeCount

        try? await Task.sleep(for: .milliseconds(50))
        guard postCommandV() else { // 権限がなければクリップボードに残すだけ
            Log.info("paste skipped: accessibility not granted (text left in clipboard)")
            return
        }
        Log.info("posted cmd+V to \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")

        guard let saved else { return }
        // ペースト先が読み終えるまで待ってから戻す
        try? await Task.sleep(for: .milliseconds(300))
        guard pb.changeCount == changeCount else { return } // その間に誰かがコピーした
        pb.clearContents()
        if !saved.isEmpty { pb.writeObjects(saved) }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    /// ⌘V を送る。右 ⌘ (0x36) を使い、物理的に押されている左 ⌘ と干渉しないようにする (VoiceInk と同じ)
    private static func postCommandV() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let src = CGEventSource(stateID: .privateState)
        let cmd: CGKeyCode = 0x36, v: CGKeyCode = 0x09
        guard let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: cmd, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: cmd, keyDown: false) else { return false }
        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        for e in [cmdDown, vDown, vUp, cmdUp] { e.post(tap: .cghidEventTap) }
        return true
    }
}
