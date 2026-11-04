import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 設定画面でキーを実際に押してショートカットを記録する。押している間はその場で表示する。
@MainActor
final class ShortcutRecorderModel: ObservableObject {
    @Published private(set) var isRecording = false
    /// 記録中に押されているキーの表示
    @Published private(set) var preview = ""
    @Published var message: String?

    /// 記録が終わったとき (確定でも取り消しでも) に呼ぶ。確定なら値が入る
    var onFinish: ((Shortcut?) -> Void)?

    private var monitor: Any?
    /// 今押されている修飾キー (keyCode)
    private var heldModifierKeys: [UInt16] = []
    /// 修飾キーを押し始めてから離し切るまでに押された修飾キー
    private var gestureModifierKeys: [UInt16] = []
    /// その間に修飾キー以外のキーが押されたか
    private var gestureHadKey = false

    func start() {
        guard !isRecording else { return }
        isRecording = true
        message = nil
        preview = ""
        heldModifierKeys = []
        resetGesture()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            guard let self else { return e }
            if e.type == .flagsChanged { flagsChanged(e) } else { keyDown(e) }
            return nil // 記録中のキーは他へ流さない
        }
    }

    func cancel() {
        finish(nil)
    }

    private func finish(_ shortcut: Shortcut?) {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        preview = ""
        onFinish?(shortcut)
    }

    private func resetGesture() {
        gestureModifierKeys = []
        gestureHadKey = false
    }

    func flagsChanged(_ e: NSEvent) {
        guard let flag = Shortcut.modifierFlag(e.keyCode) else { return } // Caps Lock など
        let down = e.modifierFlags.contains(flag) && !heldModifierKeys.contains(e.keyCode)
        if down {
            if heldModifierKeys.isEmpty { resetGesture() }
            heldModifierKeys.append(e.keyCode)
            if !gestureModifierKeys.contains(e.keyCode) { gestureModifierKeys.append(e.keyCode) }
            message = nil
        } else {
            heldModifierKeys.removeAll { $0 == e.keyCode }
        }

        if heldModifierKeys.isEmpty {
            // 修飾キーだけを押して離した
            if !gestureHadKey, let only = gestureModifierKeys.first {
                if gestureModifierKeys.count == 1 {
                    finish(Shortcut(kind: .modifierOnly, keyCode: only, modifiers: 0, keyLabel: ""))
                    return
                }
                message = String(localized: "Only one modifier key can be used on its own.")
            }
            preview = ""
        } else {
            preview = heldPreview()
        }
    }

    func keyDown(_ e: NSEvent) {
        guard !e.isARepeat else { return }
        gestureHadKey = true
        let mods = e.modifierFlags.intersection(Shortcut.comboModifiers)
        let label = Shortcut.keyLabel(for: e)

        if mods.isEmpty, e.keyCode == UInt16(kVK_Escape) {
            cancel()
            return
        }
        preview = Shortcut.modifierSymbols(mods) + label
        if mods.isEmpty, Shortcut.functionKeyNumber(e.keyCode) == nil {
            message = String(localized: "Combine with ⌃, ⌥, ⇧ or ⌘ (F keys work on their own).")
            return
        }
        finish(Shortcut(kind: .combo, keyCode: e.keyCode, modifiers: mods.rawValue, keyLabel: label))
    }

    /// 押している修飾キーの表示。1 つなら左右まで出す
    private func heldPreview() -> String {
        if heldModifierKeys.count == 1, let name = Shortcut.modifierKeyName(heldModifierKeys[0]) {
            return name + " …"
        }
        var flags: NSEvent.ModifierFlags = []
        var fn = false
        for k in heldModifierKeys {
            if let f = Shortcut.modifierFlag(k) {
                if f == .function { fn = true } else { flags.insert(f) }
            }
        }
        return (fn ? "fn " : "") + Shortcut.modifierSymbols(flags) + " …"
    }
}

struct ShortcutRecorderView: View {
    let shortcut: Shortcut
    let onChange: (Shortcut) -> Void
    /// 記録を始める・終える。記録中は今のホットキーを止める
    let onRecordingChange: (Bool) -> Void

    @StateObject private var model = ShortcutRecorderModel()

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(model.isRecording && model.preview.isEmpty ? .secondary : .primary)
                    .frame(minWidth: 140)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(model.isRecording ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(model.isRecording ? Color.accentColor : .clear, lineWidth: 1.5)
                    )
                    .animation(.easeOut(duration: 0.1), value: model.preview)

                if model.isRecording {
                    Button("Cancel") { model.cancel() }
                } else {
                    Button("Change…") {
                        onRecordingChange(true)
                        model.start()
                    }
                    if shortcut != .default {
                        Button("Reset to Default") { onChange(.default) }
                    }
                }
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.orange)
            } else if model.isRecording {
                Text("Press the keys to use (Esc to cancel)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            model.onFinish = { s in
                if let s { onChange(s) }
                onRecordingChange(false)
            }
        }
        .onDisappear { model.cancel() }
    }

    private var label: String {
        guard model.isRecording else { return shortcut.displayName }
        return model.preview.isEmpty ? String(localized: "Press keys…") : model.preview
    }
}
