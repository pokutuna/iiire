import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable {
    case general, recognition, output, apps, advanced
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
            AppRulesSettings()
                .tabItem { Label("Apps", systemImage: "app.badge") }
                .tag(SettingsTab.apps)
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
    @AppStorage(SettingsKey.soundCue) private var soundCue = Defaults.Initial.soundCue
    @AppStorage(SettingsKey.startSound) private var startSound = Defaults.Initial.startSound
    @AppStorage(SettingsKey.doneSound) private var doneSound = Defaults.Initial.doneSound
    @AppStorage(SettingsKey.cancelSound) private var cancelSound = Defaults.Initial.cancelSound

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
                                } else {
                                    applyHotkey()
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
                    // 選んだマイクが外れていても、選択を空にしない (録音はシステムの既定を使う)
                    if !inputDeviceUID.isEmpty, !devices.contains(where: { $0.uid == inputDeviceUID }) {
                        Text("Disconnected Microphone").tag(inputDeviceUID)
                    }
                }
            } footer: {
                Text("Press to start or stop. Hold to record while held. Esc cancels.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Play sound effects", isOn: $soundCue)
                if soundCue {
                    soundPicker("Start Sound", selection: $startSound)
                    soundPicker("Done Sound", selection: $doneSound)
                    soundPicker("Cancel Sound", selection: $cancelSound)
                }
            }

            Section {
                PermissionRow(
                    title: "Microphone",
                    granted: micStatus == .authorized,
                    consequence: "iiire cannot record.",
                    actionTitle: "Open System Settings"
                ) {
                    openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                }
                PermissionRow(
                    title: "Accessibility",
                    granted: axTrusted,
                    consequence: "iiire cannot type at the cursor, and a modifier key alone cannot be the hotkey.",
                    actionTitle: "Allow"
                ) {
                    TextInserter.requestAccessibility()
                    openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Permissions")
                    Text("iiire needs these permissions to record from the microphone and type at the cursor.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Settings are saved as soon as you change them and apply from the next recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .settingsForm()
        .onAppActive(perform: refresh)
        .onChange(of: shortcutJSON) { applyHotkey() }
    }

    private func applyHotkey() {
        shortcutError = state.applyHotkey()
            ? nil : String(localized: "This shortcut cannot be registered. Another app may be using it.")
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

    @AppStorage(SettingsKey.model) private var model = Defaults.Initial.model
    @AppStorage(SettingsKey.language) private var language = Defaults.Initial.language
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
        .onChange(of: model) { state.modelChanged() }
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
    @EnvironmentObject var state: AppState
    @AppStorage(SettingsKey.outputMethod) private var outputMethod = Defaults.Initial.outputMethod
    @AppStorage(SettingsKey.pasteKeystroke) private var pasteKeystroke = Defaults.Initial.pasteKeystroke
    @AppStorage(SettingsKey.pasteCustomKey) private var pasteCustomKey = ""
    @AppStorage(SettingsKey.pasteKeyIntervalMs) private var pasteKeyIntervalMs = Defaults.Initial.pasteKeyIntervalMs
    @AppStorage(SettingsKey.clipboardRestoreDelayMs) private var clipboardRestoreDelayMs = Defaults.Initial.clipboardRestoreDelayMs
    @AppStorage(SettingsKey.appRules) private var appRulesJSON = Defaults.Initial.appRules

    private var base: OutputConfig {
        .base(output: outputMethod, keystroke: pasteKeystroke, customKey: pasteCustomKey)
    }

    /// 既定とルールで実際に使う設定。どの欄を出すかの判断に使う
    private var configs: [OutputConfig] {
        [base] + AppRule.decode(appRulesJSON).map { OutputConfig.resolve(bundleID: $0.bundleID, rules: [$0], default: base) }
    }

    /// そのうちペーストするもの
    private var pasting: [OutputConfig] { configs.filter { $0.output != .clipboard } }

    var body: some View {
        Form {
            Section {
                Picker("Transcribed Text", selection: $outputMethod) {
                    ForEach(OutputMethod.allCases) { Text($0.label).tag($0.rawValue) }
                }
                if base.output != .clipboard {
                    Picker("Paste with", selection: $pasteKeystroke) {
                        ForEach(PasteKeystroke.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    if pasteKeystroke == PasteKeystroke.custom.rawValue {
                        CustomKeyField(
                            key: Binding(get: { Shortcut.decode(pasteCustomKey) }, set: { pasteCustomKey = $0?.encoded() ?? "" }),
                            fallbackNote: "Until you record a key, ⌘V is sent with right ⌘.",
                            onRecordingChange: { recording in
                                if recording { state.suspendHotkey() } else { _ = state.applyHotkey() }
                            }
                        )
                    }
                }
            } footer: {
                VStack(alignment: .trailing, spacing: 4) {
                    if base.output != .clipboard, pasteKeystroke != PasteKeystroke.custom.rawValue {
                        Text("If ⌘V is on a different key in your keyboard layout, choose Custom key and press the keys that paste.")
                    }
                    if pasting.contains(where: { $0.keystroke == .appleScript }) {
                        Text("AppleScript types the character V, so it works with most keyboard layouts. macOS asks for permission to control System Events the first time.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            if !pasting.isEmpty {
                Section {
                    if pasting.contains(where: { $0.keystroke != .appleScript }) {
                        msField("Key event interval", value: $pasteKeyIntervalMs,
                                range: Defaults.pasteKeyIntervalRange, step: 5)
                    }
                    if configs.contains(where: { $0.output == .paste }) {
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
                Text(verbatim: "ms").foregroundStyle(.secondary)
                Stepper("", value: value, in: range, step: step).labelsHidden()
            }
        }
    }
}

// MARK: - アプリ: 入力先のアプリごとのルール

private struct AppRulesSettings: View {
    @EnvironmentObject var state: AppState
    @AppStorage(SettingsKey.outputMethod) private var outputMethod = Defaults.Initial.outputMethod
    @AppStorage(SettingsKey.pasteKeystroke) private var pasteKeystroke = Defaults.Initial.pasteKeystroke
    @AppStorage(SettingsKey.pasteCustomKey) private var pasteCustomKey = ""
    @AppStorage(SettingsKey.appRules) private var appRulesJSON = Defaults.Initial.appRules
    @State private var runningApps: [RunningApp] = []

    /// 「アプリを追加」に並べる起動中のアプリ。アイコンは一覧を作るときに読む
    struct RunningApp: Identifiable {
        let id: String // bundleID
        let name: String
        let icon: NSImage
    }

    /// 「出力」タブの設定。ルールの「既定」はこれに従う
    private var base: OutputConfig {
        .base(output: outputMethod, keystroke: pasteKeystroke, customKey: pasteCustomKey)
    }

    private var rules: Binding<[AppRule]> {
        Binding(get: { AppRule.decode(appRulesJSON) }, set: { appRulesJSON = AppRule.encode($0) })
    }

    var body: some View {
        Form {
            Section {
                ForEach(rules) { $rule in
                    AppRuleRow(rule: $rule, base: base, onRecordingChange: { recording in
                        // 送るキーを記録している間は、録音のホットキーを止める
                        if recording { state.suspendHotkey() } else { _ = state.applyHotkey() }
                    }, onRemove: {
                        rules.wrappedValue.removeAll { $0.bundleID == rule.bundleID }
                    })
                }
                LabeledContent {
                    addAppMenu
                } label: {
                    if rules.wrappedValue.isEmpty {
                        Text("No rules").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("When the app in front has a rule, the rule overrides the settings in the Output tab. Items set to Default follow the Output tab.")
                    Text("A custom key is sent instead of ⌘V each time you dictate, so choose the key that pastes in that app. It must include ⌃, ⌥, ⇧ or ⌘ (or be an F key). Return, Tab, Esc, Delete, ⌘Q, ⌘W, ⌘H and ⌘M cannot be used.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .settingsForm(scrolls: true)
        .onAppActive(perform: refreshRunningApps)
    }

    /// 起動中のアプリから選ぶか、アプリケーションフォルダから選ぶ
    private var addAppMenu: some View {
        let added = Set(rules.wrappedValue.map(\.bundleID))
        let candidates = runningApps.filter { !added.contains($0.id) }
        return Menu("Add App") {
            ForEach(candidates) { app in
                Button {
                    addRule(bundleID: app.id, name: app.name)
                } label: {
                    Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                }
            }
            if !candidates.isEmpty { Divider() }
            Button("Choose from Applications…", action: chooseApp)
        }
        .fixedSize()
    }

    private func refreshRunningApps() {
        let me = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        runningApps = NSWorkspace.shared.runningApplications
            .compactMap { app -> RunningApp? in
                guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != me,
                      seen.insert(id).inserted else { return nil }
                return RunningApp(id: id, name: app.localizedName ?? id, icon: AppIcon.image(for: id, size: 16))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func addRule(bundleID: String, name: String) {
        guard !rules.wrappedValue.contains(where: { $0.bundleID == bundleID }) else { return }
        rules.wrappedValue.append(AppRule(bundleID: bundleID, name: name))
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path)
        addRule(bundleID: id, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
    }
}

/// アプリごとのルール 1 件。「既定」を選んだ項目は上の設定に従う
private struct AppRuleRow: View {
    @Binding var rule: AppRule
    let base: OutputConfig
    let onRecordingChange: (Bool) -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(nsImage: AppIcon.image(for: rule.bundleID, size: 20))
                Text(rule.name)
                Text(rule.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(action: onRemove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove Rule")
            }
            Picker("Transcribed Text", selection: $rule.output) {
                Text("Default (\(base.output.label))").tag(OutputMethod?.none)
                Divider()
                ForEach(OutputMethod.allCases) { Text($0.label).tag(Optional($0)) }
            }
            if (rule.output ?? base.output) != .clipboard {
                Picker("Paste with", selection: $rule.keystroke) {
                    Text("Default (\(base.keystrokeLabel))").tag(PasteKeystroke?.none)
                    Divider()
                    ForEach(PasteKeystroke.allCases) { Text($0.label).tag(Optional($0)) }
                }
                if rule.keystroke == .custom {
                    CustomKeyField(key: $rule.customKey,
                                   fallbackNote: "Until you record a key, the default paste method is used.",
                                   onRecordingChange: onRecordingChange)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// ⌘V の代わりに送るキーを記録する欄。送れないキーなら理由を出して保存しない
private struct CustomKeyField: View {
    @Binding var key: Shortcut?
    /// キーを記録していないときの説明
    let fallbackNote: LocalizedStringKey
    let onRecordingChange: (Bool) -> Void
    @State private var problem: String?

    var body: some View {
        LabeledContent("Key to send") {
            ShortcutRecorderView(
                shortcut: key,
                defaultShortcut: nil,
                allowsShiftOnly: true,
                onChange: { new in
                    problem = new.sendProblem
                    if problem == nil { key = new }
                },
                onRecordingChange: { recording in
                    if recording { problem = nil }
                    onRecordingChange(recording)
                }
            )
        }
        if let problem {
            Text(problem).font(.caption).foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else if key == nil {
            Text(fallbackNote).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// アプリのアイコン。見つからなければ一般的なアプリのアイコン
private enum AppIcon {
    static func image(for bundleID: String, size: CGFloat) -> NSImage {
        let image: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSWorkspace.shared.icon(for: .application)
        }
        let copy = image.copy() as! NSImage // 共有の画像を変えないよう写してから大きさを変える
        copy.size = NSSize(width: size, height: size)
        return copy
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
    /// 表示したときと、アプリに戻ってきたときに呼ぶ (システム設定での変更などを拾う)
    func onAppActive(perform action: @escaping () -> Void) -> some View {
        onAppear(perform: action)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in action() }
    }

    /// 各タブで同じ見た目にする。幅をそろえ、高さは中身に合わせる (ウィンドウの高さもこれに合う)。
    /// scrolls なら高さを決めてスクロールさせる (アプリのルールのように増えていくもの)
    func settingsForm(scrolls: Bool = false) -> some View {
        formStyle(.grouped)
            .scrollDisabled(!scrolls)
            .frame(width: 500, height: scrolls ? 520 : nil)
            .fixedSize()
    }
}

private func openURL(_ url: String) {
    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
}
