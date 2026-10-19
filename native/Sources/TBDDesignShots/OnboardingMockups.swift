// WP-ONB onboarding mockups (C285 STREAMLINE; spec coordination/leads/tbd/ONBOARDING-SPEC.md).
// Static views for Martin's review, NOT app code: nothing here is wired to TBD. Branch mockup/wp-onb only.
// Built on the kit's own TBDStepFlow (the flow the app will use), so the mockup is the real chrome.
// Usage: swift run tbd-design-shots --onboarding-mockups <outDir>  → onb-<screen>-1280-<theme>.png + contrast audit.
import SwiftUI
import TBDDesign

enum OnbScreen: String, CaseIterable {
    case welcome, portal, agent, permissions, models, summaryAll = "summary-all-on", summarySome = "summary-some-skipped"
    var step: Int {
        switch self {
        case .welcome: return 0
        case .portal: return 1
        case .agent: return 2
        case .permissions: return 3
        case .models: return 4
        case .summaryAll, .summarySome: return 5
        }
    }
}

struct OnboardingMockup: View {
    let screen: OnbScreen

    var body: some View {
        VStack(alignment: .leading, spacing: TBDKit.s5) {
            VStack(alignment: .leading, spacing: TBDKit.s1) {
                Text("Set up TBD").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
                Text("Everything TBD needs, before you start. A \"No\" is fine: you can change every answer later.")
                    .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            }
            TBDStepFlow(steps: steps, current: .constant(screen.step), size: CGSize(width: 860, height: 640)) {}
                .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
                .clipShape(TBDBrickShape())
        }
        .padding(TBDKit.s10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TBDColor.paper)
    }

    private var steps: [TBDStep] {
        [
            TBDStep("Welcome", nextLabel: "Start") { welcome },
            TBDStep("Workspace", optional: true, skipLabel: "No, not now") { portal },
            TBDStep("TBD's agent", optional: true, skipLabel: "No, not now") { agent },
            TBDStep("Permissions") { permissions },
            TBDStep("Models", optional: true, skipLabel: "Skip for now") { models },
            TBDStep("Summary", nextLabel: "Open TBD") { screen == .summarySome ? AnyView(summary(allOn: false)) : AnyView(summary(allOn: true)) },
        ]
    }

    // MARK: Step 0: Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: TBDKit.s5) {
            Text("Welcome to TBD").font(TBDTokens.Typography.display).foregroundStyle(TBDColor.ink)
            Text("TBD sets up four things now, so nothing looks broken later. It takes about 3 minutes.")
                .font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft)
            VStack(alignment: .leading, spacing: TBDKit.s3) {
                bullet("person.2", "Your Teal Brick workspace", "Workspace agents and teams in Chat.")
                bullet("sparkles", "TBD's own agent", "An agent that runs on this Mac.")
                bullet("lock.shield", "macOS permissions", "Screen, microphone, accessibility, notifications.")
                bullet("cpu", "Models", "For your timeline, Daily and Weekly, and dictation.")
            }
            TBDNotice("TBD starts with new, empty data. It does not read or change the data of the old TBD.")
        }
    }

    private func bullet(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: TBDKit.s3) {
            Image(systemName: symbol).foregroundStyle(TBDColor.tealInk).frame(width: 22)
            Text(title).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
            Text(detail).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        }
    }

    // MARK: Step 1: Portal (device sign-in, then the workspace picker)

    private var portal: some View {
        VStack(alignment: .leading, spacing: TBDKit.s5) {
            question("Use TBD with your Teal Brick workspace?")
            HStack(spacing: TBDKit.s3) {
                choice("Yes, sign in", "Workspace agents, teams, Save to Knowledge.", selected: true)
                choice("No", "TBD works on this Mac only. You can sign in later.", selected: false)
            }
            .fixedSize(horizontal: false, vertical: true)
            panel {
                VStack(alignment: .leading, spacing: TBDKit.s3) {
                    HStack(spacing: TBDKit.s2) {
                        Text("1. Approve this code in your browser").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                        Spacer(minLength: 0)
                        TBDTag("Waiting for you", status: .busy)
                    }
                    HStack(spacing: TBDKit.s4) {
                        Text("KXRT-4QPL").font(TBDFonts.nunito(TBDKit.textH2, TBDKit.weightHead)).foregroundStyle(TBDColor.ink)
                        Button("Open browser") {}.buttonStyle(TBDButtonStyle(.secondary))
                        Button("Copy code") {}.buttonStyle(TBDButtonStyle(.quiet))
                    }
                    Text("portal.tealbrick.com/device · the code expires in 9 minutes")
                        .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                }
            }
            panel {
                HStack(spacing: TBDKit.s2) {
                    Text("2. Choose a workspace").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                    Spacer(minLength: 0)
                    Text("after you approve the code").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                }
            }
        }
    }

    // MARK: Step 2: TBD's own agent (harness, provider, test, pairing)

    private var agent: some View {
        VStack(alignment: .leading, spacing: TBDKit.s4) {
            question("Run TBD's own agent on this Mac?")
            HStack(spacing: TBDKit.s3) {
                choice("Yes", "An agent in Chat that can use your timeline and notes.", selected: true)
                choice("No", "Chat shows only your workspace agents.", selected: false)
            }
            .fixedSize(horizontal: false, vertical: true)
            fieldRow("Agent") {
                TBDTag("TBD's agent", status: .live)
                Text("Codex, Eve and LangChain: coming later").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            }
            fieldRow("Runs on") {
                segment("Subscription", selected: false)
                segment("API key", selected: false)
                segment("Model on this Mac", selected: true)
            }
            panel {
                VStack(alignment: .leading, spacing: TBDKit.s3) {
                    HStack(spacing: TBDKit.s3) {
                        Image(systemName: "checkmark.circle").foregroundStyle(TBDColor.tealInk)
                        Text("Ollama found on this Mac").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                        Spacer(minLength: 0)
                        Text("qwen3:8b").font(TBDTokens.Typography.mono).foregroundStyle(TBDColor.inkSoft)
                        Button("Change") {}.buttonStyle(TBDButtonStyle(.quiet))
                    }
                    HStack(spacing: TBDKit.s3) {
                        Button("Test the model") {}.buttonStyle(TBDButtonStyle(.secondary))
                        TBDTag("Works · answered in 1.4 s", status: .live)
                    }
                }
            }
            fieldRow("Workspace") {
                TBDTag("Paired with Studio North", status: .live)
                Text("Your workspace agents can see TBD's agent.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            }
        }
    }

    // MARK: Step 3: Permissions (live status; Screen recording relaunch)

    private var permissions: some View {
        VStack(alignment: .leading, spacing: TBDKit.s4) {
            question("Allow what TBD needs on this Mac")
            VStack(spacing: 0) {
                permissionRow("display", "Screen recording", "For your timeline, Daily and Weekly.") {
                    VStack(alignment: .trailing, spacing: TBDKit.s1) {
                        Button("Quit and reopen TBD") {}.buttonStyle(TBDButtonStyle(.primary))
                        Text("macOS turns it on when TBD starts again. You come back here.")
                            .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                    }
                }
                divider
                permissionRow("mic", "Microphone", "For dictation and meeting notes.") { TBDTag("Allowed", status: .live) }
                divider
                permissionRow("accessibility", "Accessibility", "Without it, dictation cannot type into other apps.") {
                    HStack(spacing: TBDKit.s2) {
                        Button("Not now") {}.buttonStyle(TBDButtonStyle(.quiet))
                        Button("Allow") {}.buttonStyle(TBDButtonStyle(.secondary))
                    }
                }
                divider
                permissionRow("bell", "Notifications", "When Daily is ready, or an agent needs you.") { TBDTag("Allowed", status: .live) }
            }
            .background(TBDColor.paper, in: TBDBrickShape())
            .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
            Text("TBD checks every 2 seconds. Calendar access is asked later, in Meetings.")
                .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        }
    }

    private func permissionRow<Trailing: View>(_ symbol: String, _ title: String, _ detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: TBDKit.s3) {
            Image(systemName: symbol).foregroundStyle(TBDColor.inkSoft).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                Text(detail).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            }
            Spacer(minLength: TBDKit.s4)
            trailing()
        }
        .padding(.horizontal, TBDKit.s4).padding(.vertical, TBDKit.s3)
    }

    private var divider: some View { Rectangle().fill(TBDColor.line).frame(height: TBDKit.hair) }

    // MARK: Step 4: Models for Companion and Listen

    private var models: some View {
        VStack(alignment: .leading, spacing: TBDKit.s4) {
            question("Analyse your screen activity with a model?")
            fieldRow("Runs on") {
                segment("Subscription", selected: false)
                segment("API key", selected: false)
                segment("Model on this Mac", selected: true)
            }
            panel {
                VStack(alignment: .leading, spacing: TBDKit.s3) {
                    HStack(spacing: TBDKit.s3) {
                        Text("Qwen3-VL 4B").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                        Text("for your timeline, Daily and Weekly · 3.3 GB").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                        Spacer(minLength: 0)
                        TBDTag("Downloading", status: .busy)
                    }
                    progress(0.62)
                    Text("2.1 of 3.3 GB · about 2 minutes left · you can go on, it continues in the background")
                        .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                }
            }
            question("Speech model for dictation and meetings")
            panel {
                HStack(spacing: TBDKit.s3) {
                    Text("Parakeet v3").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                    Text("works offline · 640 MB").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                    Spacer(minLength: 0)
                    TBDTag("On this Mac", status: .live)
                }
            }
        }
    }

    private func progress(_ value: CGFloat) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(TBDColor.line)
                Capsule().fill(TBDColor.teal).frame(width: g.size.width * value)
            }
        }
        .frame(height: 8)
    }

    // MARK: Step 5: Summary (one plain line per area)

    private struct Line { let on: Bool; let area: String; let text: String; let action: String }

    private func summary(allOn: Bool) -> some View {
        let lines: [Line] = allOn ? [
            Line(on: true, area: "Workspace", text: "Signed in to Studio North. Your workspace agents and teams are in Chat.", action: "Change"),
            Line(on: true, area: "TBD's agent", text: "TBD's agent runs on this Mac with qwen3:8b.", action: "Change"),
            Line(on: true, area: "Screen activity", text: "TBD records your screen and makes your timeline.", action: "Change"),
            Line(on: true, area: "Daily and Weekly", text: "Daily and Weekly use Qwen3-VL 4B on this Mac.", action: "Change"),
            Line(on: true, area: "Dictation and meetings", text: "Dictation and meeting notes work. The speech model is on this Mac.", action: "Change"),
            Line(on: true, area: "Notifications", text: "TBD tells you when Daily is ready and when an agent needs you.", action: "Change"),
            Line(on: true, area: "Knowledge", text: "Save to Knowledge works.", action: "Change"),
        ] : [
            Line(on: true, area: "Workspace", text: "Signed in to Studio North. Your workspace agents and teams are in Chat.", action: "Change"),
            Line(on: false, area: "TBD's agent", text: "TBD's agent is off. Chat has only your workspace agents.", action: "Set up"),
            Line(on: true, area: "Screen activity", text: "TBD records your screen and makes your timeline.", action: "Change"),
            Line(on: false, area: "Daily and Weekly", text: "No model for Daily and Weekly. Your timeline is recorded, not summarised.", action: "Choose a model"),
            Line(on: false, area: "Dictation", text: "Download the speech model to dictate.", action: "Download"),
            Line(on: true, area: "Notifications", text: "TBD tells you when Daily is ready and when an agent needs you.", action: "Change"),
            Line(on: false, area: "Knowledge", text: "Knowledge is not in your workspace plan.", action: "Open in Portal"),
        ]
        let off = lines.filter { !$0.on }.count
        return VStack(alignment: .leading, spacing: TBDKit.s4) {
            VStack(alignment: .leading, spacing: TBDKit.s1) {
                Text(off == 0 ? "Everything is ready." : "TBD works. \(off) things are off.")
                    .font(TBDTokens.Typography.display).foregroundStyle(TBDColor.ink)
                if !allOn {
                    Text("You can turn them on later in Settings, or now with the buttons below.")
                        .font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft)
                }
            }
            VStack(spacing: 0) {
                ForEach(lines.indices, id: \.self) { i in
                    if i > 0 { divider }
                    summaryLine(lines[i])
                }
            }
            .background(TBDColor.paper, in: TBDBrickShape())
            .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
        }
    }

    /// A missing area is never red: a "No" is a valid answer (spec, Summary lines).
    private func summaryLine(_ line: Line) -> some View {
        HStack(spacing: TBDKit.s3) {
            Image(systemName: line.on ? "checkmark.circle" : "circle.dashed")
                .foregroundStyle(line.on ? TBDColor.tealInk : TBDColor.muted).frame(width: 22)
            Text(line.area).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink).frame(width: 190, alignment: .leading)
            Text(line.text).font(TBDTokens.Typography.hint).foregroundStyle(line.on ? TBDColor.inkSoft : TBDColor.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: TBDKit.s3)
            Button(line.action) {}.buttonStyle(TBDButtonStyle(line.on ? .quiet : .secondary))
        }
        .padding(.horizontal, TBDKit.s4).padding(.vertical, TBDKit.s2)
    }

    // MARK: Shared pieces

    private func question(_ text: String) -> some View {
        Text(text).font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
    }

    private func choice(_ title: String, _ detail: String, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: TBDKit.s3) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? TBDColor.tealInk : TBDColor.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                Text(detail).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(TBDKit.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(selected ? TBDColor.tealWash : TBDColor.paper, in: TBDBrickShape())
        .overlay(TBDBrickShape().strokeBorder(selected ? TBDColor.tealWashLine : TBDColor.line, lineWidth: TBDKit.hair))
    }

    private func segment(_ title: String, selected: Bool) -> some View {
        Button(title) {}.buttonStyle(TBDButtonStyle(selected ? .primary : .quiet))
    }

    private func fieldRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: TBDKit.s3) {
            Text(label).font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted).frame(width: 90, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(TBDKit.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TBDColor.paper, in: TBDBrickShape())
            .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
    }
}

/// Renders the 6 steps and the 2 summary states at 1280 × 800, light and dark, with the rendered contrast audit.
@MainActor func runOnboardingMockups() throws {
    for screen in OnbScreen.allCases {
        for dark in [false, true] {
            try render(OnboardingMockup(screen: screen), size: CGSize(width: 1280, height: 800), dark: dark,
                       to: "onb-\(String(format: "%d", screen.step))-\(screen.rawValue)-1280-\(dark ? "dark" : "light")")
        }
    }
}
