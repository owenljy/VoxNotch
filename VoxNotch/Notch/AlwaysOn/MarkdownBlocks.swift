//
//  MarkdownBlocks.swift
//  VoxNotch
//
//  Splits Markdown into independently renderable top-level blocks so a
//  streaming answer only re-parses its last block.
//

import Foundation

nonisolated enum MarkdownBlocks {

  /// Splits on blank lines outside code fences. When the previous block is a list,
  /// following list items and indented lines stay attached so numbering and nesting survive.
  static func split(_ markdown: String) -> [String] {
    var blocks: [String] = []
    var current: [Substring] = []
    var inFence = false

    func closeBlock() {
      guard !current.isEmpty else { return }
      blocks.append(current.joined(separator: "\n"))
      current = []
    }

    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        inFence.toggle()
      }

      if !inFence, trimmed.isEmpty {
        closeBlock()
        continue
      }

      if current.isEmpty, let previous = blocks.last, continuesList(previous, with: line) {
        current = [Substring(blocks.removeLast()), ""]
      }
      current.append(line)
    }
    closeBlock()
    return blocks
  }

  /// Closes markers left open mid-stream (code fences, `**`, inline code) so the
  /// partial block renders formatted instead of showing raw syntax.
  static func closingOpenMarkers(_ block: String) -> String {
    let fenceCount = block.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
      .count
    if fenceCount % 2 == 1 { return block + "\n```" }

    var result = block
    if result.components(separatedBy: "`").count % 2 == 0 { result += "`" }
    if result.components(separatedBy: "**").count % 2 == 0 {
      result = result.hasSuffix("*") && !result.hasSuffix("**") ? String(result.dropLast()) + "**" : result + "**"
    }
    return result
  }

  private static func continuesList(_ previous: String, with line: Substring) -> Bool {
    guard let firstLine = previous.split(separator: "\n", maxSplits: 1).first, isListItem(firstLine) else {
      return false
    }
    return line.first == " " || line.first == "\t" || isListItem(line)
  }

  private static func isListItem(_ line: Substring) -> Bool {
    if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { return true }
    let digits = line.prefix { $0.isNumber }
    guard !digits.isEmpty, digits.count <= 9 else { return false }
    let rest = line.dropFirst(digits.count)
    return rest.hasPrefix(". ") || rest.hasPrefix(") ")
  }
}
