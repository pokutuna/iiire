import AppKit
import SwiftUI

/// HUD に出す内容
enum HUDContent: Equatable {
    case recording(startedAt: Date, device: String?)
    case working(String)
    /// 入力した結果と、書き起こした文字列
    case result(InsertResult, String)
    case error(String)
}

/// HUD の表示内容。中身を差し替えるとアニメーションでつなぐ
@MainActor
final class HUDModel: ObservableObject {
    static let barCount = 28

    @Published var content: HUDContent?
    /// 直近の入力レベル。右端が最新
    @Published private(set) var levels = [Float](repeating: 0, count: barCount)

    func push(_ level: Float) {
        levels = levels.dropFirst() + [level] // 一度の代入で知らせる
    }

    func resetLevels() {
        levels = [Float](repeating: 0, count: Self.barCount)
    }
}

/// 録音中・書き起こし中に出す小さな表示。フォーカスは奪わず、録音中だけドラッグできる。
/// パネルの大きさは固定し、中身の大きさの変化は SwiftUI のアニメーションで見せる
@MainActor
final class HUDController {
    static let panelSize = NSSize(width: 560, height: 180)
    static let bottomPadding: CGFloat = 24

    private unowned let state: AppState // AppState が持つ
    private let model = HUDModel()
    private var panel: NSPanel?
    private var screen: NSScreen?
    private var bubbleSize: CGSize = .zero
    /// 吹き出しの下辺中央。画面の左上からの割合で保持する
    private var draggedPosition: CGPoint?
    private var dragStart: CGPoint?
    /// 結果やエラーを出している間は、待機中になっても消さない
    private var noticeTask: Task<Void, Never>?
    /// 書き起こしが終わってから入力の結果が出るまでの間、今の表示を残す
    private var awaitingResult = false
    private var orderOutTask: Task<Void, Never>?

    init(state: AppState) {
        self.state = state
    }

    func update() {
        switch state.phase {
        case .recording:
            if case .recording = model.content {} else {
                model.resetLevels()
                set(.recording(startedAt: state.recordingStartedAt ?? Date(), device: state.recordingDevice),
                    reselectScreen: true)
            }
        case .transcribing:
            set(.working(transcribingLabel))
        case .idle:
            guard !awaitingResult, noticeTask == nil else { return }
            hide()
        }
    }

    func push(level: Float) {
        guard case .recording = model.content else { return }
        model.push(level)
    }

    /// この後 showResult が来るので、待機中になっても消さない
    func expectResult() {
        awaitingResult = true
    }

    func showResult(_ result: InsertResult, text: String) {
        awaitingResult = false
        // ペーストする間に次の録音が始まっていたら、録音の表示を残す
        guard state.phase == .idle else { return }
        notice(.result(result, text), seconds: result == .notPasted ? 4 : 1.5)
    }

    /// エラーなどを数秒だけ出す
    func flash(_ text: String) {
        awaitingResult = false
        notice(.error(text), seconds: 4)
    }

    private var transcribingLabel: String {
        if state.cancelRequested { return String(localized: "Cancelling… Press Esc again to stop now.") }
        if let d = state.downloadText { return d }
        if case .loading(let s) = state.workerState { return s }
        return String(localized: "Transcribing…")
    }

    private func notice(_ content: HUDContent, seconds: Double) {
        set(content)
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            noticeTask = nil
            update()
        }
    }

    private func set(_ content: HUDContent, reselectScreen: Bool = false) {
        noticeTask?.cancel()
        noticeTask = nil
        orderOutTask?.cancel()
        let panel = self.panel ?? makePanel()
        let needsOrdering = !panel.isVisible
        // 前回の結果が残っていても、次の録音ではフォーカスのある画面を選び直す
        if reselectScreen || needsOrdering {
            screen = NSScreen.main
            place()
        }
        if needsOrdering { panel.orderFrontRegardless() }
        if case .recording = content {
            panel.ignoresMouseEvents = false
        } else {
            finishDrag()
            panel.ignoresMouseEvents = true
        }
        guard model.content != content else { return }
        withAnimation(.spring(duration: 0.3, bounce: 0.15)) { model.content = content }
    }

    private func hide() {
        guard model.content != nil else { return }
        finishDrag()
        panel?.ignoresMouseEvents = true
        withAnimation(.easeOut(duration: 0.2)) { model.content = nil }
        orderOutTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, model.content == nil else { return }
            panel?.orderOut(nil)
        }
    }

    func updatePosition() {
        draggedPosition = nil
        dragStart = nil
        place()
    }

    private func place() {
        guard let frame = screen?.visibleFrame, let panel else { return }
        let position = draggedPosition ?? state.hudPosition ?? Defaults.Initial.hudPosition
        let anchor = CGPoint(x: frame.minX + position.x * frame.width, y: frame.maxY - position.y * frame.height)
        move(panel, to: anchor, in: frame)
    }

    /// 透明な余白を除き、吹き出し全体が画面に収まるようにする
    private func move(_ panel: NSPanel, to anchor: CGPoint, in frame: CGRect) {
        let halfWidth = min(bubbleSize.width, frame.width) / 2
        let height = min(bubbleSize.height, frame.height)
        let x = anchor.x.clamped(to: (frame.minX + halfWidth)...(frame.maxX - halfWidth))
        let y = anchor.y.clamped(to: frame.minY...(frame.maxY - height))
        panel.setFrameOrigin(CGPoint(x: x - Self.panelSize.width / 2, y: y - Self.bottomPadding))
    }

    private func drag(by delta: CGSize, ended: Bool) {
        guard state.phase == .recording, let frame = screen?.visibleFrame, let panel,
              frame.width > 0, frame.height > 0 else { return }
        let current = CGPoint(x: panel.frame.midX, y: panel.frame.minY + Self.bottomPadding)
        let start = dragStart ?? current
        dragStart = start
        move(panel, to: CGPoint(x: start.x + delta.width, y: start.y + delta.height), in: frame)
        let anchor = CGPoint(x: panel.frame.midX, y: panel.frame.minY + Self.bottomPadding)
        draggedPosition = CGPoint(x: (anchor.x - frame.minX) / frame.width, y: (frame.maxY - anchor.y) / frame.height)
        if ended { finishDrag() }
    }

    private func finishDrag() {
        guard let draggedPosition else { return }
        state.setHUDPosition(draggedPosition)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false // 影は中身に付ける (パネルは透明な余白を含むため)
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = NSHostingView(rootView: HUDView(model: model, onDrag: { [weak self] delta, ended in
            self?.drag(by: delta, ended: ended)
        }, onBubbleSizeChange: { [weak self] size in
            guard let self else { return }
            bubbleSize = size
            place()
        }))
        panel = p
        return p
    }

    /// 画面の確認用。各表示を PNG に書き出す (ライトとダーク)
    static func snapshot(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let samples: [(String, HUDContent)] = [
            ("recording", .recording(startedAt: Date().addingTimeInterval(-7), device: "MacBook Pro Microphone")),
            ("working", .working(String(localized: "Transcribing…"))),
            ("pasted", .result(.pasted, "音声入力のテストです。設定画面から出力の方法を変えられます。")),
            ("copied", .result(.copied, "音声入力のテストです。")),
            ("not-pasted", .result(.notPasted, "音声入力のテストです。")),
            ("error", .error(String(localized: "No speech detected."))),
        ]
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for (label, content) in samples {
                let model = HUDModel()
                for i in 0..<HUDModel.barCount { model.push(0.25 + 0.6 * abs(Float(sin(Double(i) * 0.7)))) }
                model.content = content
                let host = NSHostingView(rootView: HUDView(model: model, snapshot: true))
                host.appearance = NSAppearance(named: appearance)
                host.frame = NSRect(origin: .zero, size: panelSize)
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: dir.appendingPathComponent("hud-\(label)-\(name).png"))
            }
        }
    }
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel
    /// 画面の確認用。書き出しでは背後のぼかしが描かれず濁った灰色になるので、
    /// ぼかしの代わりに不透明な背景色で塗り、まわりは透明にする
    var snapshot = false
    var onDrag: ((CGSize, Bool) -> Void)?
    var onBubbleSizeChange: ((CGSize) -> Void)?

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let content = model.content {
                bubble(content)
                    .overlay {
                        if case .recording = content, let onDrag {
                            HUDDragArea(onDrag: onDrag)
                        }
                    }
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { onBubbleSizeChange?($0) }
                    .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, HUDController.bottomPadding)
        .frame(width: HUDController.panelSize.width, height: HUDController.panelSize.height)
    }

    private func bubble(_ content: HUDContent) -> some View {
        Group {
            switch content {
            case .recording(let startedAt, let device):
                RecordingContent(levels: model.levels, startedAt: startedAt, device: device)
            case .working(let label):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(label)
                }
            case .result(let result, let text):
                ResultContent(result: result, text: text)
            case .error(let message):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                    Text(message).lineLimit(2).frame(maxWidth: 380, alignment: .leading)
                }
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(snapshot ? Color(nsColor: .windowBackgroundColor) : .clear)
                .background(snapshot ? nil : VisualEffect().clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        }
        .fixedSize()
        .animation(.spring(duration: 0.3, bounce: 0.15), value: content)
    }
}

/// パネル自体が動くので、ドラッグ量は画面座標で測る
private struct HUDDragArea: NSViewRepresentable {
    let onDrag: (CGSize, Bool) -> Void

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {
        view.onDrag = onDrag
    }

    final class DragView: NSView {
        var onDrag: ((CGSize, Bool) -> Void)?
        private var start: CGPoint?
        private var dragged = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            start = NSEvent.mouseLocation
            dragged = false
        }

        override func mouseDragged(with event: NSEvent) {
            dragged = true
            move(ended: false)
        }

        override func mouseUp(with event: NSEvent) {
            if dragged { move(ended: true) }
            start = nil
        }

        private func move(ended: Bool) {
            guard let start else { return }
            let point = NSEvent.mouseLocation
            onDrag?(CGSize(width: point.x - start.x, height: point.y - start.y), ended)
        }
    }
}

/// 録音中: 赤い点、流れる波形、経過時間。下に入力デバイス名
private struct RecordingContent: View {
    let levels: [Float]
    let startedAt: Date
    let device: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                PulsingDot()
                Waveform(levels: levels)
                Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 36, alignment: .trailing)
            }
            if let device {
                Label(device, systemImage: "mic")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 240, alignment: .leading)
            }
        }
    }
}

private struct PulsingDot: View {
    @ViewState private var dim = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 8, height: 8)
            .opacity(dim ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

/// 直近の入力レベルを右から左へ流す
private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(.primary)
                    .frame(width: 3, height: CGFloat(3 + 17 * min(1, levels[i])))
            }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.1), value: levels)
    }
}

/// 入力の結果: 入れた文字列を短く出す
private struct ResultContent: View {
    let result: InsertResult
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            switch result {
            case .pasted:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .copied:
                Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
            case .notPasted:
                Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 360, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var note: LocalizedStringKey? {
        switch result {
        case .pasted: nil
        case .copied: "Copied to clipboard"
        case .notPasted: "Could not paste. Paste from the clipboard."
        }
    }
}

/// システムの HUD の素材。背後をぼかし、ライト・ダークの外観に合わせる
private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
