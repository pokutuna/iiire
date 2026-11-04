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
    @AppStorage(SettingsKey.soundCue) private var soundCue = true
    @AppStorage(SettingsKey.startSound) private var startSound = "Tink"
    @AppStorage(SettingsKey.stopSound) private var stopSound = "Pop"
    @State private var soundNames: [String] = []
    @AppStorage(SettingsKey.speechPath) private var speechPath = ""

    @State private var devices: [AudioInputDevice] = []
    @State private var axTrusted = TextInserter.isTrusted
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        Form {
            Section("Speech Recognition") {
                Picker("Model", selection: $model) {
                    ForEach(RecognitionModel.all) { Text($0.label).tag($0.id) }
                }
                if RecognitionModel.find(model).takesPrompt {
                    Picker("Language", selection: $language) {
                        Text("Automatic").tag("auto")
                        Text("Japanese").tag("ja")
                        Text("English").tag("en")
                    }
                }
                let m = RecognitionModel.find(model)
                if m.takesPrompt || m.takesKeywords {
                    VStack(alignment: .leading, spacing: 4) {
                        m.takesPrompt ? Text("Hint (names and terms)") : Text("Vocabulary (one per line, written=reading)")
                        TextEditor(text: $hint)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 60)
                    }
                }
                LabeledContent("Status", value: workerStatus)
            }

            Section("Input") {
                Picker("Microphone", selection: $inputDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(devices) { Text($0.name).tag($0.uid) }
                }
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
                                    shortcutError = String(localized: "This shortcut cannot be registered. Another app may be using it.")
                                }
                            }
                        )
                        if let shortcutError {
                            Text(shortcutError).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                Text("Press briefly to start recording and press again to stop. Hold to record only while held. Esc cancels.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Play sounds when recording starts and stops", isOn: $soundCue)
                if soundCue {
                    soundPicker("Start Sound", selection: $startSound)
                    soundPicker("Stop Sound", selection: $stopSound)
                }
            }

            Section("Output") {
                Picker("Transcribed Text", selection: $outputMethod) {
                    ForEach(OutputMethod.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }

            Section("Permissions") {
                LabeledContent("Microphone") {
                    if micStatus == .authorized {
                        Text("Granted")
                    } else {
                        Button("Open System Settings") {
                            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                        }
                    }
                }
                LabeledContent("Accessibility") {
                    if axTrusted {
                        Text("Granted")
                    } else {
                        Button("Allow") {
                            TextInserter.requestAccessibility()
                            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                        }
                    }
                }
            }

            Section {
                TextField("Path (automatic if empty)", text: $speechPath, prompt: Text(SpeechWorker.resolveExecutable() ?? String(localized: "Not found")))
                Button("Restart Worker") { state.restartWorker() }
            } header: {
                Text("speech Command")
            } footer: {
                Text("Settings are saved as soon as you change them and apply from the next recording. Only the speech command path needs “Restart Worker” to take effect.")
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
                shortcutError = String(localized: "This shortcut cannot be registered. Another app may be using it.")
            }
        }
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

    private var workerStatus: String {
        switch state.workerState {
        case .stopped: String(localized: "Stopped")
        case .loading(let s): s
        case .ready: String(localized: "Ready")
        case .failed(let m): m
        }
    }

    private func refresh() {
        devices = AudioDevices.inputs()
        soundNames = SoundCue.availableNames()
        axTrusted = TextInserter.isTrusted
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
