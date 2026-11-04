import AVFoundation
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, recognition, output, advanced
}

/// 開いているタブ。画面の確認用に外からも切り替える
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var tab: SettingsTab = .general
}

/// 設定画面。Settings シーンの TabView なので、タブはツールバーに並び、ウィンドウの高さはタブの中身に合う。
/// 設定は変更するとすぐに保存する
struct SettingsView: View {
    @ObservedObject private var nav = SettingsNavigation.shared

    var body: some View {
        TabView(selection: $nav.tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            RecognitionSettings()
                .tabItem { Label("Recognition", systemImage: "waveform") }
                .tag(SettingsTab.recognition)
            OutputSettings()
                .tabItem { Label("Output", systemImage: "text.cursor") }
                .tag(SettingsTab.output)
            AdvancedSettings()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
                .tag(SettingsTab.advanced)
        }
    }
}

// MARK: - 一般: ホットキー、マイク、効果音、権限

private struct GeneralSettings: View {
    @EnvironmentObject var state: AppState

    @AppStorage(SettingsKey.shortcut) private var shortcutJSON = ""
    @State private var shortcutError: String?
    @AppStorage(SettingsKey.inputDeviceUID) private var inputDeviceUID = ""
    @AppStorage(SettingsKey.soundCue) private var soundCue = true
    @AppStorage(SettingsKey.startSound) private var startSound = "Tink"
    @AppStorage(SettingsKey.stopSound) private var stopSound = "Pop"

    @State private var devices: [AudioInputDevice] = []
    @State private var soundNames: [String] = []
    @State private var axTrusted = TextInserter.isTrusted
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        Form {
            Section {
                LabeledContent("Hotkey") {
                    VStack(alignment: .trailing, spacing: 4) {
                        ShortcutRecorderView(
                            shortcut: Shortcut.decode(shortcutJSON) ?? Defaults.shortcut,
                            onChange: { shortcutJSON = $0.encoded() },
                            onRecordingChange: { recording in
                                if recording {
                                    shortcutError = nil
                                    state.suspendHotkey()
                                } else if !state.applyHotkey() {
                                    shortcutError = Self.shortcutErrorText
                                }
                            }
                        )
                        if let shortcutError {
                            Text(shortcutError).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                Picker("Microphone", selection: $inputDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(devices) { Text($0.name).tag($0.uid) }
                }
            } footer: {
                Text("Press briefly to start recording and press again to stop. Hold to record only while held. Esc cancels.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Play sounds when recording starts and stops", isOn: $soundCue)
                if soundCue {
                    soundPicker("Start Sound", selection: $startSound)
                    soundPicker("Stop Sound", selection: $stopSound)
                }
            }

            Section {
                PermissionRow(
                    title: "Microphone",
                    granted: micStatus == .authorized,
                    consequence: "Koe cannot record.",
                    actionTitle: "Open System Settings"
                ) {
                    openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                }
                PermissionRow(
                    title: "Accessibility",
                    granted: axTrusted,
                    consequence: "Koe cannot type at the cursor, and a modifier key alone cannot be the hotkey.",
                    actionTitle: "Allow"
                ) {
                    TextInserter.requestAccessibility()
                    openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Settings are saved as soon as you change them and apply from the next recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .settingsForm()
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onChange(of: shortcutJSON) {
            if !state.applyHotkey() { shortcutError = Self.shortcutErrorText }
        }
    }

    private static var shortcutErrorText: String {
        String(localized: "This shortcut cannot be registered. Another app may be using it.")
    }

    /// 選ぶと鳴らす。▶ でもう一度鳴らせる
    private func soundPicker(_ title: LocalizedStringKey, selection: Binding<String>) -> some View {
        HStack {
            Picker(title, selection: selection) {
                // 保存した音が見つからなくなっても選択肢から消さない
                ForEach(soundNames.contains(selection.wrappedValue) ? soundNames : [selection.wrappedValue] + soundNames, id: \.self) {
                    Text($0).tag($0)
                }
            }
            .onChange(of: selection.wrappedValue) { _, name in SoundCue.preview(name) }
            Button {
                SoundCue.preview(selection.wrappedValue)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Preview")
        }
    }

    private func refresh() {
        devices = AudioDevices.inputs()
        soundNames = SoundCue.availableNames()
        axTrusted = TextInserter.isTrusted
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }
}

/// 権限の行。許可されていなければ、エラーとして目立たせ、できないことを書く
private struct PermissionRow: View {
    let title: LocalizedStringKey
    let granted: Bool
    let consequence: LocalizedStringKey
    let actionTitle: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
            } else {
                Button(actionTitle, action: action)
            }
        } label: {
            if granted {
                Text(title)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Label {
                        Text(title)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    Text("Not allowed. \(Text(consequence))")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
    }
}

// MARK: - 認識: モデル、言語、語彙

private struct RecognitionSettings: View {
    @EnvironmentObject var state: AppState

    @AppStorage(SettingsKey.model) private var model = "haas-ja-v1.0"
    @AppStorage(SettingsKey.language) private var language = "auto"
    @AppStorage(SettingsKey.hint) private var hint = ""

    var body: some View {
        let m = RecognitionModel.find(model)
        Form {
            Section {
                Picker("Model", selection: $model) {
                    ForEach(RecognitionModel.all) { r in
                        // 取得済みのモデルに印を付ける
                        Text(state.modelFiles[r.id]?.fetched == true ? "\(r.label) ✓" : r.label).tag(r.id)
                    }
                }
                LabeledContent("Model File") { modelFileStatus }
                LabeledContent("Status", value: workerStatus)
                if m.takesPrompt {
                    Picker("Language", selection: $language) {
                        Text("Automatic").tag("auto")
                        Text("Japanese").tag("ja")
                        Text("English").tag("en")
                    }
                }
            } footer: {
                Text("✓ marks downloaded models. A model is downloaded from Hugging Face when you first select it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if m.takesPrompt || m.takesKeywords {
                Section {
                    TextEditor(text: $hint)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 100)
                } header: {
                    m.takesPrompt ? Text("Hint (names and terms)") : Text("Vocabulary (one per line, written=reading)")
                }
            }
        }
        .settingsForm()
        .onAppear { state.refreshModels() }
        .onChange(of: model) { state.restartWorker() }
    }

    @ViewBuilder
    private var modelFileStatus: some View {
        if let f = state.modelFiles[model] {
            if f.fetched {
                Text("Downloaded (\(ModelFile.gigabytes(f.size)))")
            } else if state.downloadText != nil {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: f.fraction).frame(width: 180)
                    Text("Downloading: \(ModelFile.gigabytes(f.partial)) / \(ModelFile.gigabytes(f.size))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            } else {
                Text("Not downloaded (\(ModelFile.gigabytes(f.size)))")
            }
        } else {
            Text("Unknown").foregroundStyle(.secondary)
        }
    }

    private var workerStatus: String {
        switch state.workerState {
        case .stopped: String(localized: "Stopped")
        case .loading(let s): state.downloadText == nil ? s : String(localized: "Waiting for the download")
        case .ready: String(localized: "Ready")
        case .failed(let m): m
        }
    }
}

// MARK: - 出力: 入力のしかた、ペーストのタイミング

private struct OutputSettings: View {
    @AppStorage(SettingsKey.outputMethod) private var outputMethod = OutputMethod.paste.rawValue
    @AppStorage(SettingsKey.pasteKeyIntervalMs) private var pasteKeyIntervalMs = 10
    @AppStorage(SettingsKey.clipboardRestoreDelayMs) private var clipboardRestoreDelayMs = 300

    var body: some View {
        Form {
            Section {
                Picker("Transcribed Text", selection: $outputMethod) {
                    ForEach(OutputMethod.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }

            if outputMethod != OutputMethod.clipboard.rawValue {
                Section {
                    msField("Key event interval for ⌘V", value: $pasteKeyIntervalMs,
                            range: Defaults.pasteKeyIntervalRange, step: 5)
                    if outputMethod == OutputMethod.paste.rawValue {
                        msField("Restore clipboard after", value: $clipboardRestoreDelayMs,
                                range: Defaults.clipboardRestoreDelayRange, step: 50)
                    }
                } header: {
                    Text("Paste Timing")
                } footer: {
                    Text("If text is not inserted or the previous clipboard gets pasted instead, increase these values.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .settingsForm()
    }

    /// ミリ秒の入力欄。範囲外の値は範囲に収める
    private func msField(_ title: LocalizedStringKey, value: Binding<Int>, range: ClosedRange<Int>, step: Int) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("", value: value, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                    .onSubmit { value.wrappedValue = value.wrappedValue.clamped(to: range) }
                Text("ms").foregroundStyle(.secondary)
                Stepper("", value: value, in: range, step: step).labelsHidden()
            }
        }
    }
}

// MARK: - 詳細: speech コマンド

private struct AdvancedSettings: View {
    @EnvironmentObject var state: AppState
    @AppStorage(SettingsKey.speechPath) private var speechPath = ""

    var body: some View {
        Form {
            Section {
                TextField("Path (automatic if empty)", text: $speechPath, prompt: Text(SpeechWorker.resolveExecutable() ?? String(localized: "Not found")))
                LabeledContent("Worker") {
                    Button("Restart Worker") { state.restartWorker() }
                }
            } header: {
                Text("speech Command")
            } footer: {
                Text("A new path takes effect after you restart the worker.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .settingsForm()
    }
}

private extension View {
    /// 各タブで同じ見た目にする。幅をそろえ、高さは中身に合わせる (ウィンドウの高さもこれに合う)
    func settingsForm() -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 500)
            .fixedSize()
    }
}

private func openURL(_ url: String) {
    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
}
