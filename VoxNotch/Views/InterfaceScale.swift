import SwiftUI

/// Shared rhythm for content windows. Keep compact recording overlays independent.
enum InterfaceScale {
  enum Space {
    static let micro: CGFloat = 2
    static let small: CGFloat = 4
    static let medium: CGFloat = 8
    static let large: CGFloat = 16
    static let section: CGFloat = 32
  }

  /// Major-third modular scale: each level is 1.25 times the previous one.
  enum Typography {
    static let ratio: CGFloat = 1.25
    static let bodySize: CGFloat = 13
    static let caption = Font.system(size: bodySize / ratio)
    static let body = Font.system(size: bodySize)
    static let heading = Font.system(size: bodySize * ratio, weight: .semibold)
    static let title = Font.system(size: bodySize * ratio * ratio, weight: .semibold)
    static let display = Font.system(size: bodySize * ratio * ratio * ratio, weight: .bold)
  }
}

extension View {
  func settingsFormLayout() -> some View {
    self
      .formStyle(.grouped)
      .font(InterfaceScale.Typography.body)
      .lineSpacing(InterfaceScale.Space.small)
      .scrollIndicators(.never)
      .padding(InterfaceScale.Space.medium)
  }

  func settingsSectionHeading() -> some View {
    self
      .font(InterfaceScale.Typography.heading)
      .padding(.top, InterfaceScale.Space.medium)
      .padding(.bottom, InterfaceScale.Space.small)
  }

  func settingsSectionNote() -> some View {
    self
      .font(InterfaceScale.Typography.body)
      .lineSpacing(InterfaceScale.Space.small)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, InterfaceScale.Space.small)
  }
}
