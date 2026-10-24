// Window owner for CaptureExclusionPixelTests. It must be a separate process: a window
// server may let an app capture its own windows, so self-capture proves nothing.
//
// Usage: capture-exclusion-probe <none|cgs|both> <x> <y> <width> <height> [hidden]
// (top-left global coordinates in points). Shows an unprotected magenta window (kept off
// screen with `hidden`), prints READY, then accepts protect/unprotect/show/grow/repaint/quit.
// Compile with VoxNotch/Managers/CaptureExclusion.swift so this exercises production code.
import AppKit
import SwiftUI

let args = CommandLine.arguments
guard args.count == 6 || args.count == 7, let x = Double(args[2]), let y = Double(args[3]),
      let width = Double(args[4]), let height = Double(args[5])
else {
  FileHandle.standardError.write("usage: capture-exclusion-probe <none|cgs|both> x y w h [hidden]\n".data(using: .utf8)!)
  exit(2)
}
let mode = args[1]
guard ["none", "cgs", "both"].contains(mode) else { exit(2) }
var protected = false
setvbuf(stdout, nil, _IOLBF, 0)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screenHeight = NSScreen.screens[0].frame.height
let window = NSWindow(
  contentRect: NSRect(x: x, y: screenHeight - y - height, width: width, height: height),
  styleMask: [.borderless], backing: .buffered, defer: false
)
window.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
window.level = .statusBar
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
var hosting: NSHostingView<Color>?
if ProcessInfo.processInfo.environment["VOXNOTCH_PROBE_SWIFTUI"] == "1" {
  let view = NSHostingView(rootView: Color(nsColor: window.backgroundColor))
  view.sizingOptions = []
  window.contentView = view
  hosting = view
}
if args.count == 6 { window.orderFrontRegardless() }

@MainActor
private enum ProbeCommands {
  static func updateProtection() -> Bool {
    if mode != "cgs" { window.sharingType = protected ? .none : .readOnly }
    if mode != "none" {
      guard CaptureExclusion.apply(to: window, size: protected ? window.frame.size : nil) else { return false }
      CaptureExclusion.refreshSurface(of: window, size: protected ? window.frame.size : nil)
    }
    return true
  }

  static func handle(_ command: String) {
    switch command {
    case "rapidOn", "rapidOff":
      protected = command == "rapidOff"
      let first = updateProtection()
      // Leave the old refresh's delayed phase pending when the preference changes.
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) {
        protected.toggle()
        print("OK \(command) \(ProbeCommands.updateProtection() && first)")
      }
    case "protect", "unprotect":
      protected = command == "protect"
      print("OK \(command) \(updateProtection())")
    case "grow":
      var frame = window.frame
      frame.origin.y -= 80
      frame.size.width += 80
      frame.size.height += 80
      window.setFrame(frame, display: false)
      print("OK grow \(updateProtection())")
    case "show":
      window.orderFrontRegardless()
      print("OK show")
    case "repaint":
      // A barely different magenta, so the capturer sees damage without a colour change.
      let red = window.backgroundColor.redComponent
      window.backgroundColor = NSColor(srgbRed: red == 1 ? 0.98 : 1, green: 0, blue: 1, alpha: 1)
      hosting?.rootView = Color(nsColor: window.backgroundColor)
      print("OK repaint")
    case "quit":
      exit(0)
    default:
      print("ERR \(command)")
    }
  }
}

Thread.detachNewThread {
  while let line = readLine() {
    let command = line.trimmingCharacters(in: .whitespaces)
    DispatchQueue.main.async { ProbeCommands.handle(command) }
  }
  exit(0)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { print("READY \(window.windowNumber)") }
app.run()
