import AVFoundation
import CoreAudio

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDevices {
    /// 入力チャンネルを持つデバイスの一覧
    static func inputs() -> [AudioInputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    static func device(uid: String) -> AudioInputDevice? {
        inputs().first { $0.uid == uid }
    }

    /// システムの既定の入力デバイスの名前
    static func defaultInputName() -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return stringProperty(id, kAudioObjectPropertyName)
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let v = value?.takeRetainedValue() else { return nil }
        return v as String
    }
}

/// マイクから録音し、モノラル Float のサンプルを溜める。
/// 録音のたびに AVAudioEngine を作り直す (待機中にマイクを掴まないため)。
final class AudioRecorder {
    private var engine: AVAudioEngine?
    /// 今の録音の溜め先。録音ごとに作り直すので、止めた後に古い tap から届いた音は次の録音に混ざらない
    private var session: Session?
    private(set) var sampleRate: Int = 48000
    /// 録音に使っているデバイスの名前
    private(set) var deviceName: String?
    /// 時限を過ぎてもまだ戻らない、前の開く処理。戻るまでは次を始めない (スレッドが溜まらないように)
    private var stuckAttempt: StartAttempt?
    private var configObserver: NSObjectProtocol?

    /// マイクを開くのを待つ時間。CoreAudio が応答しなくなると開く処理が戻らないことがあるので、
    /// 別のスレッドで開き、これを過ぎたらあきらめる (アプリ全体が止まらないように)
    static let startTimeout: TimeInterval = 3
    static let stopTimeout: TimeInterval = 2

    /// 0...1 の入力レベル。録音スレッドから呼ばれる
    var onLevel: ((Float) -> Void)?

    struct TimeoutError: LocalizedError {
        var errorDescription: String? {
            String(localized: "The microphone did not respond. Reconnect it or choose another microphone in Settings.")
        }
    }

    /// 1 回の録音のサンプル。閉じた後は受け付けない
    private final class Session: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []
        private var closed = false

        func append(_ mono: [Float]) -> Bool {
            lock.withLock {
                guard !closed else { return false }
                samples.append(contentsOf: mono)
                return true
            }
        }

        func close() -> [Float] {
            lock.withLock {
                closed = true
                defer { samples = [] }
                return samples
            }
        }
    }

    /// 別スレッドでの開く処理の結果。時限を過ぎてから開けたら、そのスレッドが自分で閉じる
    private final class StartAttempt: @unchecked Sendable {
        let lock = NSLock()
        var finished = false
        var abandoned = false
        var opened: (engine: AVAudioEngine, sampleRate: Int, deviceName: String?)?
        var error: Error?
    }

    func start(deviceUID: String) throws {
        stop()
        if let stuck = stuckAttempt {
            guard stuck.lock.withLock({ stuck.finished }) else {
                Log.info("microphone is still not responding")
                throw TimeoutError()
            }
            stuckAttempt = nil
        }

        let session = Session()
        let attempt = StartAttempt()
        let done = DispatchSemaphore(value: 0)
        let tap: (AVAudioPCMBuffer) -> Void = { [weak self] buffer in self?.append(buffer, to: session) }
        Thread.detachNewThread {
            let result = Result { try Self.openEngine(deviceUID: deviceUID, tap: tap) }
            let abandoned = attempt.lock.withLock {
                attempt.finished = true
                switch result {
                case .success(let opened): attempt.opened = opened
                case .failure(let error): attempt.error = error
                }
                return attempt.abandoned
            }
            done.signal()
            // あきらめた後に開けたら閉じる。CoreAudio の呼び出しはロックの外で行う (詰まっても次の録音を止めない)
            if abandoned, case .success(let opened) = result {
                Log.info("microphone opened after the timeout; closing it")
                _ = session.close()
                opened.engine.inputNode.removeTap(onBus: 0)
                opened.engine.stop()
            }
        }

        let inTime = done.wait(timeout: .now() + Self.startTimeout) == .success
        let opened = try attempt.lock.withLock {
            if !inTime, !attempt.finished {
                attempt.abandoned = true
                return nil as (engine: AVAudioEngine, sampleRate: Int, deviceName: String?)?
            }
            if let error = attempt.error { throw error }
            return attempt.opened
        }
        guard let opened else {
            stuckAttempt = attempt
            _ = session.close()
            Log.info("microphone did not open within \(Self.startTimeout)s")
            throw TimeoutError()
        }
        (engine, sampleRate, deviceName) = opened
        self.session = session
        // 録音中にデバイスが変わると、エンジンが止まって音が届かなくなることがある
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
            Log.info("audio engine configuration changed (device changed or disconnected)")
        }
    }

    /// AVAudioEngine を作り、デバイスを選んで録音を始める。別スレッドで呼ぶ
    private static func openEngine(deviceUID: String, tap: @escaping (AVAudioPCMBuffer) -> Void)
        throws -> (engine: AVAudioEngine, sampleRate: Int, deviceName: String?) {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        var name: String?
        if !deviceUID.isEmpty, let device = AudioDevices.device(uid: deviceUID), let unit = input.audioUnit {
            var id = device.id
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status == noErr {
                name = device.name
            } else {
                Log.info("failed to select input device \(device.name): \(status)")
            }
        }
        if name == nil { name = AudioDevices.defaultInputName() }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Koe", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Cannot open the input device.")])
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in tap(buffer) }
        engine.prepare()
        try engine.start()
        return (engine, Int(format.sampleRate), name)
    }

    /// 録音を止め、溜めたサンプルを返す。止める処理が戻らなくても、溜めた分は返す
    @discardableResult
    func stop() -> [Float] {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        let samples = session?.close() ?? []
        session = nil
        if let engine {
            self.engine = nil
            let done = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                done.signal()
            }
            if done.wait(timeout: .now() + Self.stopTimeout) == .timedOut {
                Log.info("microphone did not stop within \(Self.stopTimeout)s")
            }
        }
        return samples
    }

    private func append(_ buffer: AVAudioPCMBuffer, to session: Session) {
        guard let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<channels {
            let ch = data[c]
            for i in 0..<n { mono[i] += ch[i] }
        }
        if channels > 1 {
            let k = 1 / Float(channels)
            for i in 0..<n { mono[i] *= k }
        }
        var sum: Float = 0
        for x in mono { sum += x * x }
        let rms = sqrt(sum / Float(max(n, 1)))
        guard session.append(mono) else { return }
        // 人の声の RMS はおおよそ 0.01-0.2 なので対数で 0...1 に寄せる
        let level = max(0, min(1, (20 * log10(max(rms, 1e-5)) + 50) / 40))
        onLevel?(level)
    }
}
