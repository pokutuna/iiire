import Carbon.HIToolbox
import XCTest
@testable import Koe

/// 入力先のアプリのルールで、既定の出力の設定を項目ごとに上書きする
final class AppRuleTests: XCTestCase {
    private let base = OutputConfig(output: .paste, keystroke: .rightCommand)

    func testRuleOverridesOnlySetFields() {
        let rules = [
            AppRule(bundleID: "com.mitchellh.ghostty", name: "Ghostty", output: nil, keystroke: .leftCommand),
            AppRule(bundleID: "com.microsoft.VSCode", name: "Code", output: .pasteAndKeep, keystroke: .appleScript),
        ]
        XCTAssertEqual(OutputConfig.resolve(bundleID: "com.mitchellh.ghostty", rules: rules, default: base),
                       OutputConfig(output: .paste, keystroke: .leftCommand))
        XCTAssertEqual(OutputConfig.resolve(bundleID: "com.microsoft.VSCode", rules: rules, default: base),
                       OutputConfig(output: .pasteAndKeep, keystroke: .appleScript))
        XCTAssertEqual(OutputConfig.resolve(bundleID: "com.apple.TextEdit", rules: rules, default: base), base)
        XCTAssertEqual(OutputConfig.resolve(bundleID: nil, rules: rules, default: base), base)
    }

    func testBrokenRulesAreIgnored() {
        XCTAssertEqual(AppRule.decode("not json"), [])
    }

    /// 「出力」タブではルール専用の送り方 (キーを指定) を既定にしない
    func testBaseConfigFromSavedValues() {
        XCTAssertEqual(OutputConfig.base(output: "clipboard", keystroke: "leftCommand"),
                       OutputConfig(output: .clipboard, keystroke: .leftCommand))
        XCTAssertEqual(OutputConfig.base(output: "?", keystroke: "custom"), base)
    }

    private func combo(_ keyCode: Int, _ mods: NSEvent.ModifierFlags, _ label: String) -> Shortcut {
        Shortcut(kind: .combo, keyCode: UInt16(keyCode), modifiers: mods.rawValue, keyLabel: label)
    }

    func testSendableKeys() {
        XCTAssertNil(combo(kVK_ANSI_Y, .control, "Y").sendProblem)
        XCTAssertNil(combo(kVK_ANSI_V, [.command, .shift], "V").sendProblem)
        XCTAssertNil(combo(kVK_F5, [], "F5").sendProblem)
    }

    func testKeysThatRunOrCloseAreRejected() {
        XCTAssertNotNil(Shortcut.default.sendProblem) // 修飾キー単独
        XCTAssertNotNil(combo(kVK_Return, .command, "↩").sendProblem)
        XCTAssertNotNil(combo(kVK_Tab, .control, "⇥").sendProblem)
        XCTAssertNotNil(combo(kVK_ANSI_Q, .command, "Q").sendProblem)
        XCTAssertNotNil(combo(kVK_ANSI_W, [.command, .option], "W").sendProblem)
        XCTAssertNotNil(combo(kVK_ANSI_Y, [], "Y").sendProblem)
    }

    func testCustomKeyFallsBackWithoutAValidKey() {
        let ctrlY = combo(kVK_ANSI_Y, .control, "Y")
        func rule(_ key: Shortcut?) -> [AppRule] {
            [AppRule(bundleID: "a", name: "A", output: nil, keystroke: .custom, customKey: key)]
        }
        XCTAssertEqual(OutputConfig.resolve(bundleID: "a", rules: rule(ctrlY), default: base),
                       OutputConfig(output: .paste, keystroke: .custom, customKey: ctrlY))
        XCTAssertEqual(OutputConfig.resolve(bundleID: "a", rules: rule(nil), default: base), base)
        XCTAssertEqual(OutputConfig.resolve(bundleID: "a", rules: rule(combo(kVK_ANSI_Q, .command, "Q")), default: base), base)
    }
}
