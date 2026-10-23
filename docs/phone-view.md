# Phone View

Enable from the phone button beside Ask or Settings → Always-On → Phone View,
then scan the QR code on an iPhone, iPad or Android device on the same reachable local
network. No mobile installation or external service is involved.

The upper pane shows both speakers, including partial speech; the lower pane
renders streaming Markdown, code, lists and tables. Each pane scrolls separately.
The answer slider browses locally on the phone. Follow Mac resumes mirroring the
desktop's displayed answer, including desktop previews. A session change resets
the phone's selection. The page pauses polling in the background and reconnects
when brought forward. Keep the browser in the foreground while reading.

## Pane layout

Drag the middle handle with a finger, mouse or iPad trackpad to resize the panes.
Each pane has a minimum usable size. Auto layout stacks portrait and narrow
windows, and uses columns in wide landscape windows. The layout selector can
explicitly choose Stacked or Side by side; very narrow windows fall back to a
stacked layout even when columns are preferred.

The browser remembers separate vertical and horizontal proportions and the layout
mode for the connection's origin. Rotating or resizing an iPad Split View window
preserves these preferences. The reset button or double-clicking the divider
restores that axis to its default. With the divider focused, arrow keys resize,
Shift increases the step, and Home/End move to the allowed limits. Browser storage
can be unavailable in private modes; resizing still works in the current page.

## Desktop visibility

Once enabling succeeds, the Mac's Always-On pane and any open Settings window are
immediately ordered offscreen; capture and answer generation continue. Its attached popover is replaced by a
separate protected pairing window so the QR remains scannable. Only a successful
authenticated snapshot request closes the pairing window. Unauthenticated requests
do not dismiss it, and a failed enable does not hide the original pane.

The menu bar's Phone & iPad View… reopens controls without stopping Always-On.
Show Always-On Panel, or Show Mac Pane in those controls, explicitly restores the
desktop pane. Manually reopened controls remain visible. Refreshing the QR repeats
the pairing flow. Turning sharing off or losing the connection keeps the desktop
pane hidden, so private text is not unexpectedly revealed.

## Connection and privacy

- Starts only after an explicit Enable action during an active Always-On session.
  Nothing is saved to enable listening automatically after relaunch.
- Network.framework listens on one chosen IPv4 address of a physical network or
  local bridge. Loopback is used in automated tests. No port forwarding, public
  relay, Bonjour advertisement or external page assets are used.
- Each start or New QR Code action generates a new 256-bit random key. It travels
  in the URL fragment, is removed from the address bar, and is retained only for
  that browser tab/session. Snapshot requests use an Authorization header.
- Only the current in-memory session is serialized through an explicit DTO.
  No audio, API keys, provider settings, custom prompts or database history are
  served. There are no remote commands or settings endpoints.
- HTTP is **not encrypted**. The random key prevents unauthenticated reads; it
  does not protect against someone observing traffic on the network. Use trusted
  Wi-Fi and keep the QR/link private. This is not an Internet sharing service.
- Host/Origin checks, no CORS, no-store responses, an inline-script CSP hash and
  text-node Markdown rendering reduce cross-site and content injection risks.
  Request size, connection count and receive time are bounded.
- Stop, capture failure, sleep and normal app shutdown cancel the listener and
  connections. Old keys cannot authenticate after refresh. The page clears its
  text when connection is lost; already viewed/copied text cannot be recalled.

## Validation

`MobileCompanionTests` exercises actual loopback HTTP authentication, key
rotation, snapshot serialization, parser limits, request origin/host rejection,
conditional updates, QR decoding from the rendered pairing view, and WebKit
loading the real served page under its CSP. It also checks independent answer
navigation, partial and streaming text, escaped model content, session reset,
connection clearing and portrait/landscape layout.

Additional checks cover an iPad-sized viewport matrix, narrow Split View windows,
touch/mouse resizing, cancellation, keyboard adjustment, bounds, independent axis
preferences, reload persistence, and the separate QR/hidden Mac pane lifecycle.

WebKit rendering tests exercise the browser engine at phone and iPad viewports;
they do not replace scanning from physical iPhone/Android hardware on the user's
Wi-Fi or physical iPad touch testing. Synthetic PointerEvents stub pointer capture
because offscreen WebKit tests cannot own a real pointer; the page's gesture
handlers and layout still run. Device isolation, firewall rules, Wi-Fi changes and OS permission dialogs
need checking on the actual network. The initial version requires IPv4 and does
not support cellular access, IPv6-only networks, screen wake locks or controlling
the Mac from the phone.
