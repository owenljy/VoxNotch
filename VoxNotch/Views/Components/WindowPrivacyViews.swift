import AppKit
import SwiftUI

extension View {
  /// Native help can create a separate, unprotected tooltip window. Keep its
  /// accessibility description while suppressing that window in privacy mode.
  func privacyAwareHelp(_ message: String) -> some View {
    modifier(PrivacyHelpModifier(message: message))
  }

  func privacyProtectedWindow() -> some View {
    background(WindowPrivacyAttachment())
  }

  func privacyAwarePopover<Popover: View>(
    isPresented: Binding<Bool>, arrowEdge: Edge = .top,
    @ViewBuilder content: @escaping () -> Popover
  ) -> some View {
    popover(isPresented: isPresented, arrowEdge: arrowEdge) {
      content().privacyProtectedWindow()
    }
  }

  /// Retain the usual context menu outside privacy mode. In privacy mode expose
  /// the same actions through a protected popover instead of an OS menu window.
  func privacyAwareContextMenu<Actions: View>(@ViewBuilder content: () -> Actions) -> some View {
    modifier(PrivacyContextMenuModifier(actions: content()))
  }
}

private struct PrivacyHelpModifier: ViewModifier {
  let message: String

  func body(content: Content) -> some View {
    content
      .help(SettingsManager.shared.hideFromScreenRecording ? "" : message)
      .accessibilityHint(Text(message))
  }
}

/// Attaches to the actual hosting window, including SwiftUI-created popovers.
/// AppKit attaches the content before drawing; no window lookup by title or delay.
struct WindowPrivacyAttachment: NSViewRepresentable {
  func makeNSView(context: Context) -> AttachmentView { AttachmentView() }
  func updateNSView(_ view: AttachmentView, context: Context) { view.prepareWindow() }

  final class AttachmentView: NSView {
    var privacy = WindowPrivacyManager.shared

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      prepareWindow()
    }

    override func viewWillDraw() {
      prepareWindow()
      super.viewWillDraw()
    }

    func prepareWindow() {
      if let window { privacy.prepare(window) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}

/// OS menus are independent windows. While privacy is requested, render their
/// actions inside a popover whose hosting window is prepared before drawing.
struct PrivacyMenu<Actions: View, Label: View>: View {
  private let actions: Actions
  private let label: Label
  @State private var isPresented = false

  init(@ViewBuilder content: () -> Actions, @ViewBuilder label: () -> Label) {
    actions = content()
    self.label = label()
  }

  var body: some View {
    Group {
      if SettingsManager.shared.hideFromScreenRecording {
        Button { isPresented.toggle() } label: { label }
          .buttonStyle(.plain)
          .privacyAwarePopover(isPresented: $isPresented, arrowEdge: .bottom) {
            ScrollView {
              VStack(alignment: .leading, spacing: 8) { actions }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: 280)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: 400)
            .buttonStyle(PrivacyMenuActionStyle { isPresented = false })
          }
      } else {
        Menu { actions } label: { label }
      }
    }
    .onChange(of: SettingsManager.shared.hideFromScreenRecording) { isPresented = false }
  }
}

private struct PrivacyMenuActionStyle: PrimitiveButtonStyle {
  let dismiss: () -> Void

  func makeBody(configuration: Configuration) -> some View {
    Button(role: configuration.role) {
      configuration.trigger()
      dismiss()
    } label: {
      configuration.label
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
  }
}

private struct PrivacyContextMenuModifier<Actions: View>: ViewModifier {
  let actions: Actions

  @ViewBuilder func body(content: Content) -> some View {
    if SettingsManager.shared.hideFromScreenRecording {
      content
        .padding(.trailing, 28)
        .overlay(alignment: .trailing) {
          PrivacyMenu { actions } label: {
            Image(systemName: "ellipsis")
              .frame(width: 24, height: 24)
              .contentShape(Rectangle())
          }
          .accessibilityLabel("More actions")
        }
    } else {
      content.contextMenu { actions }
    }
  }
}
