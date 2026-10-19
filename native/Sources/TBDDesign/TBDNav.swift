import SwiftUI

// Side navigation (the kit's AppShell side nav / tabs, C126): brick items, current = ink fill with paper text,
// others muted 700 with a plate hover; grouped under small sentence-case section labels.

/// A labelled group of side-nav items (Settings: Chat, Companion, Listen, App).
public struct TBDNavSection<Content: View>: View {
    let title: String
    let content: Content
    public init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(TBDTokens.Typography.label)
                .foregroundStyle(TBDColor.muted)
                .padding(.horizontal, TBDKit.s3)
                .padding(.bottom, TBDKit.s1)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

/// One side-nav item: SF Symbol + label in a 36pt brick. `ringed: false` = a plain list row (no idle ring), for long
/// lists such as Settings where a ring on every row reads as a column of buttons (TBD-UX-01).
public struct TBDNavItem: View {
    let title: String
    let symbol: String?
    let current: Bool
    let ringed: Bool
    let action: () -> Void
    public init(_ title: String, symbol: String? = nil, current: Bool, ringed: Bool = true, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.current = current; self.ringed = ringed; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            HStack(spacing: TBDKit.s2) {
                if let symbol {
                    Image(systemName: symbol).font(TBDFonts.symbol(TBDKit.textControl)).frame(width: 18).accessibilityHidden(true)
                }
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(TBDNavItemStyle(current: current, ringed: ringed))
        .accessibilityAddTraits(current ? .isSelected : [])
        .help(title)
    }
}

private struct TBDNavItemStyle: ButtonStyle {
    let current: Bool
    let ringed: Bool
    func makeBody(configuration: Configuration) -> some View {
        TBDNavItemBody(current: current, ringed: ringed, configuration: configuration)
    }
}

private struct TBDNavItemBody: View {
    let current: Bool
    let ringed: Bool
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false
    @Environment(\.isFocused) private var focused
    @Environment(\.tbdForcedState) private var forced
    var body: some View {
        let hover = (forced ?? (hovered ? .hover : .normal)) == .hover || configuration.isPressed
        let idle = ringed ? TBDColor.tabFill : Color.clear
        let fill = current ? (hover ? TBDColor.tabCurrentHoverFill : TBDColor.tabCurrentFill) : (hover ? TBDColor.tabHoverFill : idle)
        let on = current ? (hover ? TBDColor.tabCurrentHoverOn : TBDColor.tabCurrentOn) : (hover ? TBDColor.tabHoverOn : TBDColor.tabOn)
        configuration.label
            .font(TBDFonts.nunito(TBDKit.textControl, TBDMetrics.navWeight))   // kit .tb-tab / .tb-shell-nav: 700 in every state
            .foregroundStyle(on)
            .padding(.horizontal, TBDMetrics.navPaddingH)
            .frame(maxWidth: .infinity, minHeight: TBDTokens.Control.minHeight, alignment: .leading)
            .background(fill, in: TBDBrickShape())
            .overlay { if !current && ringed { TBDBrickShape().strokeBorder(TBDColor.tabEdge, lineWidth: TBDMetrics.navIdleRing) } }
            .contentShape(TBDBrickShape())
            .tbdFocusRing(focused || forced == .focus, offset: TBDKit.focusOffsetTight)
            .onHover { hovered = $0 }
    }
}
