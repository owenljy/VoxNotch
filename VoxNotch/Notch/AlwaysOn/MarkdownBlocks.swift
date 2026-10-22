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
    var fence: Fence?

    func closeBlock() {
      guard !current.isEmpty else { return }
      blocks.append(current.joined(separator: "\n"))
      current = []
    }

    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      updateFence(for: line, fence: &fence)

      if fence == nil, trimmed.isEmpty {
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
    var fence: Fence?
    var outside: [String] = []
    for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
      let wasInFence = fence != nil
      updateFence(for: line, fence: &fence)
      if !wasInFence, fence == nil { outside.append(String(line)) }
    }
    if let fence { return block + "\n" + String(repeating: String(fence.marker), count: fence.count) }
    let inline = outside.joined(separator: "\n")

    var result = block
    if inline.components(separatedBy: "`").count % 2 == 0 { result += "`" }
    if inline.components(separatedBy: "**").count % 2 == 0 {
      result = result.hasSuffix("*") && !result.hasSuffix("**") ? String(result.dropLast()) + "**" : result + "**"
    }
    return result
  }

  /// Renders inline LaTeX like `$O(n \\log k)$` or `$N$` as plain text. Leaves currency
  /// ("$5 and $10"), inline code and fenced code untouched.
  static func plainMath(_ block: String) -> String {
    guard block.contains("$") else { return block }
    var fence: Fence?
    return block.split(separator: "\n", omittingEmptySubsequences: false).map { line in
      let wasInFence = fence != nil
      updateFence(for: line, fence: &fence)
      guard !wasInFence, fence == nil else { return String(line) }
      // Even indices are outside `inline code`.
      return line.components(separatedBy: "`").enumerated().map { index, part in
        index.isMultiple(of: 2) ? replaceInlineMath(in: part) : part
      }.joined(separator: "`")
    }.joined(separator: "\n")
  }

  private struct Fence {
    let marker: Character
    let count: Int
  }

  private static func updateFence(for line: Substring, fence: inout Fence?) {
    let indentation = line.prefix { $0 == " " }.count
    guard indentation <= 3 else { return }
    let text = line.dropFirst(indentation)
    guard let marker = text.first, marker == "`" || marker == "~" else { return }
    let count = text.prefix { $0 == marker }.count
    guard count >= 3 else { return }
    let suffix = text.dropFirst(count)
    if let current = fence {
      if marker == current.marker, count >= current.count, suffix.allSatisfy(\.isWhitespace) { fence = nil }
    } else if marker != "`" || !suffix.contains("`") {
      fence = Fence(marker: marker, count: count)
    }
  }

  private static let inlineMath = try! NSRegularExpression(pattern: #"\$([^$\n]{1,60})\$"#)

  private static func replaceInlineMath(in text: String) -> String {
    let source = text as NSString
    var result = ""
    var cursor = 0
    for match in inlineMath.matches(in: text, range: NSRange(location: 0, length: source.length)) {
      let body = source.substring(with: match.range(at: 1))
      guard looksLikeMath(body) else { continue }
      result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
      result += latexToPlain(body)
      cursor = match.range.location + match.range.length
    }
    return result + source.substring(from: cursor)
  }

  /// Math has LaTeX markup or is a short spaceless expression; "5 and " (currency) is neither.
  private static func looksLikeMath(_ body: String) -> Bool {
    if body.contains("\\") || body.contains("^") || body.contains("_") { return true }
    let trimmed = body.trimmingCharacters(in: .whitespaces)
    guard trimmed == body, !trimmed.isEmpty, !trimmed.contains(" ") else { return false }
    return trimmed.first?.isLetter == true || trimmed.hasPrefix("(")
  }

  private static let latexSymbols: [(String, String)] = [
    ("\\log", "log"), ("\\ln", "ln"), ("\\le", "≤"), ("\\leq", "≤"), ("\\ge", "≥"), ("\\geq", "≥"),
    ("\\neq", "≠"), ("\\ne", "≠"), ("\\times", "×"), ("\\cdot", "·"), ("\\infty", "∞"),
    ("\\to", "→"), ("\\rightarrow", "→"), ("\\approx", "≈"), ("\\sum", "Σ"), ("\\sqrt", "√"),
    ("\\left", ""), ("\\right", ""), ("\\,", " "), ("\\;", " "), ("\\ ", " "),
  ]

  private static func latexToPlain(_ body: String) -> String {
    var text = body
    // Longest commands first so \leq isn't eaten by \le.
    for (command, replacement) in latexSymbols.sorted(by: { $0.0.count > $1.0.count }) {
      text = text.replacingOccurrences(of: command, with: replacement)
    }
    text = text.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
    text = text.replacingOccurrences(of: "^2", with: "²").replacingOccurrences(of: "^3", with: "³")
    return text.trimmingCharacters(in: .whitespaces)
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
