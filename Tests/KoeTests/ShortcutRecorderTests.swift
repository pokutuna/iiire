import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Koe

/// キーを押す順序に対して、記録されるショートカットを確かめる
@MainActor
final class ShortcutRecorderTests: XCTestCase {
    private var model: ShortcutRecorderModel!
    private var finished: [Shortcut?] = []

    override func setUp() async throws {
        model = ShortcutRecorderModel()
        finished = []
        model.onFinish = { [unowned self] in finished.append($0) }
        model.start()
    }

    override func tearDown() async throws {
        model.cancel()
    }

    private func flags(_ keyCode: Int, _ flags: NSEvent.ModifierFlags) {
        let e = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
                                 windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                 isARepeat: false, keyCode: UInt16(keyCode))!
        model.flagsChanged(e)
    }

    private func key(_ keyCode: Int, _ chars: String, _ flags: NSEvent.ModifierFlags = []) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                 windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                 isARepeat: false, keyCode: UInt16(keyCode))!
        model.keyDown(e)
    }

    func testModifierAloneRecordsThatSide() {
        flags(kVK_RightCommand, .command)
        XCTAssertEqual(model.preview, "Right ⌘ …")
        flags(kVK_RightCommand, [])
        XCTAssertEqual(finished, [Shortcut(kind: .modifierOnly, keyCode: UInt16(kVK_RightCommand), modifiers: 0, keyLabel: "")])
        XCTAssertFalse(model.isRecording)
    }

    func testComboRecordsModifiersAndKey() {
        flags(kVK_Control, .control)
        flags(kVK_Option, [.control, .option])
        XCTAssertEqual(model.preview, "⌃⌥ …")
        key(kVK_Space, " ", [.control, .option])
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(finished[0]?.kind, .combo)
        XCTAssertEqual(finished[0]?.displayName, "⌃⌥Space")
    }

    func testPlainLetterIsRejectedAndKeepsRecording() {
        key(kVK_ANSI_A, "a")
        XCTAssertTrue(model.isRecording)
        XCTAssertNotNil(model.message)
        XCTAssertEqual(model.preview, "A")
        XCTAssertTrue(finished.isEmpty)
    }

    func testFunctionKeyAloneIsAccepted() {
        key(kVK_F6, "\u{F709}", .function)
        XCTAssertEqual(finished.first??.displayName, "F6")
    }

    func testTwoModifiersAloneAreRejected() {
        flags(kVK_Command, .command)
        flags(kVK_Shift, [.command, .shift])
        flags(kVK_Shift, .command)
        flags(kVK_Command, [])
        XCTAssertTrue(model.isRecording)
        XCTAssertNotNil(model.message)
        // 続けて単独で押せば登録できる
        flags(kVK_RightOption, .option)
        flags(kVK_RightOption, [])
        XCTAssertEqual(finished.first??.displayName, "Right ⌥")
    }

    func testEscapeCancels() {
        key(kVK_Escape, "\u{1B}")
        XCTAssertEqual(finished.count, 1)
        XCTAssertNil(finished[0])
    }

    func testSavedShortcutRoundTrips() {
        let s = Shortcut(kind: .combo, keyCode: UInt16(kVK_ANSI_D), modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, keyLabel: "D")
        XCTAssertEqual(Shortcut.decode(s.encoded()), s)
        XCTAssertEqual(s.displayName, "⇧⌘D")
    }
}
