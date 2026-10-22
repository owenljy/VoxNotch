//
//  KeyShortcutTests.swift
//  VoxNotchTests
//

import Carbon.HIToolbox
import XCTest
@testable import VoxNotch

final class KeyShortcutTests: XCTestCase {

  func testDefaultsDisplay() {
    XCTAssertEqual(KeyShortcut.defaultAsk.displayString, "⌃⌘↩")
    XCTAssertEqual(KeyShortcut.defaultToggleAlwaysOn.displayString, "⌃⌘A")
    XCTAssertEqual(KeyShortcut.defaultPreviousAnswer.displayString, "⌃⌘←")
    XCTAssertEqual(KeyShortcut.defaultNextAnswer.displayString, "⌃⌘→")
  }

  func testMatchingIgnoresUnrelatedFlags() {
    let shortcut = KeyShortcut.defaultAsk
    XCTAssertTrue(shortcut.matches(keyCode: Int64(kVK_Return), flags: [.maskControl, .maskCommand, .maskNumericPad]))
    XCTAssertFalse(shortcut.matches(keyCode: Int64(kVK_Return), flags: [.maskControl, .maskCommand, .maskShift]))
    XCTAssertFalse(shortcut.matches(keyCode: Int64(kVK_Return), flags: [.maskCommand]))
    XCTAssertFalse(shortcut.matches(keyCode: Int64(kVK_ANSI_A), flags: [.maskControl, .maskCommand]))
  }

  func testRecordingFromEventRequiresModifier() throws {
    func key(_ code: Int, _ chars: String, _ flags: NSEvent.ModifierFlags) -> NSEvent? {
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
        characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))
    }
    let recorded = try XCTUnwrap(KeyShortcut(event: try XCTUnwrap(key(kVK_ANSI_K, "k", [.option, .command]))))
    XCTAssertEqual(recorded.displayString, "⌥⌘K")
    XCTAssertNil(KeyShortcut(event: try XCTUnwrap(key(kVK_ANSI_K, "k", [.shift]))))
    XCTAssertEqual(KeyShortcut(event: try XCTUnwrap(key(kVK_Return, "\r", [.control])))?.displayString, "⌃↩")
  }

  func testCodableRoundTrip() throws {
    let data = try JSONEncoder().encode(KeyShortcut.defaultAsk)
    XCTAssertEqual(try JSONDecoder().decode(KeyShortcut.self, from: data), .defaultAsk)
  }
}
