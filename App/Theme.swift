import SwiftUI
import UIKit

enum AppAppearance: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  static let storageKey = "daywell.appearance"
  var id: String { rawValue }

  var title: String {
    switch self {
    case .system: return "跟随系统"
    case .light: return "浅色"
    case .dark: return "深色"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system: return nil
    case .light: return .light
    case .dark: return .dark
    }
  }
}

enum DaywellTheme {
  static let background = adaptive(light: 0xF5F5FA, dark: 0x101425)
  static let surface = adaptive(light: 0xFFFFFF, dark: 0x1A2034)
  static let text = adaptive(light: 0x25243B, dark: 0xF2F1FC)
  static let muted = adaptive(light: 0x76758B, dark: 0xA6AEC5)
  static let border = adaptive(light: 0xEAE9F1, dark: 0x2C334A)
  static let accent = adaptive(light: 0x6655B5, dark: 0xC4B7FF)
  static let accentText = adaptive(light: 0xFFFFFF, dark: 0x282040)
  static let soft = adaptive(light: 0xEEEBFA, dark: 0x302945)
  static let hero = adaptive(light: 0xE8E1FA, dark: 0x302B4B)

  private static func adaptive(light: UInt32, dark: UInt32) -> Color {
    Color(
      UIColor { traits in
        let hex = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(
          red: CGFloat((hex >> 16) & 255) / 255,
          green: CGFloat((hex >> 8) & 255) / 255,
          blue: CGFloat(hex & 255) / 255, alpha: 1)
      })
  }
}

extension View {
  func daywellCard(padding: CGFloat = 20) -> some View {
    self.padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(DaywellTheme.surface, in: RoundedRectangle(cornerRadius: 24))
      .overlay(RoundedRectangle(cornerRadius: 24).stroke(DaywellTheme.border, lineWidth: 1))
  }
}

struct PrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.headline)
      .frame(maxWidth: .infinity, minHeight: 50)
      .foregroundStyle(DaywellTheme.accentText)
      .background(
        DaywellTheme.accent.opacity(configuration.isPressed ? 0.8 : 1),
        in: RoundedRectangle(cornerRadius: 16))
  }
}
