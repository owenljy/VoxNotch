//
//  TextOutputManager.swift
//  VoxNotch
//
//  Text output via CGEvent keystrokes or clipboard paste
//

import Foundation
import AppKit
import Carbon.HIToolbox

/// Manages outputting transcribed text to the active application
final class TextOutputManager {

    // MARK: - Types

    enum TextOutputError: LocalizedError, Equatable {
        case accessibilityNotGranted
        case noActiveApplication
        case keystrokeFailed
        case clipboardFailed
        case targetAppChanged

        var errorDescription: String? {
            switch self {
            case .accessibilityNotGranted:
                return "Accessibility access needed"
            case .noActiveApplication:
                return "No app to receive text"
            case .keystrokeFailed:
                return "Could not type text"
            case .clipboardFailed:
                return "Could not paste text"
            case .targetAppChanged:
                return "Target app changed during output"
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .accessibilityNotGranted:
                return "Grant access in System Settings → Privacy"
            case .noActiveApplication:
                return "Click into an app first, then try again"
            case .keystrokeFailed, .clipboardFailed, .targetAppChanged:
                return "Text was copied to clipboard instead"
            }
        }
    }

    // MARK: - Properties

    static let shared = TextOutputManager()

    private var recordedTargetPID: pid_t?
    private var recordedFocus: AXUIElement?
    private var recordedWindow: AXUIElement?

    func captureTarget() {
        recordedTargetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        recordedFocus = recordedTargetPID.flatMap { focusedAttribute(kAXFocusedUIElementAttribute, pid: $0) }
        recordedWindow = recordedTargetPID.flatMap { focusedAttribute(kAXFocusedWindowAttribute, pid: $0) }
    }

    func isTargetCurrent(_ app: NSRunningApplication?) -> Bool {
        guard let app, let pid = recordedTargetPID,
              app.processIdentifier == pid,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        if let recordedWindow {
            guard let current = focusedAttribute(kAXFocusedWindowAttribute, pid: pid),
                  CFEqual(recordedWindow, current) else { return false }
        }
        if let recordedFocus {
            guard let current = focusedAttribute(kAXFocusedUIElementAttribute, pid: pid),
                  CFEqual(recordedFocus, current) else { return false }
        }
        return true
    }

    private func focusedAttribute(_ attribute: String, pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private let keystrokeDelay: TimeInterval = 0.01
    private let keystrokeLengthThreshold: Int = 50

    /// Whether to restore clipboard after paste (read from settings)
    var restoreClipboard: Bool {
        SettingsManager.shared.restoreClipboard
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Output text using clipboard paste or keystroke simulation depending on settings
    /// - Parameter text: The text to output
    func output(_ text: String) async throws {
        try Task.checkCancellation()
        guard isTargetCurrent(NSWorkspace.shared.frontmostApplication) else { throw TextOutputError.targetAppChanged }
        // Only retry failures that occurred before any text could be inserted.
        if SettingsManager.shared.useClipboardForOutput || text.count > keystrokeLengthThreshold {
            try await outputViaClipboard(text)
        } else {
            try await outputViaKeystrokes(text)
        }
    }

    /// Output text via simulated keystrokes
    /// - Parameter text: The text to type
    func outputViaKeystrokes(_ text: String) async throws {
        guard AXIsProcessTrusted() else {
            throw TextOutputError.accessibilityNotGranted
        }

        // Long text is faster and safer via clipboard paste.
        if text.count > keystrokeLengthThreshold {
            try await outputViaClipboard(text)
            return
        }

        // Capture the frontmost PID so we can detect app switches mid-stream.
        let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        for char in text {
            try Task.checkCancellation()
            guard isTargetCurrent(NSWorkspace.shared.frontmostApplication) else { throw TextOutputError.targetAppChanged }
            // Verify the target before every character.
            if let pid = targetPID,
               let current = NSWorkspace.shared.frontmostApplication,
               current.processIdentifier != pid {
                throw TextOutputError.targetAppChanged
            }
            try await typeCharacter(char)
            try await Task.sleep(nanoseconds: UInt64(keystrokeDelay * 1_000_000_000))
        }
    }

    /// Output text via clipboard paste
    /// - Parameter text: The text to paste
    func outputViaClipboard(_ text: String) async throws {
        guard AXIsProcessTrusted() else {
            throw TextOutputError.accessibilityNotGranted
        }

        let pasteboard = NSPasteboard.general

        try Task.checkCancellation()
        let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let previous = restoreClipboard ? ClipboardSnapshot(pasteboard: pasteboard) : nil
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw TextOutputError.clipboardFailed
        }
        let writtenChangeCount = pasteboard.changeCount
        defer { previous?.restore(to: pasteboard, ifUnchangedSince: writtenChangeCount) }
        try Task.checkCancellation()
        guard targetPID == NSWorkspace.shared.frontmostApplication?.processIdentifier,
              isTargetCurrent(NSWorkspace.shared.frontmostApplication) else {
            throw TextOutputError.targetAppChanged
        }
        try await simulatePaste()
        // Allow the receiving app to read the pasteboard before restoring it.
        // Finish this cleanup even if the pipeline was cancelled after Cmd+V.
        try? await Task<Void, Error>.detached {
            try await Task.sleep(nanoseconds: 300_000_000)
        }.value
        try Task.checkCancellation()
    }

    // MARK: - Private Methods

    private func typeCharacter(_ char: Character) async throws {
        guard let eventSource = CGEventSource(stateID: .hidSystemState) else {
            throw TextOutputError.keystrokeFailed
        }

        // Get the string representation
        let string = String(char)

        // Create key events using Unicode approach for reliability
        guard let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) else {
            throw TextOutputError.keystrokeFailed
        }

        // Use the Unicode text approach for reliable character input
        var unicodeString = Array(string.utf16)
        keyDown.keyboardSetUnicodeString(stringLength: unicodeString.count, unicodeString: &unicodeString)
        keyUp.keyboardSetUnicodeString(stringLength: unicodeString.count, unicodeString: &unicodeString)

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func simulatePaste() async throws {
        guard let eventSource = CGEventSource(stateID: .hidSystemState) else {
            throw TextOutputError.keystrokeFailed
        }

        // Key code for 'V' is 9
        let vKeyCode: CGKeyCode = 9

        // Key down with Cmd modifier
        guard let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: vKeyCode, keyDown: false) else {
            throw TextOutputError.clipboardFailed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Returns true if the frontmost application has a focused text input element.
    func hasFocusedTextInput() -> Bool {
        return hasFocusedTextInput(for: NSWorkspace.shared.frontmostApplication)
    }

    /// Returns true if the frontmost application has a focused text input element.
    /// Uses the Accessibility API to query the focused UI element's role.
    /// When `app` is nil, falls back to the current frontmost application.
    func hasFocusedTextInput(for app: NSRunningApplication?) -> Bool {
        guard let targetApp = app ?? NSWorkspace.shared.frontmostApplication else {
            return false
        }

        let axApp = AXUIElementCreateApplication(targetApp.processIdentifier)

        // For Electron / browser apps the AX tree can be slow or incomplete.
        // The whitelist provides a generous fallback: if the AX query succeeds
        // we trust it; if it fails we default to true (preserving old behavior).
        if let bundleID = targetApp.bundleIdentifier {
            let whitelistedPrefixes = [
                "com.google.Chrome",
                "company.thebrowser.Browser", // Arc
                "com.microsoft.VSCode",
                "com.tinyspeck.slackmacgap",  // Slack
                "com.hnc.Discord",
                "com.apple.Terminal",
                "com.googlecode.iterm2",
                "com.brave.Browser",
                "com.microsoft.edgemac",       // Edge
                "org.mozilla.firefox",
                "com.microsoft.teams",         // Teams (old & new/teams2)
                "com.anthropic.claudefordesktop", // Claude Desktop
                "md.obsidian",                 // Obsidian
                "us.zoom.xos",                 // Zoom
                "notion.id",                   // Notion
                "com.figma.desktop",           // Figma
                "com.todesktop.230313mzl4w4u92" // Linear
            ]

            if whitelistedPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
                return isFocusedElementEditable(axApp: axApp) ?? true
            }
        }

        // Non-whitelisted apps: conservative — AX failure means false.
        return isFocusedElementEditable(axApp: axApp) ?? false
    }

    /// Check whether the focused element of an AX application is an editable text field.
    /// Returns `nil` when the AX query itself fails (no permission, timeout, etc.).
    private func isFocusedElementEditable(axApp: AXUIElement) -> Bool? {
        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            axApp, kAXFocusedUIElementAttribute as CFString, &focusedElement
        )
        guard result == .success, let element = focusedElement else { return nil }

        let axElement = element as! AXUIElement
        var roleValue: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(
            axElement, kAXRoleAttribute as CFString, &roleValue
        )
        guard roleResult == .success, let role = roleValue as? String else { return nil }

        // Standard native text input roles — always editable.
        let definitelyEditableRoles: Set<String> = [
            "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"
        ]
        if definitelyEditableRoles.contains(role) { return true }

        // Web / document roles need an extra check: AXSelectedTextRange is
        // present on focused inputs and contenteditable areas but absent on
        // inert page bodies (e.g. YouTube video view).
        if role == "AXWebArea" || role == "AXDocument" {
            var selectedTextRange: CFTypeRef?
            let rangeResult = AXUIElementCopyAttributeValue(
                axElement, "AXSelectedTextRange" as CFString, &selectedTextRange
            )
            return rangeResult == .success && selectedTextRange != nil
        }

        return false
    }

    /// Copy text to clipboard without simulating a paste keystroke.
    /// Used as a fallback when no focused text input is detected.
    func copyToClipboardOnly(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

}


/// Preserve every pasteboard item/type, including images and rich text.
struct ClipboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { values[type] = item.data(forType: type) }
            return values
        }
    }

    func restore(to pasteboard: NSPasteboard, ifUnchangedSince changeCount: Int) {
        guard pasteboard.changeCount == changeCount else { return }
        pasteboard.clearContents()
        let restored = items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
