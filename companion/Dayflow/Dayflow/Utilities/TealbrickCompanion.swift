import SwiftUI
import TBDDesign

/// Brand tokens for static sub-screen design enums and decorations: the kit (C145).
enum CompanionPalette {
  static var accent: Color { TBDColor.tealInk }
  static var fill: Color { TBDColor.tealPress }
  static var soft: Color { TBDColor.tealWash }
  static var canvas: Color { TBDColor.paper }
  static var surface: Color { TBDColor.tile }
  static var border: Color { TBDColor.line }
  static var text: Color { TBDColor.ink }
  static var muted: Color { TBDColor.muted }
  static var alert: Color { TBDColor.brickInk }
}

/// Which set of creature clips Flow plays. Sampled from tealbrick.com's logo (teal 059393, burgundy A94944).
enum TealbrickPalette: String, CaseIterable, Identifiable {
  case teal, burgundy
  var id: String { rawValue }
  var title: String { rawValue.capitalized }
  static let key = "tealbrickPalette"
  static var current: Self {
    Self(rawValue: UserDefaults.standard.string(forKey: key) ?? "teal") ?? .teal
  }
}

/// Settings › Other: the creature's palette. Only the character "brickie" has clips, so there is no character picker.
struct TealbrickCompanionSettings: View {
  @AppStorage(TealbrickPalette.key) private var palette: TealbrickPalette = .teal

  var body: some View {
    SettingsSection(
      title: String(localized: "Flow creature"),
      subtitle: String(localized: "The colors of the creature that nudges you during a Flow session.")
    ) {
      SettingsRow(label: String(localized: "Palette"), showsDivider: false) {
        TBDSegmented(selection: $palette, options: TealbrickPalette.allCases.map { ($0, $0.title) })
          .accessibilityLabel(Text("Palette"))
      }
    }
    .onChange(of: palette) { FlowCreaturePlayer.shared.refreshAppearance() }
  }
}
