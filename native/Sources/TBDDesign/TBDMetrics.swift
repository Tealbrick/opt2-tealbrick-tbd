import SwiftUI

/// Component metrics that are not tokens but must match the web kit (components.css). The components read them, and
/// the sameness proof (tbd-design-shots --sameness) reports them, so the proof can never drift from the drawing.
public enum TBDMetrics {
    /// .tb-notice: padding 14 16, 15/400.
    public static let noticePaddingH: CGFloat = TBDKit.s4
    public static let noticePaddingV: CGFloat = 14
    public static let noticeWeight: Font.Weight = TBDKit.weightBody
    /// The kit notice inherits the body line: 16 × 1.6 rounded to an even pixel = 26.
    public static let noticeLineHeight: CGFloat = (TBDKit.textBody * TBDKit.leadingBody / 2).rounded() * 2
    /// .tb-tab / .tb-shell-nav > a: padding 0 16, 700 in every state, a 1.5 tab-edge ring when not current.
    public static let navPaddingH: CGFloat = TBDKit.s4
    public static let navWeight: Font.Weight = TBDKit.weightNav
    public static let navIdleRing: CGFloat = TBDKit.hair
    /// .tb-select-value reads like field text: 14/400.
    public static let selectValueWeight: Font.Weight = TBDKit.weightBody
    /// .tb-app-icon: a 1.5 line ring (--tb-ring) in light, none in dark.
    public static let appIconRingLight: CGFloat = TBDKit.hair
    /// .tbd-app-chip: padding 0 10 0 6, 28 high.
    public static let appChipPaddingLeading: CGFloat = 6
    public static let appChipPaddingTrailing: CGFloat = 10
    /// Settings content column (TBD-UX-01): every pane uses the tile width up to this, then centres.
    public static let settingsContentMax: CGFloat = 960
}
