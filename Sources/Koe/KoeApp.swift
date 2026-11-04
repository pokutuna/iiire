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

        Window("Koe Settings", id: "settings") {
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

        Button(state.phase == .recording ? String(localized: "Stop and Transcribe") : String(localized: "Start Recording")) {
            state.toggleFromMenu()
        }
        .disabled(state.phase == .transcribing)
        Text("Hotkey: \(Defaults.shortcut.displayName) (press to toggle, hold to talk)")

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
            openWindow(id: "settings")
        }
        .keyboardShortcut(",")
        Button("Quit Koe") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusText: String {
        if let e = state.lastError { return "⚠️ \(e)" }
        switch state.workerState {
        case .stopped: return String(localized: "Stopped")
        case .loading(let s): return String(localized: "Preparing: \(s)")
        case .ready: return String(localized: "Ready: \(Defaults.model.id)")
        case .failed(let m): return "⚠️ \(m)"
        }
    }
}
