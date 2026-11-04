import Foundation

/// `speech worker MODEL` を子プロセスとして起動し、JSON Lines で認識を依頼する。
/// プロトコル: https://github.com/nyosegawa/speech.cpp/blob/main/docs/worker.md
@MainActor
final class SpeechWorker {
    enum State: Equatable {
        case stopped
        case loading(String)   // モデルの取得・読み込み中 (stderr の最終行)
        case ready
        case failed(String)
    }

    struct WorkerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    var onStateChange: ((State) -> Void)?
    private(set) var state: State = .stopped {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    private(set) var modelName: String?

    private var process: Process?
    private var stdin: FileHandle?
    private let writeQueue = DispatchQueue(label: "koe.worker.write")
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var pending: [String: CheckedContinuation<String, Error>] = [:]
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var nextID = 0

    /// 実行する `speech` コマンドのパスを決める。
    /// 設定 > .app 同梱 > ~/.local/bin > Homebrew の順。
    static func resolveExecutable() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        let configured = Defaults.speechPath.trimmingCharacters(in: .whitespaces)
        if !configured.isEmpty { candidates.append((configured as NSString).expandingTildeInPath) }
        if let env = ProcessInfo.processInfo.environment["KOE_SPEECH"] { candidates.append(env) }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "speech")?.path { candidates.append(bundled) }
        candidates += [
            NSHomeDirectory() + "/.local/bin/speech",
            "/opt/homebrew/bin/speech",
            "/usr/local/bin/speech",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    func start(model: String) {
        stop()
        guard let exe = Self.resolveExecutable() else {
            state = .failed("speech コマンドが見つかりません。設定でパスを指定してください")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["worker", model]
        var env = ProcessInfo.processInfo.environment
        env["SPEECH_NO_UPDATE_CHECK"] = "1"
        env["NO_COLOR"] = "1"
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            Task { @MainActor in self?.receiveStdout(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            Task { @MainActor in self?.receiveStderr(data) }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in self?.didTerminate(proc, status: status) }
        }

        do {
            try p.run()
        } catch {
            state = .failed("speech worker を起動できません: \(error.localizedDescription)")
            return
        }
        process = p
        stdin = inPipe.fileHandleForWriting
        modelName = model
        state = .loading("\(model) を準備中…")
    }

    func stop() {
        guard let p = process else { return }
        process = nil
        try? stdin?.close()
        stdin = nil
        if p.isRunning { p.terminate() }
        failAll(WorkerError(message: "worker を停止しました"))
        state = .stopped
    }

    /// モノラル PCM (Float, -1...1) を認識する。
    func transcribe(samples: [Float], sampleRate: Int, options: [String: Any]) async throws -> String {
        try await waitUntilReady()
        nextID += 1
        let id = "r\(nextID)"

        // 1 行が大きくなりすぎないよう 1 秒ずつ chunk にする
        var lines: [[String: Any]] = []
        var seq = 0
        var offset = 0
        while offset < samples.count {
            let end = min(offset + sampleRate, samples.count)
            lines.append(["type": "chunk", "id": id, "seq": seq, "pcm": Self.pcm16Base64(samples[offset..<end])])
            seq += 1
            offset = end
        }
        var req: [String: Any] = ["type": "transcribe", "id": id, "sample_rate": sampleRate]
        req.merge(options) { _, new in new }
        lines.append(req)

        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            send(lines)
        }
    }

    func cancelAll() {
        for id in pending.keys { send([["type": "cancel", "id": id]]) }
    }

    // MARK: - private

    private func waitUntilReady() async throws {
        switch state {
        case .ready: return
        case .loading: break
        case .stopped, .failed:
            throw WorkerError(message: stateMessage)
        }
        try await withCheckedThrowingContinuation { readyWaiters.append($0) }
    }

    private var stateMessage: String {
        switch state {
        case .failed(let m): m
        case .loading(let m): m
        case .stopped: "worker が起動していません"
        case .ready: "ready"
        }
    }

    private func send(_ objects: [[String: Any]]) {
        guard let stdin else { return }
        var data = Data()
        for obj in objects {
            guard let line = try? JSONSerialization.data(withJSONObject: obj) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        writeQueue.async {
            do { try stdin.write(contentsOf: data) } catch {
                Log.info("write to worker failed: \(error)")
            }
        }
    }

    private static func pcm16Base64(_ samples: ArraySlice<Float>) -> String {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (i, x) in samples.enumerated() {
                let v = max(-1, min(1, x)) * 32767
                out[i] = Int16(v.rounded()).littleEndian
            }
        }
        return data.base64EncodedString()
    }

    private func receiveStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer[stdoutBuffer.startIndex..<nl]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            handle(type: type, obj: obj)
        }
    }

    private func handle(type: String, obj: [String: Any]) {
        let id = obj["id"] as? String
        switch type {
        case "ready":
            state = .ready
            let waiters = readyWaiters
            readyWaiters = []
            waiters.forEach { $0.resume() }
        case "fatal":
            let msg = Self.errorMessage(obj)
            state = .failed(msg)
            failAll(WorkerError(message: msg))
        case "end":
            if let id, let cont = pending.removeValue(forKey: id) {
                cont.resume(returning: (obj["text"] as? String) ?? "")
            }
        case "error":
            let err = WorkerError(message: Self.errorMessage(obj))
            if let id, let cont = pending.removeValue(forKey: id) {
                cont.resume(throwing: err)
            } else {
                Log.info("worker error: \(err.message)")
            }
        case "cancelled":
            if let id, let cont = pending.removeValue(forKey: id) {
                cont.resume(throwing: CancellationError())
            }
        default:
            break // progress など
        }
    }

    private static func errorMessage(_ obj: [String: Any]) -> String {
        let e = obj["error"] as? [String: Any]
        let code = e?["code"] as? String ?? "error"
        let msg = e?["message"] as? String ?? ""
        return "\(code): \(msg)"
    }

    private func receiveStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        stderrBuffer.append(data)
        if stderrBuffer.count > 8192 { stderrBuffer = stderrBuffer.suffix(4096) }
        // 進捗表示のため、ロード中は stderr の最終行を状態に出す
        guard case .loading = state,
              let text = String(data: stderrBuffer, encoding: .utf8) else { return }
        let last = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if !last.isEmpty { state = .loading(last) }
    }

    private func didTerminate(_ proc: Process, status: Int32) {
        guard proc === process else { return } // stop() で止めたもの
        process = nil
        stdin = nil
        let tail = String(data: stderrBuffer, encoding: .utf8)?
            .split(separator: "\n").last.map(String.init) ?? ""
        let msg: String
        if case .failed(let m) = state { msg = m } else { msg = "worker が終了しました (status \(status)) \(tail)" }
        state = .failed(msg)
        failAll(WorkerError(message: msg))
    }

    private func failAll(_ error: Error) {
        let conts = pending.values
        pending = [:]
        conts.forEach { $0.resume(throwing: error) }
        let waiters = readyWaiters
        readyWaiters = []
        waiters.forEach { $0.resume(throwing: error) }
    }
}
