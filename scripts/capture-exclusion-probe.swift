// Window owner for CaptureExclusionPixelTests. It must be a separate process: a window
// server may let an app capture its own windows, so self-capture proves nothing.
//
// Usage: capture-exclusion-probe <none|cgs|both> <x> <y> <width> <height> [hidden]
// (top-left global coordinates in points). Shows an unprotected magenta window (kept off
// screen with `hidden`), prints READY, then accepts `protect`, `show`, `repaint` and `quit`
// lines on stdin.
import AppKit

typealias MainConnectionID = @convention(c) () -> UInt32
typealias SetWindowCaptureExcludeShape = @convention(c) (UInt32, Int, CFTypeRef?) -> Int32
typealias RegionCreateWithRect = @convention(c) (CGRect) -> Unmanaged<CFTypeRef>?

let args = CommandLine.arguments
guard args.count == 6 || args.count == 7, let x = Double(args[2]), let y = Double(args[3]),
      let width = Double(args[4]), let height = Double(args[5])
else {
  FileHandle.standardError.write("usage: capture-exclusion-probe <none|cgs|both> x y w h [hidden]\n".data(using: .utf8)!)
  exit(2)
}
let mode = args[1]
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
if args.count == 6 { window.orderFrontRegardless() }

func excludeWithCGS() -> Bool {
  let handle = dlopen(nil, RTLD_NOW)
  guard let c = dlsym(handle, "CGSMainConnectionID"),
        let e = dlsym(handle, "CGSSetWindowCaptureExcludeShape"),
        let r = dlsym(handle, "CGRegionCreateWithRect"),
        let region = unsafeBitCast(r, to: RegionCreateWithRect.self)(
          CGRect(origin: .zero, size: window.frame.size)
        )?.takeRetainedValue()
  else { return false }
  let connection = unsafeBitCast(c, to: MainConnectionID.self)()
  return unsafeBitCast(e, to: SetWindowCaptureExcludeShape.self)(connection, window.windowNumber, region) == 0
}

func handle(_ command: String) {
  switch command {
  case "protect":
    var ok = true
    if mode == "none" || mode == "both" { window.sharingType = .none }
    if mode == "cgs" || mode == "both" { ok = excludeWithCGS() }
    print("OK protect \(ok)")
  case "show":
    window.orderFrontRegardless()
    print("OK show")
  case "repaint":
    // A barely different magenta, so the capturer sees damage without a colour change.
    let red = window.backgroundColor.redComponent
    window.backgroundColor = NSColor(srgbRed: red == 1 ? 0.98 : 1, green: 0, blue: 1, alpha: 1)
    print("OK repaint")
  case "quit":
    exit(0)
  default:
    print("ERR \(command)")
  }
}

Thread.detachNewThread {
  while let line = readLine() {
    let command = line.trimmingCharacters(in: .whitespaces)
    DispatchQueue.main.async { handle(command) }
  }
  exit(0)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { print("READY \(window.windowNumber)") }
app.run()
