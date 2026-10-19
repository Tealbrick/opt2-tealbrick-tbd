// WP3 shell mockups (C280 C0 + C4; C281 chat over Buzz; C282 functions unlock with what is paid in the Portal).
// Static views for Martin's review, NOT app code: nothing here is wired to TBD. Branch mockup/wp3-shell only.
// Usage: swift run tbd-design-shots --shell-mockups <outDir>  → shell-<variant>-<page>-<size>-<theme>.png + contrast audit.
// Variant "list": one side list with folding groups (Chat / Companion / Listen) + workspace.
// Variant "rail": the v1-style icon rail (aspects) + a page list for the open aspect + workspace.
import SwiftUI
import TBDDesign

enum ShellVariant: String, CaseIterable { case list, rail }
enum ShellAspect: String { case chat = "Chat", companion = "Companion", listen = "Listen" }
enum ShellPage: String, CaseIterable {
    case agent, team, timeline, flow
    var aspect: ShellAspect {
        switch self {
        case .agent, .team: return .chat
        case .timeline, .flow: return .companion
        }
    }
}

private struct NavEntry: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var page: ShellPage? = nil
    var detail: String? = nil
}

private let chatEntries = [
    NavEntry(id: "tbd", title: "TBD", symbol: "sparkles", detail: "On this Mac"),
    NavEntry(id: "henry", title: "Henry", symbol: "person.crop.circle", page: .agent, detail: "Claude Agent SDK"),
    NavEntry(id: "tempo", title: "Tempo", symbol: "person.crop.circle", detail: "Codex"),
    NavEntry(id: "nova", title: "Nova", symbol: "person.crop.circle", detail: "LangChain"),
    NavEntry(id: "launch", title: "Launch team", symbol: "person.3", page: .team, detail: "3 agents"),
]
private let companionEntries = [
    NavEntry(id: "timeline", title: "Timeline", symbol: "clock", page: .timeline),
    NavEntry(id: "daily", title: "Daily", symbol: "sun.max"),
    NavEntry(id: "weekly", title: "Weekly", symbol: "calendar"),
    NavEntry(id: "review", title: "Review", symbol: "checkmark.seal"),
    NavEntry(id: "flow", title: "Flow", symbol: "scope", page: .flow),
    NavEntry(id: "agents", title: "Agents", symbol: "person.2"),
]
private let listenEntries = [
    NavEntry(id: "transcribe", title: "Transcribe", symbol: "waveform"),
    NavEntry(id: "library", title: "Library", symbol: "books.vertical"),
    NavEntry(id: "dictations", title: "Dictations", symbol: "mic"),
    NavEntry(id: "meetings", title: "Meetings", symbol: "person.3.sequence"),
    NavEntry(id: "prompts", title: "Prompts", symbol: "text.bubble"),
    NavEntry(id: "transforms", title: "Transforms", symbol: "wand.and.stars"),
    NavEntry(id: "vocabulary", title: "Vocabulary", symbol: "character.book.closed"),
]

private func entries(_ aspect: ShellAspect) -> [NavEntry] {
    switch aspect {
    case .chat: return chatEntries
    case .companion: return companionEntries
    case .listen: return listenEntries
    }
}

struct ShellMockup: View {
    let variant: ShellVariant
    let page: ShellPage

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            switch variant {
            case .list: listSidebar.frame(width: 248)
            case .rail:
                railColumn.frame(width: TBDRailMetrics.width)
                pageColumn.frame(width: 232)
            }
            ShellWorkspace(page: page)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(TBDColor.tile, in: TBDBrickShape())
                .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
                .padding(.vertical, TBDKit.s4)
                .padding(.trailing, TBDKit.s4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TBDColor.paper)
        .font(TBDTokens.Typography.body)
    }

    // MARK: Variant "list": one list, groups fold; the open group is the current aspect.

    private var listSidebar: some View {
        VStack(alignment: .leading, spacing: TBDKit.s4) {
            brandHeader
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: TBDKit.s4) {
                    ForEach([ShellAspect.chat, .companion, .listen], id: \.self) { aspect in
                        if aspect == page.aspect {
                            TBDNavSection(aspect.rawValue) {
                                ForEach(entries(aspect)) { entry in
                                    TBDNavItem(entry.title, symbol: entry.symbol, current: entry.page == page, ringed: false) {}
                                }
                            }
                        } else {
                            foldedGroup(aspect)
                        }
                    }
                }
                .padding(.horizontal, TBDKit.s3)
            }
            Spacer(minLength: 0)
            footer.padding(.horizontal, TBDKit.s3)
        }
        .padding(.top, TBDKit.s5)
        .padding(.bottom, TBDKit.s4)
    }

    private func foldedGroup(_ aspect: ShellAspect) -> some View {
        HStack(spacing: TBDKit.s2) {
            Image(systemName: "chevron.right").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            Text(aspect.rawValue).font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted)
            Spacer(minLength: 0)
            Text("\(entries(aspect).count)").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        }
        .padding(.horizontal, TBDKit.s3)
    }

    // MARK: Variant "rail": aspects as icons, pages in a second column.

    private var railColumn: some View {
        VStack(spacing: TBDRailMetrics.gap) {
            brandMark.padding(.bottom, TBDKit.s2)
            TBDRailRow("Chat", symbol: "bubble.left.and.bubble.right", selected: page.aspect == .chat, badge: true) {}
            TBDRailRow("Companion", symbol: "clock", selected: page.aspect == .companion) {}
            TBDRailRow("Listen", symbol: "waveform", selected: page.aspect == .listen) {}
            Spacer(minLength: 0)
            TBDRailRow("Settings", symbol: "gearshape", selected: false) {}
            TBDAgentAvatar(name: "Brickie", size: 32).padding(.bottom, TBDKit.s2)
        }
        .padding(.top, TBDRailMetrics.topInset)
        .frame(maxHeight: .infinity)
    }

    private var pageColumn: some View {
        VStack(alignment: .leading, spacing: TBDKit.s4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(page.aspect.rawValue).font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
                Text("Martin's workspace").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            }
            .padding(.horizontal, TBDKit.s3)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(entries(page.aspect)) { entry in
                    if page.aspect == .chat {
                        chatRow(entry)
                    } else {
                        TBDNavItem(entry.title, symbol: entry.symbol, current: entry.page == page, ringed: false) {}
                    }
                }
            }
            if page.aspect == .chat {
                Button("New team") {}.buttonStyle(TBDButtonStyle(.quiet)).padding(.horizontal, TBDKit.s2)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, TBDKit.s5)
        .padding(.horizontal, TBDKit.s2)
    }

    private func chatRow(_ entry: NavEntry) -> some View {
        let current = entry.page == page
        return HStack(spacing: TBDKit.s2) {
            TBDAgentAvatar(name: entry.title, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.title).font(TBDTokens.Typography.control).foregroundStyle(current ? TBDColor.tabCurrentOn : TBDColor.ink)
                if let detail = entry.detail {
                    Text(detail).font(TBDTokens.Typography.hint).foregroundStyle(current ? TBDColor.tabCurrentOn : TBDColor.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TBDKit.s3)
        .padding(.vertical, TBDKit.s2)
        .background(current ? TBDColor.tabCurrentFill : Color.clear, in: TBDBrickShape())
    }

    // MARK: Shared parts

    /// The app mark: one brick (TBDBrickEmblem needs the host app's wall images, which this renderer does not have).
    private var brandMark: some View {
        TBDBrickShape().fill(TBDColor.brick).frame(width: 30, height: 18)
    }

    private var brandHeader: some View {
        HStack(spacing: TBDKit.s2) {
            brandMark
            VStack(alignment: .leading, spacing: 0) {
                Text("TBD").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
                Text("Martin's workspace").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        }
        .padding(.horizontal, TBDKit.s5)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: TBDKit.s2) {
            TBDNavItem("Settings", symbol: "gearshape", current: false, ringed: false) {}
            HStack(spacing: TBDKit.s2) {
                TBDAgentAvatar(name: "Brickie", size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Brickie").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                    Text("Tracking today").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                }
                Spacer(minLength: 0)
                TBDTag("Live", status: .live)
            }
            .padding(.horizontal, TBDKit.s3)
        }
    }
}

// MARK: - Workspace pages

private struct ShellWorkspace: View {
    let page: ShellPage

    var body: some View {
        VStack(alignment: .leading, spacing: TBDKit.s5) {
            switch page {
            case .agent: agentChat
            case .team: teamChat
            case .timeline: timeline
            case .flow: flow
            }
        }
        .padding(TBDKit.s6)
    }

    private var agentChat: some View {
        VStack(alignment: .leading, spacing: TBDKit.s4) {
            header("Henry", label: "Agent · Claude Agent SDK · via Connect (Buzz)") { TBDTag("Online", status: .live) }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: TBDKit.s3) {
                    bubble("Please book two tickets for Thursday's workshop and send the confirmation to Eyal.", mine: true)
                    bubble("Booked: 2 tickets, Thursday 10:00. I drafted the email to Eyal.", from: "Henry")
                    holdCard(
                        title: "Henry wants to send an email to a new contact",
                        detail: "eyal@example.com · first contact · \"Your workshop tickets\"")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            composer("Message Henry")
        }
    }

    private var teamChat: some View {
        VStack(alignment: .leading, spacing: TBDKit.s4) {
            header("Launch team", label: "Team · Henry, Tempo, Nova · via Connect (Buzz)") {
                HStack(spacing: -6) {
                    ForEach(["Henry", "Tempo", "Nova"], id: \.self) { TBDAgentAvatar(name: $0, size: 26) }
                }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: TBDKit.s3) {
                    bubble("@everyone the landing page goes live Friday. What is still open?", mine: true)
                    bubble("Copy is final. The pricing table waits for the new offer ids.", from: "Nova")
                    bubble("I can generate the offer ids today. They need your approval in Rules.", from: "Tempo")
                    bubble("Social posts are scheduled for Friday 09:00.", from: "Henry")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            composer("Message the team")
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: TBDKit.s4) {
            header("Today", label: "Companion · Timeline") {
                HStack(spacing: TBDKit.s2) {
                    Button("Previous day") {}.buttonStyle(TBDButtonStyle(.secondary))
                    Button("Today") {}.buttonStyle(TBDButtonStyle(.quiet))
                }
            }
            ForEach(timelineCards, id: \.0) { card in
                HStack(alignment: .top, spacing: TBDKit.s4) {
                    Text(card.0).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).frame(width: 96, alignment: .leading)
                    VStack(alignment: .leading, spacing: TBDKit.s1) {
                        Text(card.1).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                        Text(card.2).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                    }
                    Spacer(minLength: 0)
                    TBDTag(card.3, status: card.3 == "On plan" ? .live : .idle)
                }
                .padding(TBDKit.s4)
                .background(TBDColor.paper, in: TBDBrickShape())
                .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
            }
            Spacer(minLength: 0)
        }
    }

    private let timelineCards = [
        ("09:00 – 09:40", "Inbox and Portal review", "Mail, Portal · 40 min", "Off plan"),
        ("09:40 – 11:10", "TBD Settings fix and release", "Xcode, Terminal, GitHub · 1 h 30 min", "On plan"),
        ("11:10 – 11:35", "Call with Eyal: design review", "Zoom, Penpot · 25 min", "On plan"),
        ("11:35 – 12:05", "News and social", "Safari · 30 min", "Off plan"),
    ]

    private var flow: some View {
        VStack(alignment: .leading, spacing: TBDKit.s4) {
            header("Flow", label: "Companion · Today's plan") { TBDTag("Tracking", status: .live) }
            TBDNotice("Your task list comes from Task Board. Available with Task Board — until then TBD keeps a local list.", tone: .neutral)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(flowTasks, id: \.0) { task in
                    HStack(spacing: TBDKit.s3) {
                        Image(systemName: task.2 ? "checkmark.circle.fill" : (task.3 ? "record.circle" : "circle"))
                            .foregroundStyle(task.3 ? TBDColor.tealInk : TBDColor.muted)
                        Text(task.0).font(TBDTokens.Typography.control).foregroundStyle(task.2 ? TBDColor.muted : TBDColor.ink)
                        Spacer(minLength: 0)
                        Text(task.1).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                    }
                    .padding(.vertical, TBDKit.s3)
                    .padding(.horizontal, TBDKit.s4)
                    .background(task.3 ? TBDColor.tealWash : Color.clear, in: TBDBrickShape())
                    Rectangle().fill(TBDColor.line).frame(height: TBDKit.hair)
                }
            }
            HStack(spacing: TBDKit.s2) {
                Button("Add a task") {}.buttonStyle(TBDButtonStyle(.secondary))
                Button("Open Task Board") {}.buttonStyle(TBDButtonStyle(.quiet)).disabled(true)
            }
            Spacer(minLength: 0)
        }
    }

    private let flowTasks = [
        ("Release TBD dev.6", "done · 1 h 30 min", true, false),
        ("Shell mockups for Martin", "now · 42 min", false, true),
        ("Reply to Eyal about the design review", "planned · 15 min", false, false),
        ("Weekly review", "planned · 30 min", false, false),
    ]

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

    private func bubble(_ text: String, mine: Bool = false, from: String? = nil) -> some View {
        HStack(alignment: .top, spacing: TBDKit.s2) {
            if mine { Spacer(minLength: 120) } else { TBDAgentAvatar(name: from ?? "", size: 28) }
            VStack(alignment: .leading, spacing: TBDKit.s1) {
                if let from { Text(from).font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted) }
                Text(text).font(TBDTokens.Typography.body).foregroundStyle(TBDColor.ink).fixedSize(horizontal: false, vertical: true)
            }
            .padding(TBDKit.s3)
            .background(mine ? TBDColor.tealWash : TBDColor.paper, in: TBDBrickShape())
            .overlay(TBDBrickShape().strokeBorder(mine ? TBDColor.tealWashLine : TBDColor.line, lineWidth: TBDKit.hair))
            .frame(maxWidth: 560, alignment: mine ? .trailing : .leading)
            if !mine { Spacer(minLength: 120) }
        }
    }

    /// C13 reply suite on a hold; "Always allow" needs Rules (C277 A2, C282).
    private func holdCard(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: TBDKit.s3) {
            HStack(spacing: TBDKit.s2) {
                TBDTag("Needs you", status: .needsYou)
                Text(title).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
            }
            Text(detail).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            HStack(spacing: TBDKit.s2) {
                Button("Approve") {}.buttonStyle(TBDButtonStyle(.primary))
                Button("Deny") {}.buttonStyle(TBDButtonStyle(.secondary))
                Button("Never allow") {}.buttonStyle(TBDButtonStyle(.secondary))
                Button("Always allow") {}.buttonStyle(TBDButtonStyle(.secondary)).disabled(true)
                Text("Always allow: available with Rules & Approvals").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            }
        }
        .padding(TBDKit.s4)
        .frame(maxWidth: 720, alignment: .leading)
        .background(TBDColor.paper, in: TBDBrickShape())
        .overlay(TBDBrickShape().strokeBorder(TBDColor.lineStrong, lineWidth: TBDKit.hair))
    }

    private func composer(_ placeholder: String) -> some View {
        HStack(spacing: TBDKit.s3) {
            Image(systemName: "paperclip").foregroundStyle(TBDColor.muted)
            Text(placeholder).font(TBDTokens.Typography.body).foregroundStyle(TBDColor.fieldPlaceholder)
            Spacer(minLength: 0)
            Image(systemName: "mic").foregroundStyle(TBDColor.muted)
            Button("Send") {}.buttonStyle(TBDButtonStyle(.primary))
        }
        .padding(.horizontal, TBDKit.s4)
        .padding(.vertical, TBDKit.s2)
        .background(TBDColor.fieldFill, in: TBDBrickShape())
        .overlay(TBDBrickShape().strokeBorder(TBDColor.fieldEdge, lineWidth: TBDKit.hair))
    }
}

/// Renders every variant × page × size × theme (light and dark), with the rendered contrast audit.
@MainActor func runShellMockups() throws {
    let sizes: [(String, CGSize)] = [("1280", CGSize(width: 1280, height: 800)), ("1600", CGSize(width: 1600, height: 1000))]
    let pages: [ShellVariant: [ShellPage]] = [.list: [.agent, .team, .timeline, .flow], .rail: [.agent, .timeline]]
    for variant in ShellVariant.allCases {
        for page in pages[variant] ?? [] {
            for (sizeName, size) in sizes {
                for dark in [false, true] {
                    try render(ShellMockup(variant: variant, page: page), size: size, dark: dark,
                               to: "shell-\(variant.rawValue)-\(page.rawValue)-\(sizeName)-\(dark ? "dark" : "light")")
                }
            }
        }
    }
}
