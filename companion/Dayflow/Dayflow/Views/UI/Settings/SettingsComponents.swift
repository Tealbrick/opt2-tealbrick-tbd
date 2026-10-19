import SwiftUI
import TBDDesign

// MARK: - Settings design system
//
// One visual language, enforced here, built on the TBDDesign kit. If you find
// yourself reaching outside these tokens / components while building a
// settings screen, stop and ask whether what you're about to build needs its
// own grammar or whether an existing primitive can carry the weight. Almost
// always the latter.
//
// Principles:
//   1. The paper IS the surface. Sections are ruled, not boxed. Only content
//      that is really an object (a provider card) uses .tbdCard().
//   2. Hierarchy from type roles (title / control / hint), not from borders
//      and backgrounds.
//   3. One accent (teal-ink) for links, active marks and progress.
//   4. Exactly three button treatments, all TBDButtonStyle. No one-offs.
//   5. Rows always read label-left, control-right. Always.

// MARK: - Tokens

enum SettingsStyle {
  // Spacing
  static let sectionSpacing: CGFloat = TBDKit.s8
  static let rowVerticalPadding: CGFloat = TBDKit.s3

  // Type colors
  static var text: Color { TBDColor.ink }
  static var secondary: Color { TBDColor.muted }
  static var meta: Color { TBDColor.muted }

  // Structure
  static var divider: Color { TBDColor.line }

  // Subtle fills (hover, tracks, neutral badges)
  static var subtleFill: Color { TBDColor.plate }

  static var editorFill: Color { TBDColor.fieldFill }
  static var editorBorder: Color { TBDColor.fieldEdge }

  // The one accent — links, active marks, progress fills, focused states.
  static var ink: Color { TBDColor.tealInk }
  static var primaryButtonFill: Color { TBDColor.primaryFill }

  // Destructive — only for destructive confirm buttons and error copy.
  static var destructive: Color { TBDColor.brickInk }

  // Status colours (text-safe twins; the label carries the word).
  static var statusGood: Color { TBDColor.tealInk }
  static var statusIdle: Color { TBDColor.muted }
  static var statusWarn: Color { TBDColor.brickInk }
  static var statusBad: Color { TBDColor.brickInk }
}

// MARK: - SettingsSection
//
// A section is a ruled block: a hairline on top (none for the first section of
// a pane: the pane header sits there), a title (with optional subtitle) and content beneath.
// No container chrome — the paper is the container. Optional right-rail
// trailing view for metadata ("Last updated 3m ago", totals, badges).

struct SettingsSection<Content: View, Trailing: View>: View {
  let title: String
  let subtitle: String?
  let isFirst: Bool
  let trailing: () -> Trailing
  let content: () -> Content

  init(
    title: String,
    subtitle: String? = nil,
    isFirst: Bool = false,
    @ViewBuilder trailing: @escaping () -> Trailing,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.subtitle = subtitle
    self.isFirst = isFirst
    self.trailing = trailing
    self.content = content
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // The pane header (SettingsPaneHeader) opens every pane; the first section needs no rule of its own.
      if !isFirst {
        Rectangle()
          .fill(TBDColor.line)
          .frame(height: TBDKit.hair)
          .padding(.bottom, TBDKit.s5)
      }

      // An untitled section (title "") is the pane's own first block: the pane header names it.
      if !title.isEmpty || subtitle != nil {
        HStack(alignment: .firstTextBaseline, spacing: TBDKit.s4) {
          VStack(alignment: .leading, spacing: TBDKit.s1) {
            Text(title)
              .font(TBDTokens.Typography.title)
              .foregroundStyle(TBDColor.ink)
            if let subtitle {
              Text(subtitle)
                .font(TBDTokens.Typography.hint)
                .foregroundStyle(TBDColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          Spacer(minLength: TBDKit.s3)
          trailing()
        }
        .padding(.bottom, TBDKit.s4)
      }

      content()
    }
  }
}

extension SettingsSection where Trailing == EmptyView {
  init(
    title: String, subtitle: String? = nil, isFirst: Bool = false,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.init(
      title: title, subtitle: subtitle, isFirst: isFirst, trailing: { EmptyView() },
      content: content)
  }
}

// MARK: - SettingsPaneHeader
//
// Opens every Settings pane (TBD-UX-01): the pane title in the display role and
// one line under it. Panes do not draw their own top title.

struct SettingsPaneHeader: View {
  let title: String
  let subtitle: String

  var body: some View {
    VStack(alignment: .leading, spacing: TBDKit.s1) {
      Text(title)
        .font(TBDTokens.Typography.display)
        .tracking(TBDTokens.Typography.displayTracking)
        .foregroundStyle(TBDColor.ink)
        .accessibilityAddTraits(.isHeader)
      Text(subtitle)
        .font(TBDTokens.Typography.hint)
        .foregroundStyle(TBDColor.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - SettingsRow
//
// Same look as TBDSettingsRow: label left (control weight), help under it
// (hint, muted), control right, hairline below. If the row needs a
// full-width accessory (progress bar, expanded calendar), compose it
// manually — we intentionally keep this component minimal so every row
// on every tab has identical rhythm.

struct SettingsRow<Trailing: View>: View {
  let label: String
  let subtitle: String?
  let showsDivider: Bool
  let trailing: () -> Trailing

  init(
    label: String,
    subtitle: String? = nil,
    showsDivider: Bool = true,
    @ViewBuilder trailing: @escaping () -> Trailing
  ) {
    self.label = label
    self.subtitle = subtitle
    self.showsDivider = showsDivider
    self.trailing = trailing
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: TBDKit.s5) {
        VStack(alignment: .leading, spacing: 3) {
          Text(label)
            .font(TBDTokens.Typography.control)
            .foregroundStyle(TBDColor.ink)
            .fixedSize(horizontal: false, vertical: true)
          if let subtitle {
            Text(subtitle)
              .font(TBDTokens.Typography.hint)
              .foregroundStyle(TBDColor.muted)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: TBDKit.s3)
        trailing()
      }
      .padding(.vertical, SettingsStyle.rowVerticalPadding)

      if showsDivider {
        Rectangle()
          .fill(TBDColor.line)
          .frame(height: TBDKit.hair)
      }
    }
  }
}

extension SettingsRow where Trailing == EmptyView {
  init(label: String, subtitle: String? = nil, showsDivider: Bool = true) {
    self.init(
      label: label, subtitle: subtitle, showsDivider: showsDivider, trailing: { EmptyView() })
  }
}

// MARK: - Buttons
//
// EXACTLY THREE BUTTON TREATMENTS. If you need a fourth, you're wrong.
//
//   SettingsPrimaryButton   — TBDButtonStyle(.primary). One per section, for
//                             the action that defines the section.
//   SettingsSecondaryButton — TBDButtonStyle(.secondary). For alternative
//                             actions next to or beneath a primary
//                             (Save/Reset, Open folder, Edit).
//   SettingsLinkButton      — link-coloured control text + optional arrow
//                             glyph. For navigation away from this surface
//                             (release notes, external docs).

struct SettingsPrimaryButton: View {
  let title: String
  var systemImage: String? = nil
  var isLoading: Bool = false
  var isDisabled: Bool = false
  /// One primary per screen: a second main-looking action passes `prominent: false` (secondary look, same API).
  var prominent: Bool = true
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: TBDKit.s2) {
        if isLoading {
          ProgressView()
            .controlSize(.small)
            .tint(prominent ? TBDColor.primaryOn : TBDColor.secondaryOn)
        } else if let systemImage {
          Image(systemName: systemImage)
            .font(TBDFonts.symbol(12))
        }
        Text(title)
      }
    }
    .buttonStyle(TBDButtonStyle(prominent ? .primary : .secondary))
    .disabled(isDisabled || isLoading)
    .pointingHandCursor()
  }
}

struct SettingsSecondaryButton: View {
  let title: String
  var systemImage: String? = nil
  var isDisabled: Bool = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        if let systemImage {
          Image(systemName: systemImage)
            .font(TBDFonts.symbol(12))
        }
        Text(title)
      }
    }
    .buttonStyle(TBDButtonStyle(.secondary))
    .disabled(isDisabled)
    .pointingHandCursor()
  }
}

struct SettingsLinkButton: View {
  let title: String
  var systemImage: String? = "arrow.up.right"
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Text(title)
          .font(TBDTokens.Typography.control)
        if let systemImage {
          Image(systemName: systemImage)
            .font(TBDFonts.symbol(11))
        }
      }
      .foregroundStyle(TBDColor.link)
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }
}

// MARK: - SettingsStatusDot
//
// Every status in settings reads through this component (public name kept
// for callers). A short label renders as a TBDTag; a long one (a test
// result message) renders as a TBDNotice so it can wrap. The tone carries
// the colour, the label carries the word: good = live, idle = idle,
// warn / bad = needs-you.

struct SettingsStatusDot: View {
  enum State {
    case good, idle, warn, bad
  }

  let state: State
  let label: String

  /// Longest label that still reads as a single-line tag.
  private static let tagLimit = 28

  var body: some View {
    if label.count <= Self.tagLimit {
      TBDTag(label, status: tagStatus)
    } else {
      TBDNotice(label, tone: noticeTone)
    }
  }

  private var tagStatus: TBDStatus {
    switch state {
    case .good: return .live
    case .idle: return .idle
    case .warn, .bad: return .needsYou
    }
  }

  private var noticeTone: TBDNoticeTone {
    switch state {
    case .good: return .live
    case .idle: return .neutral
    case .warn, .bad: return .needsYou
    }
  }
}

// MARK: - SettingsToggle
//
// The standard on/off control for a settings row: the kit switch. It sizes
// to its content so it hugs the right edge of the row.

struct SettingsToggle: View {
  @Binding var isOn: Bool

  var body: some View {
    Toggle(isOn: $isOn) { EmptyView() }
      .toggleStyle(TBDSwitchStyle())
      .fixedSize()
      .pointingHandCursor()
  }
}

// MARK: - SettingsBadge
//
// A tag replacing the legacy `BadgeView` on settings surfaces. Deliberately
// has only two tones: accent (live) for the one-per-group "this is the
// active thing" signal, and neutral (idle) for everything else. Callers pass
// all-caps copy; it is shown in sentence case (no uppercase labels).

struct SettingsBadge: View {
  let text: String
  var isAccent: Bool = false

  private var displayText: String {
    guard text == text.uppercased(), text != text.lowercased() else { return text }
    let lower = text.lowercased()
    return lower.prefix(1).uppercased() + lower.dropFirst()
  }

  var body: some View {
    TBDTag(displayText, status: isAccent ? .live : .idle)
      .accessibilityLabel(Text(text))
  }
}

// MARK: - SettingsMetadata
//
// The standard right-rail text treatment. Use this anywhere the trailing
// view is informational text (counts, sizes, percentages, timestamps) so
// every bit of right-rail metadata reads the same.

struct SettingsMetadata: View {
  let text: String
  var body: some View {
    Text(text)
      .font(TBDTokens.Typography.hint)
      .foregroundStyle(TBDColor.muted)
  }
}
