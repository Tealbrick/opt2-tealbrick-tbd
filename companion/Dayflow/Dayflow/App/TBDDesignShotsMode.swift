//
//  TBDDesignShotsMode.swift
//  TBD Dev only (DEBUG): `--design-shots <outDir>` renders companion screens to PNG and quits.
//
//  Usage (Debug build, bundle id com.tealbrick.desktop.dev):
//    "<TBD Dev build>/TBD.app/Contents/MacOS/TBD" --design-shots <outDir>
//  Writes <outDir>/tbd-companion-<screen>-<light|dark>.png (2x) and <outDir>/tbd-companion-contrast.json, then exits
//  (0 = no contrast failures, 1 = contrast failures, 2 = refused / bad arguments).
//
//  Runs from DayflowApp.init, before any scene or the AppDelegate starts: no capture, no hotkeys, no login item, no
//  updater, no sign-in, no Chat helper (TBDChatRuntime refuses to start), no notifications. Data: a fresh demo root
//  ~/Library/Application Support/<dataFolder>-dev-shots (TBDIdentity.dataFolder), seeded with neutral demo cards and deleted at the
//  end. Refuses unless the process is the dev identity, so it can never open the live TBD data.
//
//  The offscreen render and the rendered contrast audit follow native/Sources/TBDDesignShots/main.swift (same method,
//  same thresholds; the audit code is copied because that file is an executable target).
//

#if DEBUG
  import AppKit
  import SwiftUI
  import TBDDesign
  import TBDListening
  import TBDModels

  enum TBDDesignShots {
    static let flag = "--design-shots"
    static var isRequested: Bool { CommandLine.arguments.contains(flag) }

    @MainActor
    static func run() -> Never {
      let args = CommandLine.arguments
      guard TBDIdentity.isDev, TBDIdentity.isDesignShots else {
        fail(2, "design shots run only in the TBD Dev build (DEBUG, \(TBDIdentity.devBundleID))")
      }
      guard let index = args.firstIndex(of: flag), index + 1 < args.count, !args[index + 1].hasPrefix("-") else {
        fail(2, "usage: TBD \(flag) <outDir>")
      }
      let outDir = URL(fileURLWithPath: args[index + 1], isDirectory: true)
      do {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let roots = try prepareDemoRoots()
        var runner = Runner(outDir: outDir)
        let failures = try runner.renderAll()
        for root in roots { try? FileManager.default.removeItem(at: root) }
        exit(failures == 0 ? 0 : 1)
      } catch {
        fail(1, "\(error)")
      }
    }

    private static func fail(_ code: Int32, _ message: String) -> Never {
      FileHandle.standardError.write(Data("tbd design shots: \(message)\n".utf8))
      exit(code)
    }

    /// A fresh demo data root for this run only (Application Support/com.tealbrick.desktop-dev-shots).
    private static func prepareDemoRoots() throws -> [URL] {
      let fm = FileManager.default
      let roots = [TBDIdentity.applicationSupport()]
      for root in roots {
        // Belt and braces: only ever delete the shots roots.
        guard root.lastPathComponent.hasSuffix("-dev-shots") else {
          fail(2, "refusing to use \(root.path) (not a -dev-shots root)")
        }
        try? fm.removeItem(at: root)
      }
      let support = roots[0]
      try fm.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      // Listening reads its root from TBD_LISTENING_ROOT (TBDListeningPaths.rootEnvironmentKey); its preview API refuses
      // without it. Set before anything touches Listening.
      setenv("TBD_LISTENING_ROOT", support.appendingPathComponent("Listening", isDirectory: true).path, 1)
      // Highest-priority, never-persisted defaults for this process: onboarded, capture off, no goal prompt.
      let defaults = UserDefaults.standard
      var argument = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
      argument["didOnboard"] = true
      argument["isRecording"] = false
      argument[DayGoalPreferences.showDailyGoalPopupsKey] = false
      argument["tbd.portalInvitationDismissed"] = true
      defaults.setVolatileDomain(argument, forName: UserDefaults.argumentDomain)
      return roots
    }
  }

  // MARK: - Screens

  @MainActor
  private struct Runner {
    let outDir: URL
    let prefix = "tbd-companion"
    var results: [ScreenResult] = []
    var failures: [ContrastFailure] = []
    /// Offscreen windows stay alive until the process exits (tearing hosted views down mid-run is not needed).
    var retained: [NSWindow] = []

    init(outDir: URL) { self.outDir = outDir }

    mutating func renderAll() throws -> Int {
      TBDFonts.register()
      NSApplication.shared.setActivationPolicy(.prohibited)
      let seeded = DemoSeed.seed()
      // Flow: a sandbox in the temp folder holds every store, suite and source of the Flow shots.
      let sandbox = FlowShotsSandbox()
      defer { sandbox.cleanUp() }
      let flow = FlowShotsSeed.planner(sandbox)
      let flowBoard = FlowShotsSeed.taskBoardPlanner(sandbox)
      let flowDay = FlowShotsSeed.planVsActualPlanner(sandbox)
      let flowDayModel = FlowDayModel(planner: flowDay, modelSource: { "by TBD (model on this Mac)" })
      let observerShots = FlowShotsSeed.observerScreens(sandbox)
      defer { observerShots.cleanUp() }
      // The tabs that are not the Observer tab get an observer on the sandbox too (never the shared one).
      let quiet = observerShots.screens[0]
      guard sandbox.isContained() else {
        throw NSError(
          domain: "TBDDesignShots", code: 2,
          userInfo: [NSLocalizedDescriptionKey: "the Flow shots would leave the temp folder (\(sandbox.root.path))"])
      }
      // Creates the Listening context on the demo root (no start: no capture, hotkeys, downloads), so Settings → Listen
      // pages render their real content.
      _ = TBDListeningRuntime.shared.previewSettings(section: "capture")

      // Agents (WP-WALL): seeded rosters, frozen wall, no helper call.
      let wall = AgentWallShotsSeed.stores()
      // Connectors (C11): seeded states, frozen stores, no helper call and no Portal.
      let connectors = ConnectorsShotsSeed.states()

      let main = CGSize(width: 1280, height: 800)
      let wide = CGSize(width: 1600, height: 1000)
      let settingsTabs = TBDSettingsRoute.sections
      for dark in [false, true] {
        let theme = dark ? "dark" : "light"
        try render(MainView(), size: main, dark: dark, name: "timeline-\(theme)")
        try render(MainView(), size: main, dark: dark, name: "daily-\(theme)") {
          NotificationCenter.default.post(name: .navigateToDaily, object: nil)
        }
        try render(MainView(), size: main, dark: dark, name: "weekly-\(theme)") {
          NotificationCenter.default.post(name: .navigateToWeekly, object: nil)
        }
        if seeded {
          try render(
            TimelineReviewOverlay(isPresented: .constant(true), selectedDate: timelineDisplayDate(from: Date())),
            size: main, dark: dark, name: "timeline-review-\(theme)")
        }
        for tab in settingsTabs {
          // Connectors: the seeded "accounts" state (mixed access and remembered choices), never the live store.
          let seeded = tab == "connectors" ? connectors.first : nil
          try render(
            SettingsView(initialSection: tab, connectors: seeded?.1, connectorsPortal: ConnectorsShotsSeed.portal).padding(15),
            size: main, dark: dark, name: "settings-\(tab)-\(theme)")
          // A larger window too: Settings must use the width it is given (TBD-UX-01).
          try render(
            SettingsView(initialSection: tab, connectors: seeded?.1, connectorsPortal: ConnectorsShotsSeed.portal).padding(15),
            size: wide, dark: dark, name: "settings-\(tab)-1600-\(theme)")
        }
        // Connectors: the other states (empty, Read only, locked, install, not connected, no grant, failed).
        for (name, store) in connectors.dropFirst() {
          try render(
            SettingsView(initialSection: "connectors", connectors: store, connectorsPortal: ConnectorsShotsSeed.portal).padding(15),
            size: main, dark: dark, name: "connectors-\(name)-\(theme)")
        }
        try render(TBDCompanionSetup(), size: main, dark: dark, name: "setup-\(theme)")
        // WP-ONB: the built first-launch flow, every step and the summary in two states (C286 mockups).
        for (name, flow) in OnboardingShots.screens() {
          try render(TBDOnboardingView(flow: flow), size: main, dark: dark, name: "onboarding-\(name)-\(theme)")
        }
        // The summary scrolls at 800 pt with eight lines; the larger window shows every line (paid-app line, WP1b).
        for (name, flow) in OnboardingShots.screens() where name.hasPrefix("5-summary") {
          try render(TBDOnboardingView(flow: flow), size: wide, dark: dark, name: "onboarding-\(name)-1600-\(theme)")
        }
        try render(StatusMenuView(dismissMenu: {}), size: CGSize(width: 320, height: 640), dark: dark, name: "menu-\(theme)")
        // Flow (F2): the local Today page on a seeded store, the observer placeholder and the nudge preview.
        for (tab, name) in [(FlowTab.today, "today"), (.nudge, "nudge")] {
          try render(
            FlowView(planner: flow, tab: tab, showsTasklistImport: true, observer: quiet.agent, observerModel: quiet.model).background(TBDColor.tile), size: main, dark: dark,
            name: "flow-\(name)-\(theme)")
        }
        // Flow (F4): Today with Task Board as the source ("Looks done" row, source labels), and the Add from Task Board sheet.
        try render(
          FlowView(planner: flowBoard, tab: .today, showsTasklistImport: false, observer: quiet.agent, observerModel: quiet.model).background(TBDColor.tile), size: main, dark: dark,
          name: "flow-today-taskboard-\(theme)")
        try render(
          FlowTaskBoardSheet(
            planner: flowBoard, picked: ["iss_weekly", "iss_q4"], times: ["iss_weekly": "16:00 – 16:30"], onDone: { _ in }
          )
          .padding(TBDKit.s8).background(TBDColor.tile),
          size: CGSize(width: 900, height: 560), dark: dark, name: "flow-add-from-taskboard-\(theme)")
        // Flow (F5): Today with the strip, the minutes on each row and the Off plan card; and the Plan vs actual tab (cards,
        // labels, where each label came from). The "This was…" menus are system menus: they are covered by unit tests.
        try render(
          FlowView(
            planner: flowDay, tab: .today, showsTasklistImport: false, observer: quiet.agent, observerModel: quiet.model,
            dayModel: flowDayModel).background(TBDColor.tile),
          size: main, dark: dark, name: "flow-today-planvsactual-\(theme)")
        try render(
          FlowView(
            planner: flowDay, tab: .planVsActual, showsTasklistImport: false, observer: quiet.agent, observerModel: quiet.model,
            dayModel: flowDayModel).background(TBDColor.tile),
          size: CGSize(width: 1280, height: 900), dark: dark, name: "flow-plan-vs-actual-\(theme)")
        // The Observer tab (F3): text on this Mac (the mockup), a local vision model that is not downloaded yet, a cloud model.
        for screen in observerShots.screens {
          try render(
            FlowView(planner: flow, tab: .observer, showsTasklistImport: true, observer: screen.agent, observerModel: screen.model)
              .background(TBDColor.tile),
            size: main, dark: dark, name: "flow-observer\(screen.suffix)-\(theme)")
        }
        // Agents (WP-WALL): the restored roster wall, the signed-in wall with only TBD, and the signed-out wall; two window sizes.
        for (name, store) in wall {
          for (size, suffix) in [(main, ""), (wide, "-1600")] {
            try render(
              AgentWallView(store: store, frozen: true).background(TBDColor.tile), size: size, dark: dark,
              name: "agents-\(name)\(suffix)-\(theme)")
          }
        }
        // The debug card open (its Overlay tab), so its controls are in the contrast audit too.
        try render(
          ScrollView { FlowDemoView(showsDebugOpen: true).padding(TBDKit.s8) }.background(TBDColor.tile), size: CGSize(width: 1280, height: 1100),
          dark: dark, name: "flow-nudge-debug-\(theme)")
      }

      let report = try JSONEncoder.shotsPretty.encode(ShotsReport(screens: results, failures: failures))
      try report.write(to: outDir.appendingPathComponent("\(prefix)-contrast.json"))
      let boxes = results.reduce(0) { $0 + $1.textBoxes }
      let unclassified = results.reduce(0) { $0 + $1.unclassified }
      print("tbd design shots: \(results.count) screens, \(boxes) text boxes (\(unclassified) unclassified), \(failures.count) contrast failures")
      for f in failures.prefix(40) {
        print("  FAIL \(f.screen) (\(f.x),\(f.y) \(f.w)x\(f.h)) \(f.ink) on \(f.ground) = \(f.ratio) < \(f.need)")
      }
      return failures.count
    }

    /// The app's own environment for a companion screen (see DayflowApp / AppRootView).
    private func chrome<V: View>(_ view: V, dark: Bool, size: CGSize) -> some View {
      view
        .environmentObject(AppState.shared)
        .environmentObject(CategoryStore.shared)
        .frame(width: size.width, height: size.height)
        .background(TBDColor.paper)
        .environment(\.colorScheme, dark ? .dark : .light)
        .resolveDayflowTheme()
        .resolveStylePreview()
    }

    private mutating func render<V: View>(
      _ view: V, size: CGSize, dark: Bool, name: String, prepare: (() -> Void)? = nil
    ) throws {
      let rep = try bitmap(chrome(view, dark: dark, size: size), size: size, dark: dark, prepare: prepare)
      guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
      let url = outDir.appendingPathComponent("\(prefix)-\(name).png")
      try png.write(to: url)
      print(url.path)
      let redacted = try bitmap(
        chrome(view, dark: dark, size: size).redacted(reason: .placeholder), size: size, dark: dark, prepare: prepare)
      let (count, fails, unclassified) = ContrastAudit.audit(rep, redacted, dark: dark, screen: name)
      results.append(ScreenResult(screen: name, textBoxes: count, failures: fails.count, unclassified: unclassified))
      failures += fails
    }

    private mutating func bitmap<V: View>(_ view: V, size: CGSize, dark: Bool, prepare: (() -> Void)?) throws
      -> NSBitmapImageRep
    {
      let host = NSHostingView(rootView: view)
      host.frame = CGRect(origin: .zero, size: size)
      let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      window.contentView = host
      host.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(1.2))  // entrance animations, async loads
      if let prepare {
        prepare()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
      }
      host.layoutSubtreeIfNeeded()
      guard
        let rep = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
      else { throw CocoaError(.fileWriteUnknown) }
      rep.size = size
      NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        host.cacheDisplay(in: host.bounds, to: rep)
      }
      // Detach the hosted view so its timers and observers stop before the next screen.
      window.contentView = nil
      retained.append(window)
      return rep
    }
  }

  // MARK: - Agents wall shots

  /// The rosters of the Agents shots, in the shape the helper answers `listAgents`. Seeded and frozen: the stores never ask
  /// the helper, and the names are made up.
  @MainActor
  enum AgentWallShotsSeed {
    static let rows: [[String: Any]] = [
      ["id": "tbd-default", "name": "TBD", "runtime": "tbd-default"],
      ["id": "a1", "name": "Henry", "runtime": "workspace", "workspace": ["purpose": "Triage and drafts", "state": "online", "harness": "Claude Agent SDK"]],
      ["id": "a2", "name": "Tempo", "runtime": "workspace", "workspace": ["purpose": "Plan and reminders", "state": "paused", "harness": "Codex"]],
      ["id": "a3", "name": "Nova", "runtime": "workspace", "workspace": ["purpose": "Research", "state": "online", "harness": "LangChain"]],
      ["id": "a4", "name": "Scribe", "runtime": "workspace", "workspace": ["purpose": "Meeting notes", "state": "offline", "harness": "Claude Agent SDK"]],
      ["id": "a5", "name": "Atlas", "runtime": "workspace", "workspace": ["purpose": "Code review", "state": "online", "harness": "Codex"]],
    ]

    static func stores() -> [(String, AgentWallRosterStore)] {
      func store(_ roster: AgentWallRoster, signedIn: Bool) -> AgentWallRosterStore {
        let store = AgentWallRosterStore(client: SeededClient(), signedIn: { signedIn }, isAppActive: { false })
        store.seed(roster, signedIn: signedIn)
        return store
      }
      return [
        ("restored", store(.decode(rows), signedIn: true)),
        ("empty", store(.decode(Array(rows.prefix(1))), signedIn: true)),
        ("signed-out", store(.ownOnly, signedIn: false)),
      ]
    }

    /// Never asked: a frozen store makes no call. If it were, the shots would show it as a failure.
    private struct SeededClient: AgentWallRosterClient {
      func listAgents() async throws -> Any { throw CocoaError(.userCancelled) }
    }
  }

  // MARK: - Connectors shots

  /// The states of the Connectors shots. Seeded and frozen: the stores never ask the helper, and every name is made up.
  @MainActor
  enum ConnectorsShotsSeed {
    /// A Portal address and workspace that exist only here, so the link buttons are enabled in the shots.
    static let portal = ConnectorsPortal(issuer: { "https://portal.example" }, workspace: { "ws_demo" })

    static let mixed: [TBDConnectorAccount] = [
      TBDConnectorAccount(id: "a1", label: "Work inbox", service: "gmail", kind: .asMe, access: .readUpdate),
      TBDConnectorAccount(id: "a2", label: "Team calendar", service: "googlecalendar", kind: .asMe, access: .read),
      TBDConnectorAccount(id: "a3", label: "Studio Slack", service: "slack", kind: .asItself, access: .readUpdateDelete),
      TBDConnectorAccount(id: "a4", label: "Company GitHub", service: "github", kind: .asItself, access: .read),
    ]
    static let choices: [TBDConnectorChoice] = [
      TBDConnectorChoice(account: "work inbox", tool: "gmail_send_email", decision: .always),
      TBDConnectorChoice(account: "studio slack", tool: "slack_delete_message", decision: .never),
      TBDConnectorChoice(account: "(default account)", tool: "googlecalendar_create_event", decision: .always),
    ]

    /// The first entry is the pane as the Settings shots show it; the others are the extra states.
    static func states() -> [(String, ConnectorsStore)] {
      func store(_ state: ConnectorsState) -> ConnectorsStore {
        let store = ConnectorsStore(client: SeededClient(), account: { AgentWallAccountKey(signedIn: true) }, isAppActive: { false })
        store.seed(state)
        return store
      }
      let active = ConnectorsState(gate: .active, accounts: mixed, choices: choices, loaded: true)
      return [
        ("accounts", store(active)),
        ("empty", store(ConnectorsState(gate: .active, loaded: true))),
        ("readonly", store(ConnectorsState(gate: .active, accounts: mixed.filter { $0.access == .read }, loaded: true))),
        ("locked", store(ConnectorsState(gate: .locked, loaded: true))),
        ("install", store(ConnectorsState(gate: .install, loaded: true))),
        ("notconnected", store(ConnectorsState(gate: .notConnected, loaded: true))),
        // The remembered choices are local: they list although TBD's agent is not connected (N4).
        ("notconnected-choices", store(ConnectorsState(gate: .notConnected, choices: choices, loaded: true))),
        ("choices-unreadable", store(ConnectorsState(gate: .active, accounts: mixed, choicesIssue: .unreadable, loaded: true))),
        ("choices-failed", store(ConnectorsState(gate: .active, accounts: mixed, choices: choices, choicesIssue: .failed, loaded: true))),
        ("nogrant", store(ConnectorsState(gate: .noGrant("TBD's agent has no Connect access. In Portal, open your workspace, draw a line from TBD's agent to Connect, choose Read, then press Connect. Then open Connect and share an account with TBD's agent."), loaded: true))),
        ("failed", store(ConnectorsState(gate: .active, accounts: mixed, choices: choices, notice: "Connect did not answer in time. Try again.", loaded: true))),
      ]
    }

    /// Never asked: a frozen store makes no call.
    private struct SeededClient: ConnectorsClient {
      func access() async -> TBDAppAccess { .unknown }
      func agentConnection() async -> ConnectorsAgent { ConnectorsAgent(connected: false, workspace: nil) }
      func accounts() async throws -> TBDConnectorAccounts { throw CocoaError(.userCancelled) }
      func choices() async throws -> TBDConnectorChoices { throw CocoaError(.userCancelled) }
      func revoke(account: String, tool: String) async throws -> TBDConnectorChoices { throw CocoaError(.userCancelled) }
    }
  }

  // MARK: - Flow shots sandbox

  /// Everything the Flow shots touch lives here: a unique folder in the system temp folder (never the app-support folder,
  /// never the real Flow list), its own UserDefaults suite, an isolated session mirror and timeline, and Task Board sources
  /// that are seeded and frozen (they never ask the helper). `FlowShotsSandboxTests` proves the paths stay under the temp
  /// folder. `cleanUp()` removes what the sandbox made.
  @MainActor
  final class FlowShotsSandbox {
    let root: URL
    let defaults: UserDefaults
    private let suiteName: String
    private(set) var handedOutURLs: [URL] = []

    init(temporary: URL = FileManager.default.temporaryDirectory) {
      root = temporary.appendingPathComponent("tbd-flow-shots-\(UUID().uuidString)", isDirectory: true)
      try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      suiteName = "tbd.design-shots.flow.\(UUID().uuidString)"
      defaults = UserDefaults(suiteName: suiteName) ?? UserDefaults()
    }

    /// `<root>/<name>/flow.json` for one planner.
    func storeURL(_ name: String) -> URL {
      let url = root.appendingPathComponent(name, isDirectory: true).appendingPathComponent("flow.json")
      handedOutURLs.append(url)
      return url
    }

    /// A Task Board source that shows `mode` and `issues` and never asks the helper.
    func taskBoard(mode: TBDFlowSourceMode, issues: [TBDFlowTaskBoardIssue] = []) -> FlowTaskBoardSource {
      let source = FlowTaskBoardSource()
      source.seed(mode: mode, issues: issues)
      return source
    }

    func settings() -> FlowAgentSettings { FlowAgentSettings(defaults: defaults) }

    func timeline() -> FlowSessionTimeline {
      let url = root.appendingPathComponent("flow-session-timeline.json")
      handedOutURLs.append(url)
      return FlowSessionTimeline(fileURL: url)
    }

    /// A mirror with its own defaults, settings and timeline, and no observer.
    func mirror(now: @escaping () -> Date = { Date() }) -> FlowSessionMirror {
      FlowSessionMirror(defaults: defaults, settings: settings(), timeline: timeline(), observer: FlowNoObserver(), now: now)
    }

    /// A planner that touches nothing outside the sandbox: its own store, mirror, defaults, Task Board source and cards.
    func planner(
      store: TBDFlowStore, now: @escaping () -> Date, taskBoard: FlowTaskBoardSource, cards: [TimelineCard] = []
    ) -> FlowPlanner {
      FlowPlanner(
        store: store, mirror: mirror(now: now), defaults: defaults, now: now, playSound: {}, taskBoard: taskBoard,
        cardsForDay: { _ in cards })
    }

    /// Every URL the sandbox handed out is inside `root`, and `root` is inside the system temp folder and not inside the
    /// app-support folder. The shots check this before they run.
    func isContained(temporary: URL = FileManager.default.temporaryDirectory) -> Bool {
      Self.contains(
        root: root, urls: handedOutURLs, temporary: temporary,
        support: TBDIdentity.applicationSupport().deletingLastPathComponent())
    }

    /// The containment rule on plain paths (the test drives it with made-up folders).
    nonisolated static func contains(root: URL, urls: [URL], temporary: URL, support: URL) -> Bool {
      let temp = temporary.standardizedFileURL.path
      let supportPath = support.standardizedFileURL.path
      let rootPath = root.standardizedFileURL.path
      guard rootPath.hasPrefix(temp + "/"), !rootPath.hasPrefix(supportPath + "/"), !temp.hasPrefix(supportPath + "/"), temp != supportPath
      else { return false }
      return urls.allSatisfy { $0.standardizedFileURL.path.hasPrefix(rootPath + "/") }
    }

    func cleanUp() {
      defaults.removePersistentDomain(forName: suiteName)
      guard root.lastPathComponent.hasPrefix("tbd-flow-shots-") else { return }
      try? FileManager.default.removeItem(at: root)  // the sandbox's own folder
    }
  }

  // MARK: - Flow demo data

  /// A planner on a seeded store inside the shots root (deleted at the end): four tasks like the approved mockup, one
  /// done, one "Now" with a running focus timer. The clock stands still at 10:18, so the page is the same on every run.
  @MainActor
  enum FlowShotsSeed {
    struct ObserverScreen {
      let suffix: String
      let agent: FlowDistractionAgent
      let model: FlowObserverModel
    }
    /// The Observer tab in three states (text on this Mac like the mockup, a vision model not downloaded yet, a cloud
    /// model), each on its own defaults suite and an in-memory key store, with a fixed model list: no network, no Keychain,
    /// no real settings.
    struct ObserverScreens {
      let screens: [ObserverScreen]
      let suiteNames: [String]
      func cleanUp() { suiteNames.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) } }
    }

    static func observerScreens(_ sandbox: FlowShotsSandbox) -> ObserverScreens {
      var suites: [String] = []
      func screen(_ suffix: String, _ prepare: (TBDFlowObserverSetup, TBDModelRegistry) throws -> Void) -> ObserverScreen {
        let name = "tbd.design-shots.flow-observer.\(UUID().uuidString)"
        suites.append(name)
        let defaults = UserDefaults(suiteName: name) ?? .standard
        let registry = TBDModelRegistry(defaults: defaults, credentials: TBDMemorySecretStore())
        let setup = TBDFlowObserverSetup(registry: registry, defaults: defaults)
        do { try prepare(setup, registry) } catch { print("tbd design shots: observer seed failed: \(error)") }
        setup.watching = true
        let agent = FlowDistractionAgent(
          setup: setup, source: FlowShotsNoScreen(), settings: sandbox.settings(), timeline: sandbox.timeline(),
          mirror: sandbox.mirror(), defaults: defaults, schedulesTimer: false, tempRoot: sandbox.root)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let at1042 = calendar.date(bySettingHour: 10, minute: 42, second: 0, of: today) ?? today
        var counters = FlowObserverCounters(day: TBDFlowDay.string(from: Date(), calendar: calendar))
        counters.checks = 312
        counters.nudges = 3
        counters.snoozes = 1
        agent.showPreview(lastCheckAt: at1042, offTask: false, counters: counters)
        let model = FlowObserverModel(
          setup: setup, installedModels: { ["llama3.2:3b", "gpt-oss:20b"] }, reconfigure: {})
        return ObserverScreen(suffix: suffix, agent: agent, model: model)
      }
      let screens = [
        screen("") { setup, _ in try setup.chooseLocal(.textLocal, model: "llama3.2:3b") },
        screen("-vision") { setup, _ in try setup.chooseLocal(.visionLocal, model: TBDFlowObserverSetup.defaultVisionModel) },
        screen("-cloud") { setup, registry in
          let connection = TBDModelConnection(name: "Anthropic", endpoint: "https://api.anthropic.com", kind: .anthropic)
          try registry.saveConnection(connection, apiKey: "demo-key-not-real")
          try setup.chooseCloud(connectionID: connection.id, model: "claude-opus-5-5")
        },
      ]
      return ObserverScreens(screens: screens, suiteNames: suites)
    }

    private final class Clock: @unchecked Sendable { var date: Date; init(_ d: Date) { date = d } }

    /// F4: today's plan with Task Board as the source (mockup "today-taskboard"). A seeded source: no helper call, no
    /// entitlement read, no Keychain.
    static func taskBoardPlanner(_ sandbox: FlowShotsSandbox) -> FlowPlanner {
      let calendar = Calendar.current
      let base = calendar.startOfDay(for: Date())
      func at(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: second, of: base) ?? base
      }
      let clock = Clock(at(10, 12))
      let url = sandbox.storeURL("FlowShotsTaskBoard")
      let store = TBDFlowStore(url: url, clock: { clock.date })
      let day = TBDFlowDay.string(from: base, calendar: calendar)
      do {
        let release = try store.addTask(
          title: "Release TBD dev.13", day: day, startAt: at(8, 30), endAt: at(9, 40), source: .taskBoard, taskBoardID: "iss_release",
          taskBoardProject: "TBD")
        try store.setStatus(id: release.id, .done)
        let mockups = try store.addTask(
          title: "Flow mockups for Martin", day: day, startAt: at(9, 40), endAt: at(11, 30), source: .taskBoard, taskBoardID: "iss_flow",
          taskBoardProject: "TBD")
        let reply = try store.addTask(
          title: "Reply to Eyal about the design review", day: day, startAt: at(11, 30), endAt: at(11, 45), source: .taskBoard,
          taskBoardID: "iss_reply", taskBoardProject: "Ops")
        try store.markLooksDone(id: reply.id, at: at(11, 41))
        try store.addTask(title: "Weekly review", day: day, startAt: at(16, 0), endAt: at(16, 30))
        try store.startFocus(taskID: mockups.id, mode: .focus, minutes: 25)
      } catch {
        print("tbd design shots: flow task board seed failed: \(error)")
      }
      clock.date = at(10, 18, 18)
      let source = sandbox.taskBoard(
        mode: .taskBoard,
        issues: [
          TBDFlowTaskBoardIssue(id: "iss_flow", title: "Flow mockups for Martin", project: "TBD", status: .inProgress, priority: "high", ready: false),
          TBDFlowTaskBoardIssue(id: "iss_weekly", title: "Weekly review", project: "Ops", status: .todo, priority: "medium", ready: true),
          TBDFlowTaskBoardIssue(id: "iss_q4", title: "Draft the Q4 pricing page", project: "Website", status: .todo, priority: "medium", ready: true),
          TBDFlowTaskBoardIssue(id: "iss_penpot", title: "Answer the Penpot licence question", project: "Ops", status: .todo, priority: "low", ready: true),
        ])
      let planner = sandbox.planner(store: store, now: { clock.date }, taskBoard: source)
      planner.load()
      return planner
    }

    /// F5: Task Board plan with Companion's cards of the morning (mockups "today-taskboard" and "plan-vs-actual"): model, rule
    /// and person labels, an idle break, and a few finished timeboxes. A seeded source and seeded cards: no helper call, no
    /// database, no Keychain, no model call. The clock stands at 11:50.
    static func planVsActualPlanner(_ sandbox: FlowShotsSandbox) -> FlowPlanner {
      let calendar = Calendar.current
      let base = calendar.startOfDay(for: Date())
      func at(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: second, of: base) ?? base
      }
      let clock = Clock(at(11, 12))
      let url = sandbox.storeURL("FlowShotsPlanVsActual")
      let store = TBDFlowStore(url: url, clock: { clock.date })
      let day = TBDFlowDay.string(from: base, calendar: calendar)
      do {
        let release = try store.addTask(
          title: "Release TBD dev.13", day: day, startAt: at(8, 30), endAt: at(9, 40), source: .taskBoard, taskBoardID: "iss_release",
          taskBoardProject: "TBD")
        try store.setStatus(id: release.id, .done)
        try store.addTask(
          title: "Flow mockups for Martin", day: day, startAt: at(9, 40), endAt: at(11, 30), source: .taskBoard, taskBoardID: "iss_flow",
          taskBoardProject: "TBD")
        try store.addTask(
          title: "Reply to Eyal about the design review", day: day, startAt: at(11, 30), endAt: at(11, 45), source: .taskBoard,
          taskBoardID: "iss_reply", taskBoardProject: "Ops")
        try store.addTask(title: "Weekly review", day: day, startAt: at(16, 0), endAt: at(16, 30))
        // Model labels (cards 1, 2, 5), a person's correction (card 4), the rest by the rules (cards 3 and 6).
        try store.setCardLabel(cardID: "101", label: .onPlan, taskID: release.id, by: .model, at: at(9, 40))
        try store.setCardLabel(cardID: "102", label: .offPlan, by: .model, at: at(10, 5))
        try store.setCardLabel(cardID: "104", label: .rest, by: .person, at: at(11, 5))
        try store.setCardLabel(cardID: "105", label: .offPlan, by: .model, at: at(11, 35))
      } catch {
        print("tbd design shots: flow plan vs actual seed failed: \(error)")
      }
      clock.date = at(11, 50)
      func card(_ id: Int64, _ start: String, _ end: String, _ title: String, apps: String, category: String = "Work") -> TimelineCard {
        TimelineCard(
          recordId: id, batchId: 1, startTimestamp: start, endTimestamp: end, category: category, subcategory: "", title: title,
          summary: "", detailedSummary: "", day: day, distractions: nil, videoSummaryURL: nil, otherVideoSummaryURLs: nil,
          appSites: AppSites(primary: apps.components(separatedBy: ", ").first, secondary: apps.components(separatedBy: ", ").dropFirst().first))
      }
      let cards = [
        card(101, "8:30 AM", "9:35 AM", "TBD dev.13 release and notarization", apps: "Terminal, Xcode"),
        card(102, "9:35 AM", "10:00 AM", "Inbox and Portal review", apps: "Mail, Portal"),
        card(103, "10:00 AM", "10:45 AM", "Flow design notes and v1 source reading", apps: "Zed, Terminal"),
        card(104, "10:45 AM", "11:00 AM", "Coffee, away from the Mac", apps: "Idle", category: "Idle"),
        card(105, "11:00 AM", "11:30 AM", "News and social", apps: "Safari"),
        card(106, "11:30 AM", "11:41 AM", "Reply to Eyal about the design review", apps: "Mail"),
      ]
      let source = sandbox.taskBoard(mode: .taskBoard)
      let planner = sandbox.planner(store: store, now: { clock.date }, taskBoard: source, cards: cards)
      planner.load()
      return planner
    }

    static func planner(_ sandbox: FlowShotsSandbox) -> FlowPlanner {
      let calendar = Calendar.current
      let base = calendar.startOfDay(for: Date())
      func at(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: second, of: base) ?? base
      }
      let clock = Clock(at(10, 12))
      let url = sandbox.storeURL("FlowShots")
      let store = TBDFlowStore(url: url, clock: { clock.date })
      let day = TBDFlowDay.string(from: base, calendar: calendar)
      do {
        let release = try store.addTask(title: "Release TBD dev.13", day: day, startAt: at(8, 30), endAt: at(9, 40))
        try store.setStatus(id: release.id, .done)
        let mockups = try store.addTask(title: "Flow mockups for Martin", day: day, startAt: at(9, 40), endAt: at(11, 30))
        try store.addTask(title: "Reply to Eyal about the design review", day: day, startAt: at(11, 30), endAt: at(11, 45))
        try store.addTask(title: "Weekly review", day: day, startAt: at(16, 0), endAt: at(16, 30))
        try store.startFocus(taskID: mockups.id, mode: .focus, minutes: 25)
      } catch {
        print("tbd design shots: flow seed failed: \(error)")
      }
      clock.date = at(10, 18, 18)  // 18:42 left of the 25 minutes
      let planner = sandbox.planner(
        store: store, now: { clock.date }, taskBoard: sandbox.taskBoard(mode: .local(.notLicensed)))
      planner.load()
      return planner
    }
  }

  /// The screen source of the Flow shots: it never captures (the observer is never started in the shots).
  struct FlowShotsNoScreen: FlowScreenSource {
    private struct NoScreen: Error {}
    func captureImage(height: Int) async throws -> CGImage { throw NoScreen() }
    func recognizeText(in image: CGImage) -> String { "" }
    func writeJPEG(_ image: CGImage, to url: URL, quality: Double) throws { throw NoScreen() }
  }

  // MARK: - Demo data

  /// Neutral demo timeline cards for the last seven timeline days (no app sites: nothing fetches favicons).
  private enum DemoSeed {
    static func seed() -> Bool {
      let storage = StorageManager.shared
      let calendar = Calendar.current
      let today = calendar.startOfDay(for: timelineDisplayDate(from: Date()))
      let cards: [(String, String, String, String, String, String)] = [
        ("8:30 AM", "9:20 AM", "Work", "Planning", "Release plan review", "Went through the release checklist and open issues."),
        ("9:20 AM", "9:45 AM", "Personal", "Email", "Inbox and calendar", "Answered a few messages and moved two meetings."),
        ("9:45 AM", "11:40 AM", "Work", "Design", "Companion screens on the kit", "Moved the Settings pages to the shared components."),
        ("11:40 AM", "12:00 PM", "Distraction", "News", "News and feeds", "Read headlines and scrolled a feed."),
        ("12:00 PM", "12:45 PM", "Personal", "Break", "Lunch break", "Away from the desk."),
        ("12:45 PM", "2:15 PM", "Work", "Meetings", "Weekly planning call", "Agreed the order of the next three tasks."),
        ("2:15 PM", "2:40 PM", "Distraction", "Video", "Short videos", "Watched a few short videos."),
        ("2:40 PM", "5:10 PM", "Work", "Writing", "Docs and contrast check", "Wrote the screenshot notes and checked contrast."),
      ]
      var saved = 0
      for back in 0..<7 {
        guard let day = calendar.date(byAdding: .day, value: -back, to: today),
          let start = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day),
          let end = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day)
        else { continue }
        var batchID: Int64 = 0
        try? storage.timedWrite("designShotsSeedBatch") { db in
          try db.execute(
            sql: "INSERT INTO analysis_batches(batch_start_ts, batch_end_ts) VALUES (?, ?)",
            arguments: [Int(start.timeIntervalSince1970), Int(end.timeIntervalSince1970)])
          batchID = db.lastInsertedRowID
        }
        guard batchID != 0 else { continue }
        // Vary the days a little so Weekly is not seven identical columns.
        for (i, c) in cards.enumerated() where (i + back) % 5 != 4 {
          let shell = TimelineCardShell(
            startTimestamp: c.0, endTimestamp: c.1, category: c.2, subcategory: c.3, title: c.4,
            summary: c.5, detailedSummary: c.5, distractions: nil, appSites: nil)
          if storage.saveTimelineCardShell(batchId: batchID, card: shell) != nil { saved += 1 }
        }
      }
      print("tbd design shots: seeded \(saved) demo cards in \(TBDIdentity.applicationSupport().path)")
      return saved > 0
    }
  }

  // MARK: - Rendered contrast audit (same method and thresholds as native/Sources/TBDDesignShots/main.swift)

  private struct ContrastFailure: Encodable {
    let screen: String; let x: Int; let y: Int; let w: Int; let h: Int
    let ink: String; let ground: String; let ratio: Double; let need: Double
  }
  private struct ScreenResult: Encodable { let screen: String; let textBoxes: Int; let failures: Int; let unclassified: Int }
  private struct ShotsReport: Encodable { let screens: [ScreenResult]; let failures: [ContrastFailure] }

  extension JSONEncoder {
    fileprivate static var shotsPretty: JSONEncoder {
      let e = JSONEncoder()
      e.outputFormatting = [.prettyPrinted, .sortedKeys]
      return e
    }
  }

  private enum ContrastAudit {
    typealias RGB = (Int, Int, Int)

    static func palette(dark: Bool) -> [(String, RGB)] {
      var out: [(String, RGB)] = []
      NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        for (name, color) in TBDColor.all {
          guard let c = NSColor(color).usingColorSpace(.sRGB), c.alphaComponent > 0.99 else { continue }
          out.append((name, (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))))
        }
      }
      return out
    }
    static let decorative: Set<String> = [
      "line", "tealWashLine", "statusIdleEdge", "statusLiveEdge", "statusBusyEdge", "plate", "tealWash", "brickWash",
      "selection", "paper", "tile", "film", "filmFrame", "spotPaper", "handSwatch", "scrollTrack", "scrollThumb",
      "scrollThumbHover", "optionHoverFill", "disabledFill", "disabledOn", "optionDisabledOn",
    ]
    static let uiOnly: Set<String> = [
      "lineStrong", "fieldEdge", "quietEdge", "tabEdge", "teal", "brick", "toneTeal", "toneBrick", "toneStone", "toneWood",
      "toneMoss", "wireLive", "countFill", "dangerEdge", "fieldInvalidEdge", "danger", "scrollThumbActive",
    ]

    /// Returns (text boxes checked, failures, boxes whose ink is not a kit colour).
    static func audit(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, dark: Bool, screen: String) -> (Int, [ContrastFailure], Int) {
      let w = a.pixelsWide, h = a.pixelsHigh
      guard let pa = a.bitmapData, let pb = b.bitmapData else { return (0, [], 0) }
      let rowA = a.bytesPerRow, rowB = b.bytesPerRow, spp = a.samplesPerPixel
      func px(_ p: UnsafeMutablePointer<UInt8>, _ row: Int, _ x: Int, _ y: Int) -> RGB {
        let o = y * row + x * spp
        return (Int(p[o]), Int(p[o + 1]), Int(p[o + 2]))
      }
      let kit = palette(dark: dark)
      func token(_ c: RGB) -> String? {
        var best: (String, Int)?
        for (n, k) in kit {
          let d = abs(k.0 - c.0) + abs(k.1 - c.1) + abs(k.2 - c.2)
          if d <= 9, d < (best?.1 ?? .max) { best = (n, d) }
        }
        return best?.0
      }
      var mask = [Bool](repeating: false, count: w * h)
      for y in 0..<h {
        for x in 0..<w {
          let p = px(pa, rowA, x, y), q = px(pb, rowB, x, y)
          if abs(p.0 - q.0) + abs(p.1 - q.1) + abs(p.2 - q.2) > 60 { mask[y * w + x] = true }
        }
      }
      let cell = 6, cw = (w + cell - 1) / cell, ch = (h + cell - 1) / cell
      var on = [Bool](repeating: false, count: cw * ch)
      for y in 0..<h { for x in 0..<w where mask[y * w + x] { on[(y / cell) * cw + x / cell] = true } }
      var seen = [Bool](repeating: false, count: cw * ch)
      var boxes: [(Int, Int, Int, Int)] = []
      for start in 0..<(cw * ch) where on[start] && !seen[start] {
        var stack = [start]
        seen[start] = true
        var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
        while let c = stack.popLast() {
          let cx = c % cw, cy = c / cw
          minX = min(minX, cx); maxX = max(maxX, cx); minY = min(minY, cy); maxY = max(maxY, cy)
          for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            let nx = cx + dx, ny = cy + dy
            guard nx >= 0, ny >= 0, nx < cw, ny < ch else { continue }
            let n = ny * cw + nx
            if on[n] && !seen[n] { seen[n] = true; stack.append(n) }
          }
        }
        boxes.append((minX * cell, minY * cell, min(w, (maxX + 1) * cell), min(h, (maxY + 1) * cell)))
      }
      func lum(_ c: RGB) -> Double {
        func f(_ v: Int) -> Double { let x = Double(v) / 255; return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(c.0) + 0.7152 * f(c.1) + 0.0722 * f(c.2)
      }
      func ratio(_ p: RGB, _ q: RGB) -> Double { let l1 = lum(p), l2 = lum(q); return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05) }
      func hex(_ c: RGB) -> String { String(format: "#%02x%02x%02x", c.0, c.1, c.2) }
      var out: [ContrastFailure] = []
      var counted = 0, unclassified = 0
      for (x0, y0, x1, y1) in boxes where (x1 - x0) >= 16 && (y1 - y0) >= 16 {
        var counts: [Int: Int] = [:]
        for y in max(0, y0 - 4)..<min(h, y1 + 4) {
          for x in max(0, x0 - 4)..<min(w, x1 + 4) {
            if (x >= x0 - 1 && x < x1 + 1 && y >= y0 - 1 && y < y1 + 1) || mask[y * w + x] { continue }
            let c = px(pa, rowA, x, y)
            counts[(c.0 << 16) | (c.1 << 8) | c.2, default: 0] += 1
          }
        }
        guard let g = counts.max(by: { $0.value < $1.value })?.key else { continue }
        let ground: RGB = (g >> 16 & 255, g >> 8 & 255, g & 255)
        var ratios: [(Double, RGB)] = []
        for y in y0..<y1 {
          for x in x0..<x1 where mask[y * w + x] {
            let c = px(pa, rowA, x, y)
            ratios.append((ratio(c, ground), c))
          }
        }
        guard ratios.count >= 12 else { continue }
        ratios.sort { $0.0 < $1.0 }
        guard let top = ratios.last, top.0 >= 1.5 else { continue }
        let ink = ratios[min(ratios.count - 1, Int(Double(ratios.count) * 0.97))]
        guard let name = token(ink.1) else { unclassified += 1; continue }
        if decorative.contains(name) { continue }
        counted += 1
        let large = Double(y1 - y0) / 2 >= 30
        let need = uiOnly.contains(name) || large ? 3.0 : 4.5
        if ink.0 < need {
          out.append(
            ContrastFailure(
              screen: screen, x: x0 / 2, y: y0 / 2, w: (x1 - x0) / 2, h: (y1 - y0) / 2,
              ink: "\(name) \(hex(ink.1))", ground: hex(ground), ratio: (ink.0 * 100).rounded() / 100, need: need))
        }
      }
      return (counted, out, unclassified)
    }
  }
/// Fixed states for the onboarding shots (the same states as the approved mockups).
@MainActor
private enum OnboardingShots {
  static func screens() -> [(String, TBDOnboardingController)] {
    let all = Set(TBDOnboardingPermission.allCases)
    let allOn = TBDOnboardingChecks(
      signedIn: true, workspaceName: "Studio North", agentModelReady: true, agentModelName: "gpt-oss:20b", agentPaired: true,
      granted: all, companionModelReady: true, companionModelName: "qwen3-vl:4b", speechModelOnDisk: true,
      paidApps: TBDEntitlements(apps: [.knowledge: .unlocked], workspace: "ws").summaryChecks)
    let some = TBDOnboardingChecks(
      signedIn: true, workspaceName: "Studio North", granted: [.screenRecording, .microphone, .notifications],
      speechDownload: 0.62, paidApps: TBDEntitlements(apps: [.knowledge: .install], workspace: "ws").summaryChecks)
    return [
      ("0-welcome", .preview(step: .welcome, choices: .init(), checks: .init())),
      ("1-portal", .preview(step: .portal, choices: .init(portal: .yes), checks: .init())),
      ("2-agent", .preview(step: .agent, choices: .init(portal: .no, agent: .yes, agentRuntime: .local),
                           checks: .init(agentModelReady: true, agentModelName: "gpt-oss:20b"))),
      ("2-agent-cloud", .preview(step: .agent, choices: .init(portal: .no, agent: .yes, agentRuntime: .cloud),
                                 checks: { var c = TBDOnboardingChecks(agentModelReady: true, agentModelName: "us.anthropic.claude-sonnet-4-6")
                                           c.agentCloud = "Amazon Bedrock"; return c }())),
      ("2-agent-langchain", .preview(step: .agent, choices: .init(portal: .no, agent: .yes, agentRuntime: .local),
                                     checks: .init(agentModelReady: true, agentModelName: "gpt-oss:20b"), langchain: true)),
      ("3-permissions", .preview(step: .permissions, choices: .init(portal: .no, agent: .no),
                                 checks: .init(granted: [.microphone, .notifications]), screenRequested: true)),
      ("4-models", .preview(step: .models, choices: .init(portal: .no, agent: .no),
                            checks: .init(granted: all, companionModelReady: true, companionModelName: "qwen3-vl:4b"))),
      ("4-models-local", .preview(step: .models, choices: .init(portal: .no, agent: .no),
                                  checks: .init(granted: all), companionLocal: .modelMissing("qwen3-vl:4b"))),
      ("5-summary-all-on", .preview(step: .summary, choices: .init(portal: .yes, agent: .yes), checks: allOn)),
      ("5-summary-some-skipped", .preview(step: .summary, choices: .init(portal: .yes, agent: .no), checks: some)),
    ]
  }
}

#endif
