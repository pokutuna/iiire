import AppKit
import AVFoundation
import Combine

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle, recording, transcribing
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var workerState: SpeechWorker.State = .stopped
    @Published private(set) var level: Float = 0
    @Published private(set) var history: [String] = []
    @Published private(set) var lastError: String?

    private let worker = SpeechWorker()
    private let recorder = AudioRecorder()
    private let hotkeys = HotkeyMonitor()
    private lazy var hud = HUDController(state: self)
    private var escMonitors: [Any] = []

    /// ホットキーを押した時刻。この押下で録音を始めたときだけ入る
    private var pressedAt: Date?
    /// これより長く押していたら押している間だけ録音 (push-to-talk)、短ければトグル
    private let holdThreshold: TimeInterval = 0.4
    private var transcribeTask: Task<Void, Never>?
    /// 録音の先頭で捨てる秒数 (開始音がマイクに入った分)
    private var leadingTrim: TimeInterval = 0

    init() {
        worker.onStateChange = { [weak self] s in
            guard let self else { return }
            workerState = s
            if phase == .transcribing { hud.update() }
        }
        recorder.onLevel = { [weak self] l in
            Task { @MainActor in self?.level = l }
        }
        hotkeys.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkeys.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkeys.onInterrupted = { [weak self] in self?.hotkeyInterrupted() }
    }

    func launch() {
        Log.info("launch: ax=\(TextInserter.isTrusted) mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) shortcut=\(Defaults.shortcut.displayName) model=\(Defaults.model.id) output=\(Defaults.outputMethod.rawValue)")
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        if !TextInserter.isTrusted && Defaults.outputMethod != .clipboard {
            TextInserter.requestAccessibility()
        }
        applyHotkey()
        restartWorker()
        watchAccessibility()
    }

    /// アクセシビリティ未許可のまま入れたキー監視はイベントを受け取らないので、許可されたら入れ直す
    private func watchAccessibility() {
        guard !TextInserter.isTrusted else { return }
        Task {
            while !TextInserter.isTrusted {
                try? await Task.sleep(for: .seconds(2))
            }
            Log.info("accessibility granted; reinstalling hotkey monitor")
            applyHotkey()
        }
    }

    func shutdown() {
        worker.stop()
    }

    /// 保存されたショートカットで監視し直す。登録できなければ false
    @discardableResult
    func applyHotkey() -> Bool {
        let shortcut = Defaults.shortcut
        let ok = hotkeys.start(shortcut)
        Log.info("hotkey \(ok ? "registered" : "failed to register"): \(shortcut.displayName)")
        return ok
    }

    /// 設定画面でショートカットを記録している間は、今のホットキーを止める
    func suspendHotkey() {
        hotkeys.stop()
    }

    func restartWorker() {
        worker.start(model: Defaults.model.id)
    }

    // MARK: - 操作

    func toggleFromMenu() {
        switch phase {
        case .idle: startRecording()
        case .recording: stopAndTranscribe()
        case .transcribing: break
        }
    }

    func cancel() {
        switch phase {
        case .recording:
            recorder.stop()
            setPhase(.idle)
        case .transcribing:
            worker.cancelAll()
        case .idle:
            break
        }
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - ホットキー

    private func hotkeyPressed() {
        Log.info("hotkey pressed (phase=\(phase))")
        switch phase {
        case .idle:
            startRecording()
            if phase == .recording { pressedAt = Date() }
        case .recording:
            // トグルモードで録音中。もう一度押したら止める
            pressedAt = nil
            stopAndTranscribe()
        case .transcribing:
            break
        }
    }

    private func hotkeyReleased() {
        Log.info("hotkey released (phase=\(phase))")
        guard phase == .recording, let pressedAt else { return }
        self.pressedAt = nil
        if Date().timeIntervalSince(pressedAt) >= holdThreshold {
            stopAndTranscribe()
        }
    }

    /// 修飾キーを別のショートカットの一部として使ったので、始めた録音を捨てる
    private func hotkeyInterrupted() {
        guard phase == .recording, pressedAt != nil else { return }
        pressedAt = nil
        cancel()
    }

    // MARK: - 録音と書き起こし

    private func startRecording() {
        guard phase == .idle else { return }
        lastError = nil
        if case .failed = workerState { restartWorker() }
        if case .stopped = workerState { restartWorker() }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            fail(String(localized: "Microphone access is not allowed (System Settings > Privacy & Security > Microphone)."))
            return
        default: break
        }

        let cueAt = Date()
        SoundCue.playStart()
        do {
            try recorder.start(deviceUID: Defaults.inputDeviceUID)
        } catch {
            fail(String(localized: "Cannot start recording: \(error.localizedDescription)"))
            return
        }
        // マイクが開くまでに開始音が鳴り終わっていなければ、その分を後で捨てる
        leadingTrim = Defaults.soundCue ? max(0, SoundCue.startAudible - Date().timeIntervalSince(cueAt)) : 0
        Log.info("recording started: device=\(Defaults.inputDeviceUID.isEmpty ? "default" : Defaults.inputDeviceUID) rate=\(recorder.sampleRate)")
        setPhase(.recording)
    }

    private func stopAndTranscribe() {
        guard phase == .recording else { return }
        var samples = recorder.stop()
        SoundCue.playStop()
        let rate = recorder.sampleRate
        samples.removeFirst(min(samples.count, Int(leadingTrim * Double(rate))))
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        Log.info("recording stopped: \(samples.count) samples (\(String(format: "%.2f", Double(samples.count) / Double(rate)))s) peak=\(peak)")
        // 0.3 秒未満は誤操作とみなす
        guard samples.count > rate * 3 / 10 else {
            setPhase(.idle)
            return
        }
        // 無音を渡すとモデルがそれらしい文を作ってしまう
        guard peak > 0.005 else {
            fail(String(localized: "No sound from the microphone. Check the microphone in Settings."))
            return
        }
        // 入力が小さいマイク向けに、ピークが 0.5 になるまで持ち上げる (最大 10 倍)
        if peak < 0.5 {
            let gain = min(0.5 / peak, 10)
            for i in samples.indices { samples[i] *= gain }
        }
        setPhase(.transcribing)

        let model = Defaults.model
        var options: [String: Any] = [:]
        let hint = Defaults.hint.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.takesPrompt {
            if Defaults.language != "auto" { options["language"] = Defaults.language }
            if !hint.isEmpty { options["prompt"] = hint }
        }
        if model.takesKeywords, !hint.isEmpty {
            options["keywords"] = hint
        }

        transcribeTask = Task {
            do {
                let raw = try await worker.transcribe(samples: samples, sampleRate: rate, options: options)
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                Log.info("transcribed: \(text.debugDescription)")
                if !text.isEmpty {
                    history.insert(text, at: 0)
                    if history.count > 10 { history.removeLast() }
                    setPhase(.idle)
                    await TextInserter.insert(text, method: Defaults.outputMethod)
                } else {
                    setPhase(.idle)
                }
            } catch is CancellationError {
                Log.info("transcription cancelled")
                setPhase(.idle)
            } catch {
                fail(String(localized: "Transcription failed: \(error.localizedDescription)"))
            }
        }
    }

    private func setPhase(_ p: Phase) {
        phase = p
        if p != .recording { level = 0 }
        updateEscMonitor()
        hud.update()
    }

    private func fail(_ message: String) {
        Log.info("\(message)")
        lastError = message
        setPhase(.idle)
        hud.flash(message)
    }

    /// 録音中・書き起こし中は Esc で取り消せる
    private func updateEscMonitor() {
        let active = phase != .idle
        if active, escMonitors.isEmpty {
            let handler: (NSEvent) -> Void = { [weak self] e in
                if e.keyCode == 53 { Task { @MainActor in self?.cancel() } }
            }
            if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) { escMonitors.append(m) }
            if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handler($0); return $0 }) { escMonitors.append(m) }
        } else if !active, !escMonitors.isEmpty {
            escMonitors.forEach(NSEvent.removeMonitor)
            escMonitors = []
        }
    }
}
