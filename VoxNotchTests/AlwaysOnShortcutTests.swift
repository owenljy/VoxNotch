import CoreGraphics
import XCTest
@testable import VoxNotch

@MainActor
final class AlwaysOnShortcutTests: XCTestCase {
  func testConsumedShortcutSwallowsRepeatsAndKeyUpWithoutRetriggering() throws {
    let manager = HotkeyManager.shared
    let saved = manager.shortcuts
    defer { manager.shortcuts = saved }
    var calls = 0
    manager.shortcuts = [.init(shortcut: .defaultAsk) { calls += 1; return true }]
    let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: KeyShortcut.defaultAsk.keyCode, keyDown: true))
    event.flags = CGEventFlags(rawValue: KeyShortcut.defaultAsk.modifiers)
    XCTAssertTrue(manager.handleShortcutEvent(type: .keyDown, event: event))
    event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    XCTAssertTrue(manager.handleShortcutEvent(type: .keyDown, event: event))
    event.flags = []
    XCTAssertTrue(manager.handleShortcutEvent(type: .keyUp, event: event), "release remains consumed after modifiers are lifted")
    XCTAssertEqual(calls, 1)
    XCTAssertFalse(manager.handleShortcutEvent(type: .keyUp, event: event))
  }

  func testInactiveShortcutLeavesWholeKeyPressToFrontApp() throws {
    let manager = HotkeyManager.shared
    let saved = manager.shortcuts
    defer { manager.shortcuts = saved }
    var calls = 0
    manager.shortcuts = [.init(shortcut: .defaultAsk) { calls += 1; return false }]
    let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: KeyShortcut.defaultAsk.keyCode, keyDown: true))
    event.flags = CGEventFlags(rawValue: KeyShortcut.defaultAsk.modifiers)
    XCTAssertFalse(manager.handleShortcutEvent(type: .keyDown, event: event))
    event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    XCTAssertFalse(manager.handleShortcutEvent(type: .keyDown, event: event))
    XCTAssertFalse(manager.handleShortcutEvent(type: .keyUp, event: event))
    XCTAssertEqual(calls, 1)
  }
}
