//
//  MockTextOutputting.swift
//  VoxNotchTests
//

import AppKit
@testable import VoxNotch

final class MockTextOutputting: TextOutputting {
    var targetIsCurrent = true
    func isTargetCurrent(_ app: NSRunningApplication?) -> Bool { targetIsCurrent }
    var hasFocusedTextInputValue: Bool = true
    var outputCallCount = 0
    var copyCallCount = 0
    var lastOutputText: String?
    var lastCopiedText: String?
    var stubbedOutputError: Error?

    func hasFocusedTextInput(for app: NSRunningApplication?) -> Bool {
        return hasFocusedTextInputValue
    }

    func output(_ text: String) async throws {
        outputCallCount += 1
        lastOutputText = text
        if let error = stubbedOutputError { throw error }
    }

    func copyToClipboardOnly(_ text: String) {
        copyCallCount += 1
        lastCopiedText = text
    }
}
