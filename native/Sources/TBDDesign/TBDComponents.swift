import SwiftUI

// Kit components for SwiftUI: field, select (brick); tag, count, chip, switch, segmented, status pill (pill);
// notice (brick); StepFlow (C126 + C128). Values only from TBDColor / TBDKit / TBDTokens.

// MARK: - Field (brick)

/// Labelled text field: label 15/800 above, brick input (tile, 1.5pt line-strong ring, ink-soft ring on hover),
/// the focus ring at 2pt offset, optional hint (muted) and error (brick-ink 700 + 2pt brick ring).
public struct TBDField: View {
    let label: String
    let prompt: String
    @Binding var text: String
    let secure: Bool
    let hint: String?
    let error: String?
    @FocusState private var focused: Bool
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.tbdForcedState) private var forced

    public init(_ label: String, text: Binding<String>, prompt: String = "", secure: Bool = false, hint: String? = nil, error: String? = nil) {
        self.label = label; self._text = text; self.prompt = prompt; self.secure = secure; self.hint = hint; self.error = error
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(TBDFonts.nunito(TBDKit.textLabel, TBDKit.weightLabel)).foregroundStyle(TBDColor.ink)
            input
            if let error, !error.isEmpty {
                Text(error).font(TBDFonts.nunito(TBDKit.textTag, TBDKit.weightNav)).foregroundStyle(TBDColor.dangerInk)
            } else if let hint, !hint.isEmpty {
                Text(hint).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var input: some View {
        let invalid = !(error ?? "").isEmpty
        let state = forced ?? (hovered ? .hover : .normal)
        return ZStack(alignment: .leading) {
            // Our own placeholder, so it always uses the placeholder token (AppKit draws prompts in its own grey).
            if text.isEmpty { Text(prompt).foregroundStyle(TBDColor.fieldPlaceholder).lineLimit(1).accessibilityHidden(true) }
            Group {
                if secure { SecureField(text: $text, prompt: Text("")) { Text(label) } }
                else { TextField(text: $text, prompt: Text("")) { Text(label) } }
            }
            .textFieldStyle(.plain)
            .focused($focused)
            .focusEffectDisabled()
        }
        .font(TBDFonts.nunito(TBDKit.textControl, TBDKit.weightBody))
        .foregroundStyle(enabled ? TBDColor.fieldOn : TBDColor.disabledOn)
        .padding(.horizontal, TBDTokens.Control.paddingX)
        .frame(minHeight: TBDTokens.Control.minHeight)
        .background(enabled ? TBDColor.fieldFill : TBDColor.disabledFill, in: TBDBrickShape())
        .overlay {
            if enabled {
                TBDBrickShape().strokeBorder(invalid ? TBDColor.fieldInvalidEdge : state == .hover ? TBDColor.fieldHoverEdge : TBDColor.fieldEdge,
                                             lineWidth: invalid ? 2 : TBDKit.hair)
            }
        }
        .tbdFocusRing(enabled && (focused || state == .focus), offset: TBDKit.focusOffsetTight)
        .onHover { hovered = $0 }
        .accessibilityLabel(label)
    }
}

// MARK: - Select (brick trigger; the option list is the system menu — native exception, TBD-MAPPING.md)

public struct TBDSelect<Value: Hashable>: View {
    let label: String?
    @Binding var selection: Value
    let options: [(Value, String)]
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.tbdForcedState) private var forced

    public init(_ label: String? = nil, selection: Binding<Value>, options: [(Value, String)]) {
        self.label = label; self._selection = selection; self.options = options
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label { Text(label).font(TBDFonts.nunito(TBDKit.textLabel, TBDKit.weightLabel)).foregroundStyle(TBDColor.ink) }
            trigger
                .overlay {
                    // The real control: an invisible borderless menu over the drawn trigger, so the list is the macOS menu.
                    Menu {
                        ForEach(options.indices, id: \.self) { i in
                            Button { selection = options[i].0 } label: {
                                if options[i].0 == selection { Label(options[i].1, systemImage: "checkmark") } else { Text(options[i].1) }
                            }
                        }
                    } label: { Color.clear.contentShape(Rectangle()) }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .opacity(0.02)
                    .accessibilityLabel(label ?? title)
                    .accessibilityValue(title)
                }
                .onHover { hovered = $0 }
        }
    }

    private var title: String { options.first { $0.0 == selection }?.1 ?? "" }

    private var trigger: some View {
        let state = forced ?? (hovered ? .hover : .normal)
        return HStack(spacing: TBDKit.s3) {
            Text(title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down").font(TBDFonts.symbol(11, TBDKit.weightLabel)).accessibilityHidden(true)
        }
        .font(TBDFonts.nunito(TBDKit.textControl, TBDMetrics.selectValueWeight))   // the value reads like field text (kit .tb-select-value)
        .foregroundStyle(enabled ? TBDColor.fieldOn : TBDColor.disabledOn)
        .padding(.horizontal, TBDTokens.Control.paddingX)
        .frame(minHeight: TBDTokens.Control.minHeight)
        .background(enabled ? TBDColor.fieldFill : TBDColor.disabledFill, in: TBDBrickShape())
        .overlay { if enabled { TBDBrickShape().strokeBorder(state == .hover ? TBDColor.fieldHoverEdge : TBDColor.fieldEdge, lineWidth: TBDKit.hair) } }
        .tbdFocusRing(state == .focus, offset: TBDKit.focusOffsetTight)
    }
}

// MARK: - Pills: tag / status, count, filter chip, switch, segmented, status pill

/// A pill edge drawn as a filled ring (outer capsule minus inner capsule). A stroked full-round shape leaves
/// tick artefacts at its ends in AppKit's bitmap rendering; the filled ring is exact everywhere.
public struct TBDPillEdge: Shape {
    var width: CGFloat
    public init(_ width: CGFloat = TBDKit.hair) { self.width = width }
    public func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRoundedRect(in: rect, cornerSize: CGSize(width: rect.height / 2, height: rect.height / 2))
        let inner = rect.insetBy(dx: width, dy: width)
        p.addRoundedRect(in: inner, cornerSize: CGSize(width: inner.height / 2, height: inner.height / 2))
        return p
    }
}
public extension View {
    func tbdPillEdge(_ color: Color, width: CGFloat = TBDKit.hair) -> some View {
        overlay(TBDPillEdge(width).fill(color, style: FillStyle(eoFill: true)).allowsHitTesting(false))
    }
}

public enum TBDStatus: Sendable { case idle, live, busy, needsYou, open }

/// Tag / status badge (pill, 28pt, 14/700). Live = teal wash; needs-you = brick wash; open = dashed.
public struct TBDTag: View {
    let text: String
    let status: TBDStatus
    public init(_ text: String, status: TBDStatus = .idle) { self.text = text; self.status = status }
    public var body: some View {
        let (fill, on, edge): (Color, Color, Color) = switch status {
        case .idle, .open: (TBDColor.statusIdleFill, TBDColor.statusIdleOn, TBDColor.statusIdleEdge)
        case .live: (TBDColor.statusLiveFill, TBDColor.statusLiveOn, TBDColor.statusLiveEdge)
        case .busy: (TBDColor.statusBusyFill, TBDColor.statusBusyOn, TBDColor.statusBusyEdge)
        case .needsYou: (TBDColor.statusNeedsYouFill, TBDColor.statusNeedsYouOn, TBDColor.statusNeedsYouEdge)
        }
        HStack(spacing: TBDKit.s2) {
            if status == .busy { Capsule().fill(TBDColor.teal).frame(width: 14, height: 4).accessibilityHidden(true) }
            Text(text)
        }
        .font(TBDTokens.Typography.tag)
        .foregroundStyle(on)
        .lineLimit(1)
        .padding(.horizontal, TBDKit.s3)
        .frame(minHeight: 28)
        .background(status == .open ? Color.clear : fill, in: Capsule())
        .tbdPillEdge(status == .open ? Color.clear : edge)
        .overlay { if status == .open { Capsule().strokeBorder(TBDColor.lineStrong, style: StrokeStyle(lineWidth: TBDKit.hair, dash: [4, 3])) } }
    }
}

/// Counter (pill, 24pt): brick red with on-brick, or ink for neutral counts.
public struct TBDCount: View {
    let value: Int
    let ink: Bool
    public init(_ value: Int, ink: Bool = false) { self.value = value; self.ink = ink }
    public var body: some View {
        Text("\(value)")
            .font(TBDFonts.nunito(TBDKit.textControl, TBDKit.weightLabel))
            .monospacedDigit()
            .foregroundStyle(ink ? TBDColor.primaryOn : TBDColor.countOn)
            .padding(.horizontal, TBDKit.s2)
            .frame(minWidth: 24, minHeight: 24)
            .background(ink ? TBDColor.primaryFill : TBDColor.countFill, in: Capsule())
    }
}

/// Focus ring for pill controls, read inside the button (where `isFocused` is the control's own focus).
private struct TBDPillPress: ButtonStyle {
    @Environment(\.tbdForcedState) private var forced
    func makeBody(configuration: Configuration) -> some View { TBDPillPressBody(configuration: configuration, forced: forced) }
}
private struct TBDPillPressBody: View {
    let configuration: ButtonStyleConfiguration
    let forced: TBDControlState?
    @Environment(\.isFocused) private var focused
    var body: some View { configuration.label.tbdFocusRing(focused || forced == .focus, pill: true) }
}

/// Filter chip (pill, 36pt): line-strong ring, muted 700; pressed = ink fill.
public struct TBDFilterChip: View {
    let text: String
    @Binding var isOn: Bool
    @State private var hovered = false
    @Environment(\.tbdForcedState) private var forced
    public init(_ text: String, isOn: Binding<Bool>) { self.text = text; self._isOn = isOn }
    public var body: some View {
        let hover = (forced ?? (hovered ? .hover : .normal)) == .hover
        let fill = isOn ? (hover ? TBDColor.tabCurrentHoverFill : TBDColor.tabCurrentFill) : (hover ? TBDColor.tabHoverFill : TBDColor.tabFill)
        let on = isOn ? (hover ? TBDColor.tabCurrentHoverOn : TBDColor.tabCurrentOn) : (hover ? TBDColor.tabHoverOn : TBDColor.tabOn)
        Button { isOn.toggle() } label: {
            Text(text).font(TBDTokens.Typography.tag).foregroundStyle(on)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 14).frame(minHeight: 36)
                .background(fill, in: Capsule())
                .tbdPillEdge(isOn ? Color.clear : TBDColor.tabEdge)
                .contentShape(Capsule())
        }
        .buttonStyle(TBDPillPress())
        .onHover { hovered = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Switch (pill 44×26): plate track with a line-strong ring and an ink-soft thumb; on = teal-ink track, paper thumb.
public struct TBDSwitchStyle: ToggleStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { TBDSwitchBody(configuration: configuration) }
}
private struct TBDSwitchBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let on = configuration.isOn
        HStack(spacing: TBDKit.s3) {
            configuration.label.font(TBDTokens.Typography.body).foregroundStyle(TBDColor.ink)
            Spacer(minLength: 0)
            Button { withAnimation(TBDMotion.animation(TBDMotion.standard, reduce: reduceMotion)) { configuration.isOn.toggle() } } label: {
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule().fill(on ? TBDColor.tealInk : TBDColor.plate)
                    TBDPillEdge().fill(on ? Color.clear : TBDColor.lineStrong, style: FillStyle(eoFill: true))
                    Circle().fill(on ? TBDColor.paper : TBDColor.inkSoft).frame(width: 18, height: 18).padding(4)
                }
                .frame(width: 44, height: 26)
                .opacity(enabled ? 1 : 0.45)
            }
            .buttonStyle(TBDPillPress())
        }
        // VoiceOver and keyboard users get a real toggle with its own label, not "Switch".
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// Segmented toggle (pill): plate track, tile thumb with a line-strong ring, 14/700.
public struct TBDSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @State private var hovered: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(selection: Binding<Value>, options: [(Value, String)]) { self._selection = selection; self.options = options }
    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let current = options[i].0 == selection
                Button { withAnimation(TBDMotion.animation(TBDMotion.standard, reduce: reduceMotion)) { selection = options[i].0 } } label: {
                    Text(options[i].1)
                        .font(TBDTokens.Typography.tag)
                        .foregroundStyle(current || hovered == i ? TBDColor.ink : TBDColor.muted)
                        .padding(.horizontal, 14).frame(minHeight: 30)
                        .background(current ? TBDColor.tile : Color.clear, in: Capsule())
                        .tbdPillEdge(current ? TBDColor.lineStrong : Color.clear)
                        .contentShape(Capsule())
                }
                .buttonStyle(TBDPillPress())
                .onHover { hovered = $0 ? i : (hovered == i ? nil : hovered) }
                .accessibilityAddTraits(current ? .isSelected : [])
            }
        }
        .padding(3)
        .background(TBDColor.plate, in: Capsule())
    }
}

/// Small floating status indicator (meeting / recording): ink pill with a swatch, fixed dark over desktop content.
public struct TBDStatusPill: View {
    let text: String
    let tone: Color
    public init(_ text: String, tone: Color = TBDColor.teal) { self.text = text; self.tone = tone }
    public var body: some View {
        HStack(spacing: TBDKit.s2) {
            Circle().fill(tone).frame(width: 10, height: 10).accessibilityHidden(true)
            Text(text).font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightLabel))
        }
        .foregroundStyle(TBDColor.overlayOn)
        .padding(.leading, TBDKit.s3).padding(.trailing, 14)
        .frame(minHeight: 32)
        .background(TBDColor.overlayFill, in: Capsule())
        .shadow(color: TBDColor.shadowInk, radius: TBDKit.floatShadowRadius, y: TBDKit.floatShadowY)
    }
}

/// Earlier status chip API: now a pill tag with a colour dot.
public struct TBDChip: View {
    let text: String
    let color: Color
    public init(_ text: String, color: Color = TBDTokens.accent) { self.text = text; self.color = color }
    public var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(text).font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightNav)).foregroundStyle(TBDColor.ink)
        }
        .padding(.horizontal, 10).frame(minHeight: 24)
        .background(TBDColor.tile, in: Capsule())
        .tbdPillEdge(TBDColor.line)
    }
}

// MARK: - Notice (brick)

public enum TBDNoticeTone: Sendable { case neutral, live, needsYou }

/// Notice: brick; tile + ring (neutral), teal wash (live) or brick wash (needs-you). No side bar.
public struct TBDNotice: View {
    let text: String
    let tone: TBDNoticeTone
    /// Extra space so each line box is the kit's 26pt body line (SwiftUI has no line-height).
    private var extraLine: CGFloat { max(0, TBDMetrics.noticeLineHeight - TBDFonts.lineHeight(TBDKit.textLabel)) }
    public init(_ text: String, tone: TBDNoticeTone = .neutral) { self.text = text; self.tone = tone }
    public var body: some View {
        let (fill, on, edge): (Color, Color, Color) = switch tone {
        case .neutral: (TBDColor.tile, TBDColor.inkSoft, TBDColor.line)
        case .live: (TBDColor.statusLiveFill, TBDColor.statusLiveOn, TBDColor.statusLiveEdge)
        case .needsYou: (TBDColor.statusNeedsYouFill, TBDColor.statusNeedsYouOn, TBDColor.statusNeedsYouEdge)
        }
        Text(text)
            .font(TBDFonts.nunito(TBDKit.textLabel, TBDMetrics.noticeWeight))   // kit .tb-notice: 15/400, padding 14 16
            .foregroundStyle(on)
            .lineSpacing(extraLine)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, TBDMetrics.noticePaddingH).padding(.vertical, TBDMetrics.noticePaddingV + extraLine / 2)
            .background(fill, in: TBDBrickShape())
            .overlay(TBDBrickShape().strokeBorder(edge, lineWidth: TBDKit.hair))
            .textSelection(.enabled)
    }
}

// MARK: - StepFlow (C126 + C128)

/// One step of a StepFlow.
public struct TBDStep {
    public let name: String
    public let optional: Bool
    public let nextLabel: String
    public let skipLabel: String
    public let canAdvance: Bool
    public let content: AnyView
    public init<Content: View>(_ name: String, nextLabel: String = "Next", optional: Bool = false, skipLabel: String = "Skip",
                               canAdvance: Bool = true, @ViewBuilder content: () -> Content) {
        self.name = name; self.nextLabel = nextLabel; self.optional = optional; self.skipLabel = skipLabel
        self.canAdvance = canAdvance; self.content = AnyView(content())
    }
}

/// ONE step at a time in ONE fixed size: top = every step as "n-Name" (current full ink 800, done = teal-ink ✓ and
/// clickable, others at 62%), middle = only the current step (scrolls), bottom = Previous / Skip (optional steps) / Next.
/// A step change fades the middle to the ground and back (ease-in out, ease-out in, --tb-dur-step); instant with reduced motion.
public struct TBDStepFlow: View {
    let steps: [TBDStep]
    @Binding var current: Int
    let size: CGSize
    let finish: () -> Void
    @State private var visible = true
    @State private var shown: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(steps: [TBDStep], current: Binding<Int>, size: CGSize = CGSize(width: 560, height: TBDKit.stepflowHeight), finish: @escaping () -> Void) {
        self.steps = steps; self._current = current; self.size = size; self.finish = finish
        self._shown = State(initialValue: current.wrappedValue)
    }

    public var body: some View {
        let step = steps[min(shown, steps.count - 1)]
        VStack(alignment: .leading, spacing: 0) {
            stepRow.padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 14)
            ScrollView(.vertical) {
                step.content.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.vertical, TBDKit.s5)
            }
            .opacity(visible ? 1 : 0)
            .frame(maxHeight: .infinity)
            HStack(spacing: TBDKit.s3) {
                // A flow's actions are its main actions: 44pt (--tb-target), TBD-MAPPING §5.
                if shown > 0 { Button("Previous") { go(shown - 1) }.buttonStyle(TBDButtonStyle(.secondary, size: .large)) }
                Spacer(minLength: 0)
                if step.optional { Button(step.skipLabel) { advance() }.buttonStyle(TBDButtonStyle(.quiet, size: .large)) }
                Button(step.nextLabel) { advance() }
                    .buttonStyle(TBDButtonStyle(.primary, size: .large))
                    .disabled(!step.canAdvance)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28).padding(.top, TBDKit.s4).padding(.bottom, TBDKit.s5)
            .overlay(alignment: .top) { Rectangle().fill(TBDColor.line).frame(height: TBDKit.hair) }
        }
        .frame(width: size.width, height: size.height)
        .background(TBDColor.tile)
        .onChange(of: current) { _, new in if new != shown { go(new) } }
    }

    private var stepRow: some View {
        HStack(spacing: TBDKit.s4) {
            ForEach(steps.indices, id: \.self) { i in
                let done = i < shown
                let label = Text("\(i + 1)-\(steps[i].name)\(done ? " ✓" : "")")
                    .font(TBDFonts.nunito(TBDKit.textTag, i == shown ? TBDKit.weightLabel : TBDKit.weightNav))
                    .foregroundStyle(i == shown ? TBDColor.ink : done ? TBDColor.tealInk : TBDColor.ink.opacity(0.62))
                // Done steps are buttons (go back). The others are plain text: a disabled button would dim them below AA.
                if done {
                    Button { go(i) } label: { label }.buttonStyle(.plain)
                } else {
                    label.accessibilityAddTraits(i == shown ? .isSelected : [])
                }
            }
        }
    }

    private func advance() { if shown + 1 < steps.count { go(shown + 1) } else { finish() } }

    private func go(_ index: Int) {
        guard index != shown, steps.indices.contains(index) else { return }
        current = index
        if reduceMotion { shown = index; return }
        withAnimation(TBDMotion.stepOut) { visible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + TBDKit.durStep) {
            shown = index
            withAnimation(TBDMotion.stepIn) { visible = true }
        }
    }
}

/// A function that needs an app the workspace has not paid for, or not installed (C282): lock mark + the sentence
/// ("Available with Rules & Approvals."). Muted hint text; it replaces the control, never sits beside a live one.
public struct TBDAvailableWith: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        HStack(spacing: TBDKit.s2) {
            Image(systemName: "lock").font(TBDFonts.symbol(TBDKit.textHint)).foregroundStyle(TBDColor.muted).accessibilityHidden(true)
            Text(text).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
