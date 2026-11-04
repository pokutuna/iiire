import AppKit
import SwiftUI

/// 録音中・書き起こし中に画面下部に出す小さな表示。フォーカスは奪わない。
@MainActor
final class HUDController {
    private let state: AppState
    private var panel: NSPanel?
    private var message: String?
    private var hideTask: Task<Void, Never>?

    init(state: AppState) {
        self.state = state
    }

    func update() {
        if state.phase == .idle, message == nil {
            panel?.orderOut(nil)
        } else {
            show()
        }
    }

    /// エラーなどを数秒だけ出す
    func flash(_ text: String) {
        message = text
        show()
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            message = nil
            update()
        }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: HUDView(message: message).environmentObject(state))
        let size = panel.contentView!.fittingSize
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY + 48, width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel = p
        return p
    }
}

private struct HUDView: View {
    @EnvironmentObject var state: AppState
    let message: String?

    var body: some View {
        HStack(spacing: 8) {
            if let message, state.phase == .idle {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(message).lineLimit(2).frame(maxWidth: 360, alignment: .leading)
            } else if state.phase == .recording {
                Circle().fill(.red).frame(width: 8, height: 8)
                LevelBars(level: state.level)
            } else {
                ProgressView().controlSize(.small)
                Text(transcribingLabel)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.black.opacity(0.8)))
        .fixedSize()
    }

    private var transcribingLabel: String {
        if let d = state.downloadText { return d }
        if case .loading(let s) = state.workerState { return s }
        return String(localized: "Transcribing…")
    }
}

private struct LevelBars: View {
    let level: Float
    private let weights: [Float] = [0.5, 0.8, 1, 0.7, 0.9, 0.6, 0.4]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: CGFloat(4 + 14 * min(1, level * weights[i] * 1.3)))
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
