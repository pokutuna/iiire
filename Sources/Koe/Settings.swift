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
        .init(id: "haas-ja-v1.0", label: "Haas ja v1.0 (ja, 速い, 0.66 GB)", takesPrompt: false, takesKeywords: true),
        .init(id: "reazonspeech-v2", label: "ReazonSpeech v2 (ja, 0.66 GB)", takesPrompt: false, takesKeywords: false),
        .init(id: "parakeet-tdt_ctc-0.6b-ja", label: "Parakeet TDT-CTC ja (ja, 短い発話, 0.66 GB)", takesPrompt: false, takesKeywords: false),
        .init(id: "qwen3-asr-0.6b", label: "Qwen3-ASR 0.6B (多言語, 0.84 GB)", takesPrompt: true, takesKeywords: false),
        .init(id: "qwen3-asr-1.7b", label: "Qwen3-ASR 1.7B (多言語, 2.18 GB)", takesPrompt: true, takesKeywords: false),
    ]

    static func find(_ id: String) -> RecognitionModel {
        all.first { $0.id == id } ?? .init(id: id, label: id, takesPrompt: false, takesKeywords: false)
    }
}

/// 書き起こした文字列の渡し方
enum OutputMethod: String, CaseIterable, Identifiable {
    case paste          // カーソル位置にペーストし、クリップボードを元に戻す
    case pasteAndKeep   // カーソル位置にペーストし、クリップボードにも残す
    case clipboard      // クリップボードにコピーするだけ

    var id: String { rawValue }
    var label: String {
        switch self {
        case .paste: "カーソル位置に入力"
        case .pasteAndKeep: "カーソル位置に入力 + クリップボードに残す"
        case .clipboard: "クリップボードにコピーのみ"
        }
    }
}

enum SettingsKey {
    static let model = "model"
    static let language = "language"
    static let hint = "hint"
    static let shortcut = "shortcut"
    static let legacyHotkey = "hotkey"
    static let inputDeviceUID = "inputDeviceUID"
    static let outputMethod = "outputMethod"
    static let speechPath = "speechPath"
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
            SettingsKey.speechPath: "",
        ])
    }

    static var model: RecognitionModel { .find(UserDefaults.standard.string(forKey: SettingsKey.model)!) }
    static var language: String { UserDefaults.standard.string(forKey: SettingsKey.language)! }
    static var hint: String { UserDefaults.standard.string(forKey: SettingsKey.hint)! }
    static var shortcut: Shortcut {
        let d = UserDefaults.standard
        if let s = Shortcut.decode(d.string(forKey: SettingsKey.shortcut) ?? "") { return s }
        // 以前のプリセット名で保存された設定
        if let legacy = d.string(forKey: SettingsKey.legacyHotkey), let s = legacyShortcut(legacy) { return s }
        return .default
    }

    private static func legacyShortcut(_ name: String) -> Shortcut? {
        switch name {
        case "rightOption": Shortcut(kind: .modifierOnly, keyCode: UInt16(kVK_RightOption), modifiers: 0, keyLabel: "")
        case "rightCommand": Shortcut(kind: .modifierOnly, keyCode: UInt16(kVK_RightCommand), modifiers: 0, keyLabel: "")
        case "rightControl": Shortcut(kind: .modifierOnly, keyCode: UInt16(kVK_RightControl), modifiers: 0, keyLabel: "")
        case "fn": Shortcut(kind: .modifierOnly, keyCode: UInt16(kVK_Function), modifiers: 0, keyLabel: "")
        case "optionSpace": Shortcut(kind: .combo, keyCode: UInt16(kVK_Space), modifiers: NSEvent.ModifierFlags.option.rawValue, keyLabel: "Space")
        case "controlOptionSpace": Shortcut(kind: .combo, keyCode: UInt16(kVK_Space), modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, keyLabel: "Space")
        case "f5": Shortcut(kind: .combo, keyCode: UInt16(kVK_F5), modifiers: 0, keyLabel: "F5")
        default: nil
        }
    }
    static var inputDeviceUID: String { UserDefaults.standard.string(forKey: SettingsKey.inputDeviceUID)! }
    static var outputMethod: OutputMethod {
        OutputMethod(rawValue: UserDefaults.standard.string(forKey: SettingsKey.outputMethod)!) ?? .paste
    }
    static var speechPath: String { UserDefaults.standard.string(forKey: SettingsKey.speechPath)! }
}
