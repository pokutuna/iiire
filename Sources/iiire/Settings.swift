import AppKit
import Carbon.HIToolbox

/// 認識モデル。speech.cpp のカタログ名をそのまま使う。
struct RecognitionModel: Identifiable, Hashable {
    let id: String
    let label: String
    /// `prompt` オプションを受け付けるか (Qwen3-ASR)
    let takesPrompt: Bool
    /// `keywords` オプションを受け付けるか (Haas)
    let takesKeywords: Bool

    static let all: [RecognitionModel] = [
        .init(id: "haas-ja-v1.0", label: String(localized: "Haas ja v1.0 (ja, fast, 0.66 GB)"), takesPrompt: false, takesKeywords: true),
        .init(id: "reazonspeech-v2", label: "ReazonSpeech v2 (ja, 0.66 GB)", takesPrompt: false, takesKeywords: false),
        .init(id: "parakeet-tdt_ctc-0.6b-ja", label: String(localized: "Parakeet TDT-CTC ja (ja, short utterances, 0.66 GB)"), takesPrompt: false, takesKeywords: false),
        .init(id: "qwen3-asr-0.6b", label: String(localized: "Qwen3-ASR 0.6B (multilingual, 0.84 GB)"), takesPrompt: true, takesKeywords: false),
        .init(id: "qwen3-asr-1.7b", label: String(localized: "Qwen3-ASR 1.7B (multilingual, 2.18 GB)"), takesPrompt: true, takesKeywords: false),
    ]

    static func find(_ id: String) -> RecognitionModel {
        all.first { $0.id == id } ?? .init(id: id, label: id, takesPrompt: false, takesKeywords: false)
    }
}

/// 書き起こした文字列の渡し方
enum OutputMethod: String, CaseIterable, Identifiable, Codable {
    case paste          // カーソル位置にペーストし、クリップボードを元に戻す
    case pasteAndKeep   // カーソル位置にペーストし、クリップボードにも残す
    case clipboard      // クリップボードにコピーするだけ

    var id: String { rawValue }
    var label: String {
        switch self {
        case .paste: String(localized: "Type at cursor")
        case .pasteAndKeep: String(localized: "Type at cursor and keep in clipboard")
        case .clipboard: String(localized: "Copy to clipboard only")
        }
    }
}

/// ペーストの ⌘V の送り方。キーバインドを変えているアプリでは、効く送り方が違う
enum PasteKeystroke: String, CaseIterable, Identifiable, Codable {
    case rightCommand   // CGEvent で 右 ⌘ + V
    case leftCommand    // CGEvent で 左 ⌘ + V
    case appleScript    // System Events に keystroke "v" using command down を頼む
    case custom         // 記録したキー (例: ⌃Y、キー配列で ⌘V が別の位置なら ⌘ とそのキー)

    var id: String { rawValue }
    var label: String {
        switch self {
        case .rightCommand: String(localized: "⌘V with right ⌘")
        case .leftCommand: String(localized: "⌘V with left ⌘")
        case .appleScript: String(localized: "⌘V via AppleScript (System Events)")
        case .custom: String(localized: "Custom key")
        }
    }
}

extension Shortcut {
    /// ペーストの代わりに送るキーとして使えない理由。使えるなら nil。
    /// 書き起こすたびに送るので、実行や終了につながるキーは送らない
    var sendProblem: String? {
        guard kind == .combo else { return String(localized: "A modifier key alone cannot be sent.") }
        let runsOrCloses: Set<Int> = [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape, kVK_Delete, kVK_ForwardDelete]
        if runsOrCloses.contains(Int(keyCode)) {
            return String(localized: "Return, Tab, Esc and Delete cannot be sent.")
        }
        // キー配列によって位置が違うので、記録したときの文字で見る
        if modifierFlags.contains(.command), ["Q", "W", "H", "M"].contains(keyLabel.uppercased()) {
            return String(localized: "⌘Q, ⌘W, ⌘H and ⌘M close or hide the app, so they cannot be sent.")
        }
        if lacksModifier {
            return String(localized: "Combine with ⌃, ⌥, ⇧ or ⌘ (F keys work on their own).")
        }
        return nil
    }
}

/// 入力先のアプリごとに、既定の出力の設定を上書きする。nil の項目は既定に従う
struct AppRule: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    var output: OutputMethod?
    var keystroke: PasteKeystroke?
    /// keystroke が custom のときに送るキー
    var customKey: Shortcut?

    var id: String { bundleID }

    static func decode(_ json: String) -> [AppRule] {
        (try? JSONDecoder().decode([AppRule].self, from: Data(json.utf8))) ?? []
    }

    static func encode(_ rules: [AppRule]) -> String {
        (try? JSONEncoder().encode(rules)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}

/// 入力先のアプリに使う出力の設定
struct OutputConfig: Equatable {
    var output: OutputMethod
    var keystroke: PasteKeystroke
    /// keystroke が custom のときに送るキー。送ってよいキーに限る
    var customKey: Shortcut? = nil

    /// 「出力」タブで保存した値から作る。
    /// custom なのにキーがない (まだ記録していない) か送れないキーなら、右 ⌘ で ⌘V を送る
    static func base(output: String, keystroke: String, customKey: String) -> OutputConfig {
        var config = OutputConfig(output: OutputMethod(rawValue: output) ?? .paste,
                                  keystroke: PasteKeystroke(rawValue: keystroke) ?? .rightCommand)
        if config.keystroke == .custom {
            if let key = Shortcut.decode(customKey), key.sendProblem == nil {
                config.customKey = key
            } else {
                config.keystroke = .rightCommand
            }
        }
        return config
    }

    /// bundleID のルールがあれば、その項目で既定を上書きする。
    /// custom なのにキーがない (まだ記録していない) か送れないキーなら、既定の送り方にする
    static func resolve(bundleID: String?, rules: [AppRule], default base: OutputConfig) -> OutputConfig {
        guard let bundleID, let rule = rules.first(where: { $0.bundleID == bundleID }) else { return base }
        var config = base
        config.output = rule.output ?? base.output
        switch rule.keystroke {
        case nil:
            break
        case .custom:
            if let key = rule.customKey, key.sendProblem == nil {
                config.keystroke = .custom
                config.customKey = key
            }
        case let k?:
            config.keystroke = k
            config.customKey = nil
        }
        return config
    }

    /// 送り方の表示。記録したキーならそのキーも出す
    var keystrokeLabel: String {
        guard keystroke == .custom, let customKey else { return keystroke.label }
        return "\(keystroke.label) \(customKey.displayName)"
    }
}

enum SettingsKey {
    static let model = "model"
    static let language = "language"
    static let hint = "hint"
    static let shortcut = "shortcut"
    static let inputDeviceUID = "inputDeviceUID"
    static let outputMethod = "outputMethod"
    static let soundCue = "soundCue"
    static let startSound = "startSound"
    static let doneSound = "doneSound"
    static let cancelSound = "cancelSound"
    static let speechPath = "speechPath"
    static let pasteKeyIntervalMs = "pasteKeyIntervalMs"
    static let clipboardRestoreDelayMs = "clipboardRestoreDelayMs"
    static let pasteKeystroke = "pasteKeystroke"
    static let pasteCustomKey = "pasteCustomKey"
    static let appRules = "appRules"
}

enum Defaults {
    static func register() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.model: "haas-ja-v1.0",
            SettingsKey.language: "auto",
            SettingsKey.hint: "",
            SettingsKey.shortcut: "",
            SettingsKey.inputDeviceUID: "",
            SettingsKey.outputMethod: OutputMethod.paste.rawValue,
            SettingsKey.soundCue: true,
            SettingsKey.startSound: "Funk",
            SettingsKey.doneSound: "Glass",
            SettingsKey.cancelSound: "Bottle",
            SettingsKey.speechPath: "",
            SettingsKey.pasteKeyIntervalMs: 10,
            SettingsKey.clipboardRestoreDelayMs: 1000,
            SettingsKey.pasteKeystroke: PasteKeystroke.rightCommand.rawValue,
            SettingsKey.pasteCustomKey: "",
            SettingsKey.appRules: "[]",
        ])
    }

    /// 文字列の設定。`defaults write` で別の型の値が入っていても落ちないように
    private static func string(_ key: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? ""
    }

    static var model: RecognitionModel { .find(string(SettingsKey.model)) }
    static var language: String { string(SettingsKey.language) }
    static var hint: String { string(SettingsKey.hint) }
    static var shortcut: Shortcut { Shortcut.decode(string(SettingsKey.shortcut)) ?? .default }
    static var inputDeviceUID: String { string(SettingsKey.inputDeviceUID) }
    static var soundCue: Bool { UserDefaults.standard.bool(forKey: SettingsKey.soundCue) }
    static var startSound: String { string(SettingsKey.startSound) }
    static var doneSound: String { string(SettingsKey.doneSound) }
    static var cancelSound: String { string(SettingsKey.cancelSound) }
    /// 「出力」タブの設定
    static var baseOutputConfig: OutputConfig {
        .base(output: string(SettingsKey.outputMethod), keystroke: string(SettingsKey.pasteKeystroke),
              customKey: string(SettingsKey.pasteCustomKey))
    }
    static var outputMethod: OutputMethod { baseOutputConfig.output }
    static var appRules: [AppRule] { AppRule.decode(string(SettingsKey.appRules)) }
    /// 入力先のアプリ (bundleID) に使う出力の設定
    static func outputConfig(for bundleID: String?) -> OutputConfig {
        .resolve(bundleID: bundleID, rules: appRules, default: baseOutputConfig)
    }
    static var speechPath: String { string(SettingsKey.speechPath) }

    static let pasteKeyIntervalRange = 0...100
    static let clipboardRestoreDelayRange = 100...3000
    /// ⌘V のキー入力 (⌘ 押す, V 押す, V 離す, ⌘ 離す) の間隔
    static var pasteKeyIntervalMs: Int {
        UserDefaults.standard.integer(forKey: SettingsKey.pasteKeyIntervalMs).clamped(to: pasteKeyIntervalRange)
    }
    /// ⌘V を送ってから元のクリップボードに戻すまでの時間
    static var clipboardRestoreDelayMs: Int {
        UserDefaults.standard.integer(forKey: SettingsKey.clipboardRestoreDelayMs).clamped(to: clipboardRestoreDelayRange)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
