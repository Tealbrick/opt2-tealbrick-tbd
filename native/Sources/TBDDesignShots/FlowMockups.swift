// Flow mockups (WP4/WP5 Flow, C3, C142, C282) for the parts v1 Flow did not have: the Task Board source, plan vs
// actual from Companion's timeline, and the observer's model choice. The v1 parts (overlay, creature, pills, Tasks
// list, focus timer, paste a plan) are a straight port and are not mocked here. Design: coordination/leads/tbd/DESIGN-FLOW.md.
// Static views for review, NOT app code. Branch mockup/wp-flow only.
// Usage: swift run tbd-design-shots --flow-mockups <outDir>  → flow-<screen>-<theme>.png + contrast audit.
import SwiftUI
import TBDDesign

enum FlowMockScreen: String, CaseIterable { case todayTaskBoard = "today-taskboard", todayLocal = "today-local", addFromTaskBoard = "add-from-taskboard", planVsActual = "plan-vs-actual", observer }

private enum Label3 { case on, off, rest, none }

private struct PlanRow: Identifiable {
    let id: String
    let title: String
    let time: String
    let tracked: String
    var source: String? = nil
    var done = false
    var now = false
    var looksDone = false
}

private struct CardRow: Identifiable {
    let id: String
    let time: String
    let title: String
    let apps: String
    let label: Label3
    let labelText: String
    let by: String
}

struct FlowMockup: View {
    let screen: FlowMockScreen

    var body: some View {
        ZStack {
            page.padding(TBDKit.s8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if screen == .addFromTaskBoard {
                TBDColor.scrim
                addSheet
            }
        }
        .background(TBDColor.paper)
    }

    @ViewBuilder private var page: some View {
        switch screen {
        case .todayTaskBoard, .addFromTaskBoard: today(taskBoard: true)
        case .todayLocal: today(taskBoard: false)
        case .planVsActual: planVsActual
        case .observer: observer
        }
    }

    // MARK: M1 / M2 — Today

    private func today(taskBoard: Bool) -> some View {
        VStack(alignment: .leading, spacing: TBDKit.s5) {
            header("Flow", label: "Companion · Today's plan · Sunday 19 October") {
                HStack(spacing: TBDKit.s2) {
                    TBDTag(taskBoard ? "From Task Board" : "Only on this Mac", status: taskBoard ? .live : .idle)
                    TBDTag("Observer: text only on this Mac", status: .live)
                }
            }
            tabs(selected: "Today")
            if !taskBoard {
                TBDNotice("Task list from Task Board: available with Task Board. Until then TBD keeps this list on this Mac.", tone: .neutral)
            }
            dayStrip
            HStack(alignment: .top, spacing: TBDKit.s6) {
                VStack(alignment: .leading, spacing: TBDKit.s3) {
                    sectionTitle("Plan", trailing: taskBoard ? "4 tasks · 3 from Task Board" : "4 tasks")
                    planList(taskBoard ? taskBoardPlan : localPlan, taskBoard: taskBoard)
                    HStack(spacing: TBDKit.s2) {
                        if taskBoard { Button("Add from Task Board") {}.buttonStyle(TBDButtonStyle(.secondary)) }
                        Button("Paste a plan") {}.buttonStyle(TBDButtonStyle(.secondary))
                        Button("Add a task") {}.buttonStyle(TBDButtonStyle(.quiet))
                        if !taskBoard { Button("Import from Tasklist") {}.buttonStyle(TBDButtonStyle(.quiet)) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: TBDKit.s4) {
                    nowCard
                    offPlanCard
                }
                .frame(width: 340)
            }
        }
    }

    private var taskBoardPlan: [PlanRow] {[
        PlanRow(id: "a", title: "Release TBD dev.13", time: "08:30 – 09:40", tracked: "1 h 05 min on plan", source: "Task Board · TBD", done: true),
        PlanRow(id: "b", title: "Flow mockups for Martin", time: "09:40 – 11:30", tracked: "1 h 20 min on plan", source: "Task Board · TBD", now: true),
        PlanRow(id: "c", title: "Reply to Eyal about the design review", time: "11:30 – 11:45", tracked: "10 min on plan", source: "Task Board · Ops", looksDone: true),
        PlanRow(id: "d", title: "Weekly review", time: "16:00 – 16:30", tracked: "not started", source: "Only on this Mac"),
    ]}

    private var localPlan: [PlanRow] {[
        PlanRow(id: "a", title: "Release TBD dev.13", time: "08:30 – 09:40", tracked: "1 h 05 min on plan", done: true),
        PlanRow(id: "b", title: "Flow mockups for Martin", time: "09:40 – 11:30", tracked: "1 h 20 min on plan", now: true),
        PlanRow(id: "c", title: "Reply to Eyal about the design review", time: "11:30 – 11:45", tracked: "not started"),
        PlanRow(id: "d", title: "Weekly review", time: "16:00 – 16:30", tracked: "not started"),
    ]}

    private func planList(_ rows: [PlanRow], taskBoard: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: TBDKit.s2) {
                    HStack(alignment: .firstTextBaseline, spacing: TBDKit.s3) {
                        Image(systemName: row.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(row.done || row.now ? TBDColor.tealInk : TBDColor.muted)
                        VStack(alignment: .leading, spacing: TBDKit.s1) {
                            HStack(spacing: TBDKit.s2) {
                                Text(row.title).font(TBDTokens.Typography.control).foregroundStyle(row.done ? TBDColor.muted : TBDColor.ink)
                                if row.now { TBDTag("Now", status: .live) }
                            }
                            HStack(spacing: TBDKit.s2) {
                                Text(row.time).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                                if let source = row.source { Text("· \(source)").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted) }
                            }
                        }
                        Spacer(minLength: 0)
                        Text(row.tracked).font(TBDTokens.Typography.label).foregroundStyle(row.tracked == "not started" ? TBDColor.muted : TBDColor.inkSoft)
                    }
                    if row.looksDone {
                        HStack(spacing: TBDKit.s2) {
                            TBDTag("Looks done", status: .needsYou)
                            Text("The observer saw the reply sent at 11:41.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                            Spacer(minLength: 0)
                            Button("Mark done on Task Board") {}.buttonStyle(TBDButtonStyle(.primary))
                            Button("Not yet") {}.buttonStyle(TBDButtonStyle(.quiet))
                        }
                        .padding(.leading, 28)
                    }
                }
                .padding(.vertical, TBDKit.s3)
                .padding(.horizontal, TBDKit.s4)
                .background(row.now ? TBDColor.tealWash : Color.clear, in: TBDBrickShape())
                Rectangle().fill(TBDColor.line).frame(height: TBDKit.hair)
            }
        }
    }

    private var nowCard: some View {
        card {
            Text("Now").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted)
            Text("Flow mockups for Martin").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
            Text("Focus · 18:42 left").font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft)
            HStack(spacing: TBDKit.s2) {
                Button("Pause") {}.buttonStyle(TBDButtonStyle(.secondary))
                Button("Stop") {}.buttonStyle(TBDButtonStyle(.quiet))
                Button("Break 5 min") {}.buttonStyle(TBDButtonStyle(.quiet))
            }
            Text("Next: Reply to Eyal at 11:30").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        }
    }

    private var offPlanCard: some View {
        card {
            HStack {
                Text("Off plan today").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted)
                Spacer(minLength: 0)
                Text("55 min").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.brickInk)
            }
            ForEach([("News and social", "Safari · 30 min"), ("Inbox and Portal review", "Mail, Portal · 25 min")], id: \.0) { item in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.0).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                        Text(item.1).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                    }
                    Spacer(minLength: 0)
                    Button("This was…") {}.buttonStyle(TBDButtonStyle(.quiet))
                }
            }
        }
    }

    // MARK: Day strip (plan vs actual, Companion timeline)

    private var dayStrip: some View {
        card {
            HStack(alignment: .firstTextBaseline) {
                Text("Plan vs actual · from your timeline").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted)
                Spacer(minLength: 0)
                Text("On plan 2 h 35 min · Off plan 55 min · Break 15 min").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.inkSoft)
            }
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(strip.enumerated()), id: \.offset) { _, seg in
                        Rectangle().fill(color(seg.0)).frame(width: max(2, geo.size.width * seg.1 - 2))
                    }
                }
            }
            .frame(height: 18)
            .clipShape(TBDBrickShape())
            HStack(spacing: TBDKit.s4) {
                legend(.on, "On plan"); legend(.off, "Off plan"); legend(.rest, "Break"); legend(.none, "Not tracked yet")
                Spacer(minLength: 0)
                Text("08:30").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                Text("–").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                Text("16:30").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            }
        }
    }

    private let strip: [(Label3, CGFloat)] = [(.on, 0.135), (.off, 0.05), (.on, 0.10), (.rest, 0.03), (.on, 0.07), (.off, 0.065), (.on, 0.02), (.none, 0.53)]

    private func color(_ l: Label3) -> Color {
        switch l { case .on: TBDColor.teal; case .off: TBDColor.brick; case .rest: TBDColor.toneStone; case .none: TBDColor.plate }
    }

    private func legend(_ l: Label3, _ text: String) -> some View {
        HStack(spacing: TBDKit.s1) {
            Rectangle().fill(color(l)).frame(width: 12, height: 12).overlay(Rectangle().strokeBorder(TBDColor.lineStrong, lineWidth: 1))
            Text(text).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.inkSoft)
        }
    }

    // MARK: M3 — Add from Task Board (sheet)

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: TBDKit.s4) {
            Text("Add from Task Board").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
            Text("Issues assigned to you in Polygonface. TBD keeps the times on this Mac; Task Board has no times.")
                .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                issueRow("Flow mockups for Martin", project: "TBD", status: "In progress", picked: true, time: "09:40 – 11:30")
                issueRow("Weekly review", project: "Ops", status: "Ready", picked: true, time: "16:00 – 16:30")
                issueRow("Draft the Q4 pricing page", project: "Website", status: "Ready", picked: false, time: nil)
                issueRow("Answer the Penpot licence question", project: "Ops", status: "Ready", picked: false, time: nil)
            }
            HStack(spacing: TBDKit.s2) {
                Button("Add 2 to today") {}.buttonStyle(TBDButtonStyle(.primary))
                Button("Cancel") {}.buttonStyle(TBDButtonStyle(.quiet))
                Spacer(minLength: 0)
                Text("Done in Flow = done on Task Board, after your tap.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            }
        }
        .padding(TBDKit.s6)
        .frame(width: 720)
        .background(TBDColor.paper, in: TBDBrickShape())
        .overlay(TBDBrickShape().strokeBorder(TBDColor.lineStrong, lineWidth: TBDKit.hair))
    }

    private func issueRow(_ title: String, project: String, status: String, picked: Bool, time: String?) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: TBDKit.s3) {
                Image(systemName: picked ? "checkmark.square.fill" : "square").foregroundStyle(picked ? TBDColor.tealInk : TBDColor.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                    Text(project).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                }
                Spacer(minLength: 0)
                TBDTag(status, status: status == "In progress" ? .live : .idle)
                Text(time ?? "No time").font(TBDTokens.Typography.control).foregroundStyle(time == nil ? TBDColor.fieldPlaceholder : TBDColor.ink)
                    .frame(width: 130, alignment: .leading)
                    .padding(.horizontal, TBDKit.s3).frame(minHeight: 34)
                    .background(TBDColor.fieldFill, in: TBDBrickShape())
                    .overlay(TBDBrickShape().strokeBorder(TBDColor.fieldEdge, lineWidth: TBDKit.hair))
            }
            .padding(.vertical, TBDKit.s3)
            Rectangle().fill(TBDColor.line).frame(height: TBDKit.hair)
        }
    }

    // MARK: M4 — Plan vs actual (timeline cards with labels + correction menu)

    private let cards: [CardRow] = [
        CardRow(id: "1", time: "08:30 – 09:35", title: "TBD dev.13 release and notarization", apps: "Terminal, Xcode, GitHub", label: .on, labelText: "On plan: Release TBD dev.13", by: "by TBD (model on this Mac)"),
        CardRow(id: "2", time: "09:35 – 10:00", title: "Inbox and Portal review", apps: "Mail, Portal", label: .off, labelText: "Off plan", by: "by TBD (model on this Mac)"),
        CardRow(id: "3", time: "10:00 – 10:45", title: "Flow design notes and v1 source reading", apps: "Zed, Terminal", label: .on, labelText: "On plan: Flow mockups for Martin", by: "by rule (timebox and words)"),
        CardRow(id: "4", time: "10:45 – 11:00", title: "Coffee, away from the Mac", apps: "Idle", label: .rest, labelText: "Break", by: "by you"),
        CardRow(id: "5", time: "11:00 – 11:30", title: "News and social", apps: "Safari", label: .off, labelText: "Off plan", by: "by TBD (model on this Mac)"),
    ]

    private var planVsActual: some View {
        VStack(alignment: .leading, spacing: TBDKit.s5) {
            header("Flow", label: "Companion · Today's plan · Sunday 19 October") {
                TBDTag("From Task Board", status: .live)
            }
            tabs(selected: "Plan vs actual")
            dayStrip
                VStack(alignment: .leading, spacing: TBDKit.s2) {
                    ForEach(cards) { c in
                        HStack(alignment: .top, spacing: TBDKit.s4) {
                            Rectangle().fill(color(c.label)).frame(width: 6, height: 44).overlay(Rectangle().strokeBorder(TBDColor.lineStrong, lineWidth: 1))
                            Text(c.time).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).frame(width: 110, alignment: .leading)
                            VStack(alignment: .leading, spacing: TBDKit.s1) {
                                Text(c.title).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                                Text(c.apps).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                            }
                            Spacer(minLength: 0)
                            VStack(alignment: .trailing, spacing: TBDKit.s1) {
                                TBDTag(c.labelText, status: c.label == .on ? .live : (c.label == .off ? .needsYou : .idle))
                                Text(c.by).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                            }
                            Button("This was…") {}.buttonStyle(TBDButtonStyle(.quiet))
                        }
                        .padding(TBDKit.s3)
                        .background(TBDColor.paper, in: TBDBrickShape())
                        .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
                    }
                }
                .overlay(alignment: .bottomTrailing) { correctionMenu.offset(x: -TBDKit.s3, y: -78) }
        }
    }

    private var correctionMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("11:00 – 11:30 was").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted).padding(.horizontal, TBDKit.s3).padding(.vertical, TBDKit.s2)
            ForEach(["Flow mockups for Martin", "Reply to Eyal about the design review", "Weekly review"], id: \.self) { t in
                menuItem("On plan: \(t)", selected: false)
            }
            Rectangle().fill(TBDColor.line).frame(height: TBDKit.hair)
            menuItem("Off plan", selected: true)
            menuItem("Break", selected: false)
        }
        .padding(.vertical, TBDKit.s1)
        .frame(width: 360)
        .background(TBDColor.paper, in: TBDBrickShape())
        .overlay(TBDBrickShape().strokeBorder(TBDColor.lineStrong, lineWidth: TBDKit.hair))
        .shadow(color: TBDColor.shadowInk, radius: TBDKit.floatShadowRadius, y: TBDKit.floatShadowY)
    }

    private func menuItem(_ text: String, selected: Bool) -> some View {
        HStack(spacing: TBDKit.s2) {
            Image(systemName: "checkmark").opacity(selected ? 1 : 0).foregroundStyle(TBDColor.tealInk)
            Text(text).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TBDKit.s3).frame(minHeight: 34)
    }

    // MARK: M5 — Observer

    private var observer: some View {
        VStack(alignment: .leading, spacing: TBDKit.s5) {
            header("Flow", label: "Companion · Observer") { TBDTag("Last check 10:42 · on plan", status: .live) }
            tabs(selected: "Observer")
            HStack(alignment: .top, spacing: TBDKit.s6) {
                VStack(alignment: .leading, spacing: TBDKit.s4) {
                    card {
                        HStack {
                            VStack(alignment: .leading, spacing: TBDKit.s1) {
                                Text("Watch my screen for focus").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
                                Text("Every 15 seconds TBD checks if you work on your plan, and nudges you when you drift.")
                                    .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Toggle(isOn: .constant(true)) { EmptyView() }.toggleStyle(TBDSwitchStyle()).accessibilityLabel("Watch my screen for focus")
                        }
                    }
                    Text("How TBD looks at your screen").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted)
                    choice("Text only, on this Mac", detail: "TBD reads the text on your screen and asks the model on this Mac (llama3.2:3b). Nothing leaves your Mac.", selected: true, tag: "Recommended")
                    choice("Screenshots, on this Mac", detail: "A vision model on this Mac looks at the screenshot. Needs a 3.2 GB download (qwen2.5vl:3b).", selected: false, tag: nil)
                    choice("Cloud model", detail: "Every 15 seconds a screenshot goes to Anthropic with your key. Use this only if you accept that.", selected: false, tag: "Leaves this Mac")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: TBDKit.s4) {
                    card {
                        Text("Nudges").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted)
                        Text("How often").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                        TBDSegmented(selection: .constant("friendly"), options: [("quiet", "Quiet"), ("friendly", "Friendly"), ("feisty", "Feisty")])
                        Text("Where").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                        TBDSegmented(selection: .constant("side"), options: [("side", "Side"), ("top", "Top"), ("peek", "Peek")])
                        Button("Show a test nudge") {}.buttonStyle(TBDButtonStyle(.secondary))
                    }
                    card {
                        Text("Today").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted)
                        Text("312 checks · 3 nudges · 1 snooze").font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft)
                        Text("Screen text and screenshots are not stored. Only the verdicts are kept for today.")
                            .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: 340)
            }
        }
    }

    private func choice(_ title: String, detail: String, selected: Bool, tag: String?) -> some View {
        HStack(alignment: .top, spacing: TBDKit.s3) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle").foregroundStyle(selected ? TBDColor.tealInk : TBDColor.muted)
            VStack(alignment: .leading, spacing: TBDKit.s1) {
                HStack(spacing: TBDKit.s2) {
                    Text(title).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                    if let tag { TBDTag(tag, status: tag == "Recommended" ? .live : .needsYou) }
                }
                Text(detail).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(TBDKit.s4)
        .background(selected ? TBDColor.tealWash : TBDColor.paper, in: TBDBrickShape())
        .overlay(TBDBrickShape().strokeBorder(selected ? TBDColor.tealWashLine : TBDColor.line, lineWidth: TBDKit.hair))
    }

    // MARK: Building blocks

    private func header<T: View>(_ title: String, label: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: TBDKit.s4) {
            VStack(alignment: .leading, spacing: TBDKit.s1) {
                Text(title).font(TBDTokens.Typography.display).tracking(TBDTokens.Typography.displayTracking).foregroundStyle(TBDColor.ink)
                Text(label).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            }
            Spacer(minLength: 0)
            trailing()
        }
    }

    private func tabs(selected: String) -> some View {
        TBDSegmented(selection: .constant(selected), options: ["Today", "Plan vs actual", "Observer", "Nudge preview"].map { ($0, $0) })
    }

    private func sectionTitle(_ text: String, trailing: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
            Spacer(minLength: 0)
            Text(trailing).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: TBDKit.s3, content: content)
            .padding(TBDKit.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TBDColor.paper, in: TBDBrickShape())
            .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
    }
}

/// Renders every Flow mockup screen at the app's page size, light and dark, with the rendered contrast audit.
@MainActor func runFlowMockups() throws {
    let size = CGSize(width: 1180, height: 820)
    for screen in FlowMockScreen.allCases {
        for dark in [false, true] {
            try render(FlowMockup(screen: screen), size: size, dark: dark, to: "flow-\(screen.rawValue)-\(dark ? "dark" : "light")")
        }
    }
}
