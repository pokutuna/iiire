import AppKit
import SwiftUI

struct KoeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(delegate.state)
        } label: {
            MenuBarIcon().environmentObject(delegate.state)
                .modifier(OpenSettingsOnLaunch())
        }

        Settings {
            SettingsView().environmentObject(delegate.state)
        }
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

/// 画面の確認用。`--open-settings` で起動したら設定画面を開く。
/// `--snapshot-settings DIR` なら各タブを DIR/settings-<tab>.png に書き出して終了する (画面収録の許可は要らない)
private struct OpenSettingsOnLaunch: ViewModifier {
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.task {
            let args = CommandLine.arguments
            let snapshotDir = args.firstIndex(of: "--snapshot-settings").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            guard args.contains("--open-settings") || snapshotDir != nil else { return }
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
            guard let snapshotDir else { return }
            try? FileManager.default.createDirectory(atPath: snapshotDir, withIntermediateDirectories: true)
            for tab in SettingsTab.allCases {
                SettingsNavigation.shared.tab = tab
                try? await Task.sleep(for: .seconds(1))
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }),
                   let view = window.contentView?.superview,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: snapshotDir).appendingPathComponent("settings-\(tab.rawValue).png"))
                }
            }
            NSApp.terminate(nil)
        }
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
    @Environment(\.openSettings) private var openSettings
    /// 設定画面でホットキーを変えたら、メニューの表示も変える
    @AppStorage(SettingsKey.shortcut) private var shortcutJSON = ""

    var body: some View {
        Text(statusText)

        Button(state.phase == .recording ? String(localized: "Stop Recording") : String(localized: "Start Recording")) {
            state.toggleFromMenu()
        }
        .disabled(state.phase == .transcribing)
        Text("Hotkey: \((Shortcut.decode(shortcutJSON) ?? Defaults.shortcut).displayName)")

        if !state.history.isEmpty {
            Divider()
            Text("History (click to copy)")
            ForEach(Array(state.history.enumerated()), id: \.offset) { _, text in
                Button(text.count > 40 ? String(text.prefix(40)) + "…" : text) {
                    state.copyToClipboard(text)
                }
            }
        }

        Divider()
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Quit Koe") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusText: String {
        if let e = state.lastError { return "⚠️ \(e)" }
        switch state.workerState {
        case .stopped: return String(localized: "Stopped")
        case .loading(let s): return state.downloadText ?? s
        case .ready: return String(localized: "Ready: \(Defaults.model.id)")
        case .failed(let m): return "⚠️ \(m)"
        }
    }
}
