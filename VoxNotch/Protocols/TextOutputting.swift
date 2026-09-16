//
//  TextOutputting.swift
//  VoxNotch
//
//  Protocol abstracting TextOutputManager for testability.
//

import AppKit

/// Abstraction over text output so QuickDictationController can be tested with mocks.
protocol TextOutputting: AnyObject {
    func hasFocusedTextInput(for app: NSRunningApplication?) -> Bool
    func captureTarget()
    func isTargetCurrent(_ app: NSRunningApplication?) -> Bool
    func output(_ text: String) async throws
    func copyToClipboardOnly(_ text: String)
}

extension TextOutputManager: TextOutputting {}


extension TextOutputting {
    func captureTarget() {}
    func isTargetCurrent(_ app: NSRunningApplication?) -> Bool {
        guard let app else { return false }
        return app.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}
