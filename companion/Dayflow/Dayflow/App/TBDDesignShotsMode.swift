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
      // Creates the Listening context on the demo root (no start: no capture, hotkeys, downloads), so Settings → Listen
      // pages render their real content.
      _ = TBDListeningRuntime.shared.previewSettings(section: "capture")

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
          try render(SettingsView(initialSection: tab).padding(15), size: main, dark: dark, name: "settings-\(tab)-\(theme)")
          // A larger window too: Settings must use the width it is given (TBD-UX-01).
          try render(SettingsView(initialSection: tab).padding(15), size: wide, dark: dark, name: "settings-\(tab)-1600-\(theme)")
        }
        try render(TBDCompanionSetup(), size: main, dark: dark, name: "setup-\(theme)")
        // WP-ONB: the built first-launch flow, every step and the summary in two states (C286 mockups).
        for (name, flow) in OnboardingShots.screens() {
          try render(TBDOnboardingView(flow: flow), size: main, dark: dark, name: "onboarding-\(name)-\(theme)")
        }
        try render(StatusMenuView(dismissMenu: {}), size: CGSize(width: 320, height: 640), dark: dark, name: "menu-\(theme)")
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
      granted: all, companionModelReady: true, companionModelName: "qwen3-vl:4b", speechModelOnDisk: true)
    let some = TBDOnboardingChecks(
      signedIn: true, workspaceName: "Studio North", granted: [.screenRecording, .microphone, .notifications],
      speechDownload: 0.62)
    return [
      ("0-welcome", .preview(step: .welcome, choices: .init(), checks: .init())),
      ("1-portal", .preview(step: .portal, choices: .init(portal: .yes), checks: .init())),
      ("2-agent", .preview(step: .agent, choices: .init(portal: .no, agent: .yes, agentRuntime: .local),
                           checks: .init(agentModelReady: true, agentModelName: "gpt-oss:20b"))),
      ("3-permissions", .preview(step: .permissions, choices: .init(portal: .no, agent: .no),
                                 checks: .init(granted: [.microphone, .notifications]), screenRequested: true)),
      ("4-models", .preview(step: .models, choices: .init(portal: .no, agent: .no),
                            checks: .init(granted: all, companionModelReady: true, companionModelName: "qwen3-vl:4b"))),
      ("5-summary-all-on", .preview(step: .summary, choices: .init(portal: .yes, agent: .yes), checks: allOn)),
      ("5-summary-some-skipped", .preview(step: .summary, choices: .init(portal: .yes, agent: .no), checks: some)),
    ]
  }
}

#endif
