import AppKit
import SwiftUI

struct KoeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(delegate.state)
        } label: {
            MenuBarIcon().environmentObject(delegate.state)
        }

        Window("Koe 設定", id: "settings") {
            SettingsView().environmentObject(delegate.state)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor lazy var state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { state.launch() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { state.shutdown() }
    }
}

private struct MenuBarIcon: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        switch state.phase {
        case .recording: Image(systemName: "mic.fill")
        case .transcribing: Image(systemName: "ellipsis.bubble")
        case .idle:
            if case .failed = state.workerState {
                Image(systemName: "mic.slash")
            } else {
                Image(systemName: "mic")
            }
        }
    }
}

private struct MenuContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusText)

        Button(state.phase == .recording ? "録音を止めて書き起こす" : "録音を開始") {
            state.toggleFromMenu()
        }
        .disabled(state.phase == .transcribing)
        Text("ホットキー: \(Defaults.shortcut.displayName) (短く押すとトグル、長押しで押している間)")

        if !state.history.isEmpty {
            Divider()
            Text("履歴 (クリックでコピー)")
            ForEach(Array(state.history.enumerated()), id: \.offset) { _, text in
                Button(text.count > 40 ? String(text.prefix(40)) + "…" : text) {
                    state.copyToClipboard(text)
                }
            }
        }

        Divider()
        Button("設定…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }
        .keyboardShortcut(",")
        Button("Koe を終了") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusText: String {
        if let e = state.lastError { return "⚠️ \(e)" }
        switch state.workerState {
        case .stopped: return "停止中"
        case .loading(let s): return "準備中: \(s)"
        case .ready: return "準備完了: \(Defaults.model.id)"
        case .failed(let m): return "⚠️ \(m)"
        }
    }
}
