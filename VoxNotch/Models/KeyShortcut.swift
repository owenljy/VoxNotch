//
//  KeyShortcut.swift
//  VoxNotch
//
//  A global key + modifier shortcut (e.g. ⌃⌘↩) handled by HotkeyManager.
//

import AppKit
import Carbon.HIToolbox
import CoreGraphics

nonisolated struct KeyShortcut: Codable, Hashable, Sendable {

  let keyCode: UInt16
  /// CGEventFlags raw value restricted to ⌃⌥⇧⌘.
  let modifiers: UInt64
  let keyLabel: String

  static let relevantModifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]

  static let defaultToggleAlwaysOn = KeyShortcut(
    keyCode: UInt16(kVK_ANSI_A),
    modifiers: CGEventFlags([.maskControl, .maskCommand]).rawValue,
    keyLabel: "A"
  )

  static let defaultAsk = KeyShortcut(
    keyCode: UInt16(kVK_Return),
    modifiers: CGEventFlags([.maskControl, .maskCommand]).rawValue,
    keyLabel: "↩"
  )

  var displayString: String {
    let flags = CGEventFlags(rawValue: modifiers)
    var symbols = ""
    if flags.contains(.maskControl) { symbols += "⌃" }
    if flags.contains(.maskAlternate) { symbols += "⌥" }
    if flags.contains(.maskShift) { symbols += "⇧" }
    if flags.contains(.maskCommand) { symbols += "⌘" }
    return symbols + keyLabel
  }

  func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
    Int64(self.keyCode) == keyCode && flags.intersection(Self.relevantModifiers).rawValue == modifiers
  }

  /// Builds a shortcut from a recorded key event; requires ⌃, ⌥ or ⌘ so plain typing never triggers it.
  init?(event: NSEvent) {
    var flags: CGEventFlags = []
    if event.modifierFlags.contains(.control) { flags.insert(.maskControl) }
    if event.modifierFlags.contains(.option) { flags.insert(.maskAlternate) }
    if event.modifierFlags.contains(.shift) { flags.insert(.maskShift) }
    if event.modifierFlags.contains(.command) { flags.insert(.maskCommand) }
    guard !flags.intersection([.maskControl, .maskAlternate, .maskCommand]).isEmpty else { return nil }

    let label = Self.specialKeyLabels[Int(event.keyCode)]
      ?? event.charactersIgnoringModifiers?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard let label, !label.isEmpty else { return nil }
    self.init(keyCode: event.keyCode, modifiers: flags.rawValue, keyLabel: label)
  }

  init(keyCode: UInt16, modifiers: UInt64, keyLabel: String) {
    self.keyCode = keyCode
    self.modifiers = modifiers
    self.keyLabel = keyLabel
  }

  private static let specialKeyLabels: [Int: String] = [
    kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "Space",
    kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
    kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
  ]
}
