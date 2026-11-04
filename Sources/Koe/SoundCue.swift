import AppKit

/// 録音の開始・終了を知らせる効果音。macOS のシステムサウンドを名前で鳴らす。
@MainActor
enum SoundCue {
    /// 開始音がマイクに入りうる時間。この間に録れた音は捨てる
    static let startAudible: TimeInterval = 0.2

    private static var cache: [String: NSSound] = [:]

    static func playStart() {
        guard Defaults.soundCue else { return }
        play(Defaults.startSound)
    }

    static func playStop() {
        guard Defaults.soundCue else { return }
        play(Defaults.stopSound)
    }

    /// 設定画面での試聴
    static func preview(_ name: String) {
        play(name)
    }

    /// NSSound(named:) が探す場所にある音の名前
    static func availableNames() -> [String] {
        let dirs = [
            NSHomeDirectory() + "/Library/Sounds",
            "/Library/Sounds",
            "/System/Library/Sounds",
        ]
        let exts: Set<String> = ["aiff", "aif", "wav", "caf", "mp3", "m4a"]
        var names = Set<String>()
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for f in files where exts.contains((f as NSString).pathExtension.lowercased()) {
                names.insert((f as NSString).deletingPathExtension)
            }
        }
        return names.sorted()
    }

    private static func play(_ name: String) {
        let sound = cache[name] ?? NSSound(named: NSSound.Name(name))
        guard let sound else { return } // 見つからなければ鳴らさない
        cache[name] = sound
        sound.volume = 0.6
        sound.stop() // 鳴っている途中でも頭から鳴らし直す
        sound.play()
    }
}
