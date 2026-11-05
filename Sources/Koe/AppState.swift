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
    @Published private(set) var history: [String] = []
    @Published private(set) var lastError: String?
    /// モデル名 → ファイルを取得済みか、どこまで取得したか
    @Published private(set) var modelFiles: [String: ModelFile] = [:]
    /// 最後に始めたモデル一覧の取得。取得は順に行い、後に始めたものの結果で上書きする
    private var modelsLoad: Task<Void, Never>?
    private var watchingDownload = false
    /// 録音を始めた時刻と、使っている入力デバイスの名前 (HUD に出す)
    private(set) var recordingStartedAt: Date?
    private(set) var recordingDevice: String?

    private let worker = SpeechWorker()
    private let recorder = AudioRecorder()
    private let hotkeys = HotkeyMonitor()
    private lazy var hud = HUDController(state: self)
    private var escMonitors: [Any] = []

    /// ホットキーを押した時刻 (起動からの秒数)。この押下で録音を始めたときだけ入る
    private var pressedAt: TimeInterval?
    /// これより長く押していたら押している間だけ録音 (push-to-talk)、短ければトグル
    private let holdThreshold: TimeInterval = 0.5
    private var transcribeTask: Task<Void, Never>?
    /// 今の書き起こしの番号。取り消した後に届いた結果は捨てる
    private var transcribeID = 0
    /// 書き起こし中に Esc を一度押した。もう一度押すと worker を止める
    @Published private(set) var cancelRequested = false
    /// 録音の先頭で捨てる秒数 (開始音がマイクに入った分)
    private var leadingTrim: TimeInterval = 0
    /// 書き起こし中にモデルが変わった。書き起こしが終わってから worker を起動し直す
    private var restartAfterTranscription = false

    init() {
        worker.onStateChange = { [weak self] s in
            guard let self else { return }
            workerState = s
            if phase == .transcribing { hud.update() }
            if case .loading = s { watchModelDownload() } else { refreshModels() }
        }
        recorder.onLevel = { [weak self] l in
            Task { @MainActor in self?.hud.push(level: l) }
        }
        recorder.onDeviceLost = { [weak self] in
            Task { @MainActor in self?.deviceLost() }
        }
        hotkeys.onPress = { [weak self] in self?.hotkeyPressed(at: $0) }
        hotkeys.onRelease = { [weak self] in self?.hotkeyReleased(at: $0) }
        hotkeys.onInterrupted = { [weak self] in self?.hotkeyInterrupted() }
    }

    func launch() {
        Log.info("launch: ax=\(TextInserter.isTrusted) mic=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) shortcut=\(Defaults.shortcut.displayName) model=\(Defaults.model.id) output=\(Defaults.outputMethod.rawValue)")
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        // ペーストしない設定でも、修飾キー単独のホットキーと、他のアプリにいるときの Esc に要る
        if !TextInserter.isTrusted {
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
        restartAfterTranscription = false
        worker.start(model: Defaults.model.id)
    }

    /// 設定でモデルを変えた。書き起こし中なら、それを中断しないよう終わってから切り替える
    func modelChanged() {
        if phase == .transcribing {
            restartAfterTranscription = true
        } else {
            restartWorker()
        }
    }

    // MARK: - モデルの取得

    @discardableResult
    func refreshModels() -> Task<Void, Never> {
        let previous = modelsLoad
        let task = Task {
            await previous?.value
            modelFiles = await ModelCatalog.load()
        }
        modelsLoad = task
        return task
    }

    /// worker が準備中の間は、取得の進み具合を出すため 1 秒ごとに調べ直す。
    /// 準備が終わったときの取得は、worker の状態の変化を受けて行う
    private func watchModelDownload() {
        guard !watchingDownload else { return }
        watchingDownload = true
        Task {
            defer { watchingDownload = false }
            while case .loading = workerState {
                await refreshModels().value
                if phase == .transcribing { hud.update() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// 今のモデルを取得している最中なら、その進み具合の表示
    var downloadText: String? {
        guard case .loading = workerState else { return nil }
        let id = Defaults.model.id
        guard let f = modelFiles[id], !f.fetched else { return nil }
        let percent = f.fraction.formatted(.percent.precision(.fractionLength(0)))
        return String(localized: "Downloading \(id): \(percent) (\(ModelFile.gigabytes(f.partial)) / \(ModelFile.gigabytes(f.size)))")
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
            SoundCue.playCancel()
            setPhase(.idle)
        case .transcribing:
            // 1 回目は worker に取り消しを頼む。まだ読み込み中で頼むものがないとき、
            // または 2 回目は、待たずに worker を止めて戻る
            if cancelRequested || !worker.hasPendingRequests {
                forceStopTranscription()
            } else {
                Log.info("cancel requested")
                cancelRequested = true
                worker.cancelAll()
                hud.update()
            }
        case .idle:
            break
        }
    }

    /// 応答を待たずに書き起こしをやめる。処理中なら worker を起動し直す
    private func forceStopTranscription() {
        Log.info("transcription abandoned")
        transcribeID += 1
        transcribeTask?.cancel()
        transcribeTask = nil
        if worker.hasPendingRequests { restartWorker() } // start が前の worker を止める
        SoundCue.playCancel()
        setPhase(.idle)
    }

    func copyToClipboard(_ text: String) {
        TextInserter.put(text, on: .general, transient: false)
    }

    // MARK: - ホットキー

    private func hotkeyPressed(at time: TimeInterval) {
        Log.info("hotkey pressed (phase=\(phase))")
        switch phase {
        case .idle:
            // 長押しはキーイベントの時刻で測る。マイクを開く間に溜まったイベントを後から処理しても、
            // 押していた時間を長く見積もらない
            startRecording()
            if phase == .recording { pressedAt = time }
        case .recording:
            // トグルモードで録音中。もう一度押したら止める
            pressedAt = nil
            stopAndTranscribe()
        case .transcribing:
            break
        }
    }

    private func hotkeyReleased(at time: TimeInterval) {
        Log.info("hotkey released (phase=\(phase))")
        guard phase == .recording, let pressedAt else { return }
        self.pressedAt = nil
        if time - pressedAt >= holdThreshold {
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
        switch workerState {
        case .failed, .stopped: restartWorker()
        default: break
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            fail(String(localized: "Allow microphone access in System Settings."))
            return
        default: break
        }

        let cueAt = Date()
        SoundCue.playStart()
        Log.info("opening microphone")
        do {
            try recorder.start(deviceUID: Defaults.inputDeviceUID)
        } catch {
            Log.info("cannot start recording: \(error)")
            fail(String(localized: "Couldn't get input from the microphone."))
            return
        }
        // マイクが開くまでに開始音が鳴り終わっていなければ、その分を後で捨てる
        leadingTrim = Defaults.soundCue ? max(0, SoundCue.startAudible - Date().timeIntervalSince(cueAt)) : 0
        recordingStartedAt = Date()
        recordingDevice = recorder.deviceName
        Log.info("recording started: device=\(recorder.deviceName ?? "?") rate=\(recorder.sampleRate)")
        setPhase(.recording)
    }

    /// 録音中にマイクが止まり、録り続けられなくなった
    private func deviceLost() {
        guard phase == .recording, recorder.deviceLost else { return }
        recorder.stop()
        fail(String(localized: "Recording stopped partway."))
    }

    private func stopAndTranscribe() {
        guard phase == .recording else { return }
        if recorder.deviceLost { return deviceLost() }
        var samples = recorder.stop()
        let rate = recorder.sampleRate
        samples.removeFirst(min(samples.count, Int(leadingTrim * Double(rate))))
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let elapsed = Date().timeIntervalSince(recordingStartedAt ?? Date())
        Log.info("recording stopped: \(samples.count) samples (\(String(format: "%.2f", Double(samples.count) / Double(rate)))s of \(String(format: "%.2f", elapsed))s) peak=\(peak)")
        // マイクから音が届いていない。押していた時間で判断する (サンプル数では誤操作と区別できない)
        if elapsed > 1, samples.count < rate * 3 / 10 {
            fail(String(localized: "Couldn't get input from the microphone."))
            return
        }
        // 0.3 秒未満は誤操作とみなす
        guard samples.count > rate * 3 / 10 else {
            SoundCue.playCancel()
            setPhase(.idle)
            return
        }
        // 無音を渡すとモデルがそれらしい文を作ってしまう
        guard peak > 0.005 else {
            fail(String(localized: "No speech detected."))
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

        transcribeID += 1
        let id = transcribeID
        transcribeTask = Task {
            do {
                let raw = try await worker.transcribe(samples: samples, sampleRate: rate, options: options)
                guard id == transcribeID else { return }
                // Esc の後に結果が届いたら入力しない (取り消しより先に書き起こしが終わっていた)
                guard !cancelRequested else {
                    Log.info("transcription finished after cancel; result dropped")
                    SoundCue.playCancel()
                    setPhase(.idle)
                    return
                }
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                Log.info("transcribed: \(text.debugDescription)")
                if !text.isEmpty {
                    history.insert(text, at: 0)
                    if history.count > 10 { history.removeLast() }
                    hud.expectResult()
                    setPhase(.idle)
                    await TextInserter.insert(text) { [weak self] result in
                        if result == .notPasted { SoundCue.playCancel() } else { SoundCue.playDone() }
                        self?.hud.showResult(result, text: text)
                    }
                } else {
                    SoundCue.playCancel()
                    setPhase(.idle)
                }
            } catch is CancellationError {
                guard id == transcribeID else { return }
                Log.info("transcription cancelled")
                SoundCue.playCancel()
                setPhase(.idle)
            } catch {
                guard id == transcribeID else { return }
                Log.info("transcription failed: \(error.localizedDescription)")
                fail(String(localized: "Transcription failed."))
            }
        }
    }

    private func setPhase(_ p: Phase) {
        phase = p
        if p == .idle, restartAfterTranscription { restartWorker() }
        cancelRequested = false
        if p != .recording { pressedAt = nil }
        updateEscMonitor()
        hud.update()
    }

    private func fail(_ message: String) {
        Log.info(message)
        SoundCue.playCancel()
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
