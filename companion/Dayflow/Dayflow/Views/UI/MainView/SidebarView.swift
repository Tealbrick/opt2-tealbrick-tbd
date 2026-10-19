import SwiftUI
import TBDDesign

private enum SidebarMetrics {
  static let itemSpacing: CGFloat = TBDRailMetrics.gap
  static let scale: CGFloat = 1.1
  static let itemSize: CGFloat = TBDRailMetrics.row
  static let selectedBackgroundSize: CGFloat = TBDRailMetrics.iconBox
  static let iconSize: CGFloat = TBDRailMetrics.icon
  static let fallbackSymbolSize: CGFloat = TBDRailMetrics.icon
  static let badgeSize: CGFloat = 8 * scale
  static let badgeOffsetX: CGFloat = 10 * scale
  static let badgeOffsetY: CGFloat = -10 * scale
  static let iconContainerSize: CGFloat = TBDRailMetrics.iconBox
  static let iconLabelSpacing: CGFloat = 3
  static let labelFontSize: CGFloat = TBDRailMetrics.label
}

enum SidebarIcon: CaseIterable {
  case timeline
  case daily
  case weekly
  case review
  case flow
  case agents
  case settings

  var assetName: String? {
    switch self {
    case .timeline: return "TimelineIcon"
    case .daily: return "DailyIcon"
    case .weekly: return "WeeklyIcon"
    case .review: return nil
    case .flow: return nil
    case .agents: return "AgentsIcon"
    case .settings: return nil
    }
  }

  var systemNameFallback: String? {
    switch self {
    case .review: return "rectangle.stack"
    case .flow: return "scope"
    case .agents: return "person.2"
    case .settings: return "gearshape.fill"
    default: return nil
    }
  }

  var displayName: String {
    switch self {
    case .timeline: return String(localized: "Timeline")
    case .daily:
      return String(
        localized: "sidebar.daily", defaultValue: "Daily",
        comment: "Short sidebar label for the daily recap view.")
    case .weekly:
      return String(
        localized: "sidebar.weekly", defaultValue: "Weekly",
        comment: "Short sidebar label for the weekly recap view.")
    case .review: return "Review"
    case .flow: return String(localized: "Flow")
    case .agents: return String(localized: "Agents")
    case .settings: return String(localized: "Settings")
    }
  }

  var analyticsTabName: String {
    switch self {
    case .timeline: return "timeline"
    case .daily: return "daily"
    case .weekly: return "weekly"
    case .review: return "review"
    case .flow: return "flow"
    case .agents: return "agents"
    case .settings: return "settings"
    }
  }
}

struct SidebarView: View {
  @Binding var selectedIcon: SidebarIcon
  @ObservedObject private var badgeManager = NotificationBadgeManager.shared

  private var visibleIcons: [SidebarIcon] {
    SidebarIcon.allCases.filter { icon in
      if icon == .settings { return false }
      return true
    }
  }

  /// Local Tasks and nudge demo do not depend on a hosted account.

  var body: some View {
    VStack(alignment: .center, spacing: SidebarMetrics.itemSpacing) {
      ForEach(visibleIcons, id: \.self) { icon in
        SidebarIconButton(
          icon: icon,
          isSelected: selectedIcon == icon,
          showBadge: shouldShowBadge(for: icon),
          action: {
            if icon == .settings {
              NotificationCenter.default.post(name: Notification.Name("tbdOpenSettings"), object: "account")
            } else { selectedIcon = icon }
          }
        )
        .frame(width: SidebarMetrics.itemSize, height: SidebarMetrics.itemSize)
      }
    }
  }

  private func shouldShowBadge(for icon: SidebarIcon) -> Bool {
    switch icon {
    case .daily:
      return badgeManager.hasPendingDailyRecap
    default:
      return false
    }
  }
}

struct SidebarIconButton: View {
  let icon: SidebarIcon
  let isSelected: Bool
  var showBadge: Bool = false
  let action: () -> Void

  private var iconColor: Color {
    isSelected ? TBDColor.tealInk : TBDColor.muted
  }

  private var labelColor: Color {
    isSelected ? TBDColor.tealInk : TBDColor.muted
  }

  var body: some View {
    Button(action: action) {
      VStack(spacing: SidebarMetrics.iconLabelSpacing) {
        iconBox

        Text(icon.displayName)
          .font(TBDFonts.nunito(SidebarMetrics.labelFontSize, isSelected ? TBDKit.weightLabel : TBDKit.weightNav))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .foregroundStyle(labelColor)
      }
      .frame(width: SidebarMetrics.itemSize, height: SidebarMetrics.itemSize)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contentShape(Rectangle())
    .pointingHandCursor()
  }

  private var iconBox: some View {
    return ZStack {
      if isSelected {
        // Soft rail selection (docs/design-language.md).
        TBDRailSelection()
          .frame(
            width: SidebarMetrics.selectedBackgroundSize,
            height: SidebarMetrics.selectedBackgroundSize
          )
      }

      iconImage
        .frame(width: SidebarMetrics.iconSize, height: SidebarMetrics.iconSize)

      if showBadge {
        // Badge dot: a count-red mark with a paper ring (as the kit rail).
        Capsule()
          .fill(TBDColor.countFill)
          .frame(width: SidebarMetrics.badgeSize, height: SidebarMetrics.badgeSize)
          .tbdPillEdge(TBDColor.paper)
          .offset(x: SidebarMetrics.badgeOffsetX, y: SidebarMetrics.badgeOffsetY)
      }
    }
    .frame(width: SidebarMetrics.iconContainerSize, height: SidebarMetrics.iconContainerSize)
  }

  @ViewBuilder
  private var iconImage: some View {
    if let asset = icon.assetName {
      Image(asset)
        .resizable()
        .interpolation(.high)
        .renderingMode(.template)
        .aspectRatio(contentMode: .fit)
        .foregroundStyle(iconColor)
    } else if let sys = icon.systemNameFallback {
      Image(systemName: sys)
        .font(TBDFonts.symbol(SidebarMetrics.fallbackSymbolSize, TBDKit.weightBody))
        .foregroundStyle(iconColor)
    }
  }
}
