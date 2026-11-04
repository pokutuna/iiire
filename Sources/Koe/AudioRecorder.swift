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
    private let lock = NSLock()
    private var samples: [Float] = []
    private(set) var sampleRate: Int = 48000

    /// 0...1 の入力レベル。録音スレッドから呼ばれる
    var onLevel: ((Float) -> Void)?

    func start(deviceUID: String) throws {
        stop()
        lock.withLock { samples = [] }

        let engine = AVAudioEngine()
        let input = engine.inputNode

        if !deviceUID.isEmpty, let device = AudioDevices.device(uid: deviceUID), let unit = input.audioUnit {
            var id = device.id
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { Log.info("failed to select input device \(device.name): \(status)") }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Koe", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Cannot open the input device.")])
        }
        sampleRate = Int(format.sampleRate)

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// 録音を止め、溜めたサンプルを返す
    @discardableResult
    func stop() -> [Float] {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        return lock.withLock {
            let s = samples
            samples = []
            return s
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
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
        lock.withLock { samples.append(contentsOf: mono) }
        // 人の声の RMS はおおよそ 0.01-0.2 なので対数で 0...1 に寄せる
        let level = max(0, min(1, (20 * log10(max(rms, 1e-5)) + 50) / 40))
        onLevel?(level)
    }
}
