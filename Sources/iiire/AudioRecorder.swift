import AudioToolbox
import CoreAudio
import Foundation

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

    /// システムの既定の入力デバイス
    static func defaultInputID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    static func name(_ id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioObjectPropertyName)
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
/// AUHAL (CoreAudio の入出力ユニット) で直接録る。AVAudioEngine は、他のアプリ (Google Meet など) が
/// マイクの設定を変えると止まってしまうため。録音のたびに開き直す (待機中にマイクを掴まないため)。
final class AudioRecorder {
    private var capture: Capture?
    /// 今の録音の溜め先。録音ごとに作り直すので、止めた後に届いた音は次の録音に混ざらない
    private var session: Session?
    private(set) var sampleRate: Int = 48000
    /// 録音に使っているデバイスの名前
    private(set) var deviceName: String?
    /// 時限を過ぎてもまだ戻らない、前の開く処理。戻るまでは次を始めない (スレッドが溜まらないように)
    private var stuckAttempt: StartAttempt?

    /// マイクを開くのを待つ時間。CoreAudio が応答しなくなると開く処理が戻らないことがあるので、
    /// 別のスレッドで開き、これを過ぎたらあきらめる (アプリ全体が止まらないように)
    static let startTimeout: TimeInterval = 3
    static let stopTimeout: TimeInterval = 2

    /// 0...1 の入力レベル。録音スレッドから呼ばれる
    var onLevel: ((Float) -> Void)?
    /// 録音中にマイクの形式が変わり、合わせ直せなかった。別のスレッドから呼ばれる
    var onDeviceLost: (() -> Void)?

    /// 今の録音が、途中でマイクから録れなくなった
    var deviceLost: Bool { session?.lost ?? false }

    /// マイクが時限内に開かなかった
    struct TimeoutError: Error {}

    /// 1 回の録音のサンプル。閉じた後は受け付けない
    private final class Session: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []
        private var closed = false
        private var isLost = false
        /// 溜めるサンプルのレート。録音の途中でマイクのレートが変わったら、このレートに直して溜める
        let rate: Double

        init(rate: Double) {
            self.rate = rate
        }

        func append(_ mono: [Float], rate: Double) -> Bool {
            let mono = rate == self.rate ? mono : Self.resample(mono, from: rate, to: self.rate)
            return lock.withLock {
                guard !closed else { return false }
                samples.append(contentsOf: mono)
                return true
            }
        }

        var lost: Bool { lock.withLock { isLost } }

        func markLost() {
            lock.withLock { isLost = true }
        }

        func close() -> [Float] {
            lock.withLock {
                closed = true
                defer { samples = [] }
                return samples
            }
        }

        /// 線形補間。録音の途中でレートが変わったときだけ使うので、簡単なものにする
        private static func resample(_ x: [Float], from: Double, to: Double) -> [Float] {
            let n = Int(Double(x.count) * to / from)
            guard n > 0 else { return [] }
            return (0..<n).map { i in
                let p = Double(i) * from / to
                let j = min(Int(p), x.count - 1)
                let k = min(j + 1, x.count - 1)
                return x[j] + (x[k] - x[j]) * Float(p - Double(j))
            }
        }
    }

    /// 開いた AUHAL と、録音スレッドで使う受け皿。開いた後の AUHAL の操作は queue で順に行う
    private final class Capture: @unchecked Sendable {
        let unit: AudioUnit
        let session: Session
        let onLevel: (Float) -> Void
        let onLost: () -> Void
        let queue = DispatchQueue(label: "iiire.recorder")
        /// AUHAL から受け取る形式 (デバイスに合わせる。AUHAL は入力のレートを変換しない)
        private(set) var rate: Double = 0
        private(set) var channels = 0
        private var buffer: UnsafeMutablePointer<Float>?
        private var capacity = 0
        private var closed = false

        init(unit: AudioUnit, session: Session, onLevel: @escaping (Float) -> Void, onLost: @escaping () -> Void) {
            self.unit = unit
            self.session = session
            self.onLevel = onLevel
            self.onLost = onLost
        }

        deinit { buffer?.deallocate() }

        /// デバイスの今の形式に合わせて、受け取る形式を決める。初期化する前に呼ぶ
        func matchDeviceFormat() throws {
            let device = try deviceFormat(unit)
            let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let ch = UInt32(device.mChannelsPerFrame)
            var format = AudioStreamBasicDescription(
                mSampleRate: device.mSampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4 * ch, mFramesPerPacket: 1, mBytesPerFrame: 4 * ch,
                mChannelsPerFrame: ch, mBitsPerChannel: 32, mReserved: 0)
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, size), "set client format")
            rate = device.mSampleRate
            channels = Int(ch)
            buffer?.deallocate()
            capacity = 8192 * channels
            buffer = .allocate(capacity: capacity)
        }

        /// 他のアプリがマイクのレートなどを変えたら、受け取る形式を合わせ直す。
        /// 合わせ直すと通知がまた届くので、形式が変わっていなければ何もしない
        func followDeviceFormat() {
            guard !closed, let device = try? deviceFormat(unit),
                  device.mSampleRate != rate || Int(device.mChannelsPerFrame) != channels else { return }
            Log.info("microphone format changed: \(rate)Hz \(channels)ch -> \(device.mSampleRate)Hz \(device.mChannelsPerFrame)ch")
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            do {
                try matchDeviceFormat()
                try check(AudioUnitInitialize(unit), "initialize")
                try check(AudioOutputUnitStart(unit), "start")
            } catch {
                Log.info("could not follow the microphone format change: \(error)")
                session.markLost()
                onLost()
            }
        }

        func close() {
            closed = true
            AudioOutputUnitStop(unit)
            AudioUnitRemovePropertyListenerWithUserData(unit, kAudioUnitProperty_StreamFormat, Capture.formatChanged,
                                                        Unmanaged.passUnretained(self).toOpaque())
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }

        /// 録音スレッドで呼ばれる
        func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ time: UnsafePointer<AudioTimeStamp>,
                    _ bus: UInt32, _ frames: UInt32) -> OSStatus {
            let n = Int(frames), ch = channels
            guard let buffer, n * ch <= capacity else { return noErr }
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: UInt32(ch), mDataByteSize: UInt32(n * ch * 4), mData: buffer))
            let status = AudioUnitRender(unit, flags, time, bus, frames, &list)
            guard status == noErr else { return status }
            var mono = [Float](repeating: 0, count: n)
            var sum: Float = 0
            for i in 0..<n {
                var v: Float = 0
                for c in 0..<ch { v += buffer[i * ch + c] }
                v /= Float(ch)
                mono[i] = v
                sum += v * v
            }
            guard session.append(mono, rate: rate) else { return noErr }
            // 人の声の RMS はおおよそ 0.01-0.2 なので対数で 0...1 に寄せる
            let rms = sqrt(sum / Float(max(n, 1)))
            onLevel(max(0, min(1, (20 * log10(max(rms, 1e-5)) + 50) / 40)))
            return noErr
        }

        static let inputProc: AURenderCallback = { refCon, flags, time, bus, frames, _ in
            Unmanaged<Capture>.fromOpaque(refCon).takeUnretainedValue().render(flags, time, bus, frames)
        }

        static let formatChanged: AudioUnitPropertyListenerProc = { refCon, _, _, scope, element in
            guard scope == kAudioUnitScope_Input, element == 1 else { return }
            let capture = Unmanaged<Capture>.fromOpaque(refCon).takeUnretainedValue()
            capture.queue.async { capture.followDeviceFormat() }
        }
    }

    /// 別スレッドでの開く処理の結果。時限を過ぎてから開けたら、そのスレッドが自分で閉じる
    private final class StartAttempt: @unchecked Sendable {
        let lock = NSLock()
        var finished = false
        var abandoned = false
        var opened: (capture: Capture, deviceName: String?)?
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

        let attempt = StartAttempt()
        let done = DispatchSemaphore(value: 0)
        let onLevel: (Float) -> Void = { [weak self] in self?.onLevel?($0) }
        let onLost: () -> Void = { [weak self] in self?.onDeviceLost?() }
        Thread.detachNewThread {
            let result = Result { try Self.open(deviceUID: deviceUID, onLevel: onLevel, onLost: onLost) }
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
                _ = opened.capture.session.close()
                opened.capture.queue.async { opened.capture.close() }
            }
        }

        let inTime = done.wait(timeout: .now() + Self.startTimeout) == .success
        let opened = try attempt.lock.withLock {
            if !inTime, !attempt.finished {
                attempt.abandoned = true
                return nil as (capture: Capture, deviceName: String?)?
            }
            if let error = attempt.error { throw error }
            return attempt.opened
        }
        guard let opened else {
            stuckAttempt = attempt
            Log.info("microphone did not open within \(Self.startTimeout)s")
            throw TimeoutError()
        }
        capture = opened.capture
        session = opened.capture.session
        sampleRate = Int(opened.capture.session.rate)
        deviceName = opened.deviceName
    }

    /// AUHAL を開き、デバイスを選んで録音を始める。別スレッドで呼ぶ
    private static func open(deviceUID: String, onLevel: @escaping (Float) -> Void,
                             onLost: @escaping () -> Void) throws -> (capture: Capture, deviceName: String?) {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        var instance: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &desc) else { throw openError(0) }
        try check(AudioComponentInstanceNew(component, &instance), "create audio unit")
        guard let unit = instance else { throw openError(0) }
        do {
            var on: UInt32 = 1, off: UInt32 = 0
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, 4), "enable input")
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, 4), "disable output")

            func select(_ id: AudioDeviceID) -> OSStatus {
                var id = id
                return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                            &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            }
            var name: String?
            if !deviceUID.isEmpty, let device = AudioDevices.device(uid: deviceUID) {
                let status = select(device.id)
                if status == noErr { name = device.name } else { Log.info("failed to select input device \(device.name): \(status)") }
            }
            if name == nil {
                guard let id = AudioDevices.defaultInputID() else { throw openError(0) }
                try check(select(id), "select default input device")
                name = AudioDevices.name(id)
            }

            // 録音を始めたときのデバイスのレートで溜める
            let capture = Capture(unit: unit, session: Session(rate: try deviceFormat(unit).mSampleRate),
                                  onLevel: onLevel, onLost: onLost)
            try capture.matchDeviceFormat()
            let context = Unmanaged.passUnretained(capture).toOpaque()
            var callback = AURenderCallbackStruct(inputProc: Capture.inputProc, inputProcRefCon: context)
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                           &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set input callback")
            try check(AudioUnitAddPropertyListener(unit, kAudioUnitProperty_StreamFormat, Capture.formatChanged, context), "add format listener")
            try check(AudioUnitInitialize(unit), "initialize")
            try check(AudioOutputUnitStart(unit), "start")
            return (capture, name)
        } catch {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    /// 録音を止め、溜めたサンプルを返す。止める処理が戻らなくても、溜めた分は返す
    @discardableResult
    func stop() -> [Float] {
        let samples = session?.close() ?? []
        session = nil
        if let capture {
            self.capture = nil
            let done = DispatchSemaphore(value: 0)
            capture.queue.async {
                capture.close()
                done.signal()
            }
            if done.wait(timeout: .now() + Self.stopTimeout) == .timedOut {
                Log.info("microphone did not stop within \(Self.stopTimeout)s")
            }
        }
        return samples
    }
}

/// AUHAL の入力側 (デバイス側) の形式
private func deviceFormat(_ unit: AudioUnit) throws -> AudioStreamBasicDescription {
    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &format, &size), "get device format")
    guard format.mSampleRate > 0, format.mChannelsPerFrame > 0 else { throw openError(0) }
    return format
}

private func check(_ status: OSStatus, _ what: String) throws {
    guard status != noErr else { return }
    Log.info("microphone: \(what) failed: \(status)")
    throw openError(status)
}

private func openError(_ status: OSStatus) -> Error {
    NSError(domain: "iiire", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Cannot open the input device."])
}
