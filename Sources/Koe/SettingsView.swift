import AVFoundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    @AppStorage(SettingsKey.model) private var model = "haas-ja-v1.0"
    @AppStorage(SettingsKey.language) private var language = "auto"
    @AppStorage(SettingsKey.hint) private var hint = ""
    @AppStorage(SettingsKey.shortcut) private var shortcutJSON = ""
    @State private var shortcutError: String?
    @AppStorage(SettingsKey.inputDeviceUID) private var inputDeviceUID = ""
    @AppStorage(SettingsKey.outputMethod) private var outputMethod = OutputMethod.paste.rawValue
    @AppStorage(SettingsKey.speechPath) private var speechPath = ""

    @State private var devices: [AudioInputDevice] = []
    @State private var axTrusted = TextInserter.isTrusted
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        Form {
            Section("音声認識") {
                Picker("モデル", selection: $model) {
                    ForEach(RecognitionModel.all) { Text($0.label).tag($0.id) }
                }
                if RecognitionModel.find(model).takesPrompt {
                    Picker("言語", selection: $language) {
                        Text("自動").tag("auto")
                        Text("日本語").tag("ja")
                        Text("英語").tag("en")
                    }
                }
                let m = RecognitionModel.find(model)
                if m.takesPrompt || m.takesKeywords {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(m.takesPrompt ? "ヒント (固有名詞や用語)" : "語彙 (1 行に 1 つ、表記=読み)")
                        TextEditor(text: $hint)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 60)
                    }
                }
                LabeledContent("状態", value: workerStatus)
            }

            Section("入力") {
                Picker("マイク", selection: $inputDeviceUID) {
                    Text("システムの既定").tag("")
                    ForEach(devices) { Text($0.name).tag($0.uid) }
                }
                LabeledContent("ホットキー") {
                    VStack(alignment: .trailing, spacing: 4) {
                        ShortcutRecorderView(
                            shortcut: Shortcut.decode(shortcutJSON) ?? Defaults.shortcut,
                            onChange: { shortcutJSON = $0.encoded() },
                            onRecordingChange: { recording in
                                if recording {
                                    shortcutError = nil
                                    state.suspendHotkey()
                                } else if !state.applyHotkey() {
                                    shortcutError = "このショートカットは登録できません (他のアプリが使っている可能性があります)"
                                }
                            }
                        )
                        if let shortcutError {
                            Text(shortcutError).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                Text("短く押すと録音を開始し、もう一度押すと止めます。長押しすると押している間だけ録音します。Esc で取り消し。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("出力") {
                Picker("書き起こした文字列", selection: $outputMethod) {
                    ForEach(OutputMethod.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }

            Section("権限") {
                LabeledContent("マイク") {
                    if micStatus == .authorized {
                        Text("許可済み")
                    } else {
                        Button("システム設定を開く") {
                            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                        }
                    }
                }
                LabeledContent("アクセシビリティ") {
                    if axTrusted {
                        Text("許可済み")
                    } else {
                        Button("許可する") {
                            TextInserter.requestAccessibility()
                            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                        }
                    }
                }
            }

            Section {
                TextField("パス (空なら自動)", text: $speechPath, prompt: Text(SpeechWorker.resolveExecutable() ?? "見つかりません"))
                Button("worker を再起動") { state.restartWorker() }
            } header: {
                Text("speech コマンド")
            } footer: {
                Text("設定は変更するとすぐに保存され、次の録音から使われます。speech コマンドのパスだけは「worker を再起動」で反映されます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onChange(of: model) { state.restartWorker() }
        .onChange(of: shortcutJSON) {
            if !state.applyHotkey() {
                shortcutError = "このショートカットは登録できません (他のアプリが使っている可能性があります)"
            }
        }
    }

    private var workerStatus: String {
        switch state.workerState {
        case .stopped: "停止中"
        case .loading(let s): s
        case .ready: "準備完了"
        case .failed(let m): m
        }
    }

    private func refresh() {
        devices = AudioDevices.inputs()
        axTrusted = TextInserter.isTrusted
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
