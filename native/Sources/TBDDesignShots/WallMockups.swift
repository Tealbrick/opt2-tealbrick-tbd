// Wall mockups (WP-WALL, C280 C4, C127): the v1 Agents brick wall next to the restored roster wall, so Martin can say
// "yes, that is the wall". Static views for review, NOT app code. Branch mockup/wp-wall only.
//
// A: "v1"     the v1 page as it was (companion AgentWallView.swift @33d7fe17): header + day label, the photoreal wall band
//             with its hour ruler, three cards (summary, sessions, legend + toggles). One brick = ten minutes.
// B: "restored" the same wall, endless-scroll look (frozen), but ONE brick per workspace agent from the roster (C127).
// C: "restored-empty" signed in, no workspace agents yet: only TBD's own brick and a short notice.
//
// The renderer below is a port of v1's: the red image is tiled across the band, recoloured bricks are cut from the teal /
// tealdeep / amber images clipped to the brick rects, contact shadow, 5% edge fade, callouts with leader dots (courses >= 4
// above, others below, crowding rule 190 pt). The scroll offset is frozen. Differences from v1 (all for the kit or the audit):
// fonts and colours are TBDDesign tokens (v1 used Switzer/Georgia and its TBDTokens shims); callout and ruler TEXT is drawn
// as SwiftUI Text over the Canvas (not inside it) so the rendered contrast audit can see it; the legend swatches are crops
// of the same photos at run time (v1 used asset-catalog images). The 2.6 MB of photos are NOT in this package: they are
// read from <wallImagesDir> (wall-red.jpg, wall-teal.jpg, wall-tealdeep.jpg, wall-amber.jpg).
// Usage: swift run tbd-design-shots --wall-mockups <outDir> <wallImagesDir>  -> wall-<screen>-<size>-<theme>.png + audit.
import AppKit
import SwiftUI
import TBDDesign

// MARK: - Photos

struct WallPhotos {
    let red: NSImage, teal: NSImage, deep: NSImage, amber: NSImage
    /// One brick cut from each photo (legend and list swatches).
    let redBrick: NSImage, tealBrick: NSImage, deepBrick: NSImage, amberBrick: NSImage

    static func load(_ dir: String) throws -> WallPhotos {
        func image(_ name: String) throws -> NSImage {
            let path = (dir as NSString).appendingPathComponent("wall-\(name).jpg")
            guard let img = NSImage(contentsOfFile: path) else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path]) }
            return img
        }
        let red = try image("red"), teal = try image("teal"), deep = try image("tealdeep"), amber = try image("amber")
        return WallPhotos(red: red, teal: teal, deep: deep, amber: amber,
                          redBrick: brick(red), tealBrick: brick(teal), deepBrick: brick(deep), amberBrick: brick(amber))
    }

    /// Course 4, brick 0, inset a few pixels so the joint is not in the swatch. 1 m = 1500 px in the 2700 x 900 photos.
    private static func brick(_ image: NSImage) -> NSImage {
        let ppm = 1500.0
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let rect = CGRect(x: AgentWallTile.brickX(course: 4, index: 0) * ppm + 8, y: AgentWallTile.brickTop(course: 4) * ppm + 8,
                          width: AgentWallTile.brickW * ppm - 16, height: AgentWallTile.brickH * ppm - 16)
        guard let cut = cg.cropping(to: rect) else { return image }
        return NSImage(cgImage: cut, size: NSSize(width: rect.width, height: rect.height))
    }
}

// MARK: - Palette, tile geometry (v1: AgentWallPalette, AgentWallTile)

enum AgentWallTile {
    static let bricksPerCourse = 8, courses = 8
    static let pitch = 0.225, course = 0.075, brickW = 0.215, brickH = 0.065, width = 1.8, height = 0.6
    static let aspect = CGFloat(width / height)
    /// Sessions fill the middle courses first.
    static let courseOrder = [4, 3, 5, 2, 6, 1, 7, 0]
    /// Left edge (metres) of brick `k` in course `r`, within one tile.
    static func brickX(course r: Int, index k: Int) -> Double { Double(k) * pitch + (r % 2 == 1 ? pitch / 2 : 0) + (pitch - brickW) / 2 }
    /// Top edge (metres from the top of the tile) of course `r`, course 0 at the bottom.
    static func brickTop(course r: Int) -> Double { height - (Double(r) * course + course / 2 + brickH / 2) }
    /// Left edge (metres) of the `g`-th brick of a course counted along the endless wall.
    static func x(course r: Int, global g: Int) -> Double { Double(g / bricksPerCourse) * width + brickX(course: r, index: g % bricksPerCourse) }
}

enum AgentBrickTone { case teal, deep, amber }

struct AgentWallBrick {
    let course: Int
    let x: Double
    let tone: AgentBrickTone
    var remote = false
}

struct AgentWallCallout {
    let id: String
    let course: Int
    let x: Double
    let title: String
    let meta: String
}

func positiveMod(_ value: Double, _ modulus: Double) -> Double {
    guard modulus > 0 else { return 0 }
    let r = value.truncatingRemainder(dividingBy: modulus)
    return r < 0 ? r + modulus : r
}

// MARK: - The plan (v1: AgentWallPlan, plus the roster plan)

struct WallThread: Identifiable {
    let id: String
    let project: String
    let provider: String
    let lane: Int
    let title: String
    let summary: String
    let spans: [ClosedRange<Double>]
    let waits: [ClosedRange<Double>]
    var active = false
    var start: Double { spans.map(\.lowerBound).min() ?? 0 }
    var end: Double { spans.map(\.upperBound).max() ?? 0 }
    var workingHours: Double { spans.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }
    var waitingHours: Double { waits.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }
}

struct WallRemote: Identifiable {
    let id: String
    let agentName: String
    let title: String
    let hour: Double
}

struct WallPlan {
    let lo: Double, hi: Double
    let loopWidth: Double  // metres
    let bricks: [AgentWallBrick]
    let callouts: [AgentWallCallout]
    let ruler: Bool

    /// v1, ported as is: lay the day across one loop of the wall; one brick is ten minutes.
    init(threads: [WallThread], remotes: [WallRemote], highlightWaiting: Bool) {
        let hours = threads.flatMap { $0.spans.flatMap { [$0.lowerBound, $0.upperBound] } } + remotes.map(\.hour)
        var lo = floor(hours.min() ?? 9) - 0.5, hi = ceil(hours.max() ?? 17) + 0.5
        if hi - lo < 6 { hi = lo + 6 }
        lo = max(0, lo); hi = min(24.5, hi)
        self.lo = lo; self.hi = hi
        let bricksPerHour = 6.0
        let tiles = max(3, Int(ceil((hi - lo) * bricksPerHour / Double(AgentWallTile.bricksPerCourse))))
        loopWidth = Double(tiles) * AgentWallTile.width
        ruler = true
        let span = hi - lo, loop = loopWidth
        func time(_ x: Double) -> Double { lo + x / loop * span }
        func xOf(_ hour: Double) -> Double { (hour - lo) / span * loop }

        var bricks: [AgentWallBrick] = []
        var callouts: [AgentWallCallout] = []
        let total = tiles * AgentWallTile.bricksPerCourse
        for thread in threads.sorted(by: { $0.start < $1.start }) {
            let course = AgentWallTile.courseOrder[thread.lane % AgentWallTile.courseOrder.count]
            var first: Double?
            for g in 0..<total {
                let x0 = AgentWallTile.x(course: course, global: g)
                let range = time(x0)...time(x0 + AgentWallTile.brickW)
                let working = thread.spans.contains { $0.overlaps(range) }
                let waiting = highlightWaiting && thread.waits.contains { $0.overlaps(range) }
                guard working || waiting else { continue }
                let tone: AgentBrickTone = waiting && !working ? .amber : (thread.active ? .deep : .teal)
                bricks.append(AgentWallBrick(course: course, x: x0, tone: tone))
                if first == nil { first = x0 }
            }
            if let first {
                let p = thread.provider.lowercased()
                let provider = p.contains("claude") ? "Claude Code" : p.contains("openai") || p.contains("codex") ? "Codex" : thread.provider.capitalized
                let meta = [thread.project, provider, Self.short(thread.workingHours), thread.active ? "running" : nil].compactMap { $0 }.joined(separator: " · ")
                callouts.append(AgentWallCallout(id: thread.id, course: course, x: first + AgentWallTile.brickW / 2, title: thread.title, meta: meta))
            }
        }
        for remote in remotes {
            let course = 7
            let g = Int((xOf(remote.hour) / AgentWallTile.pitch).rounded(.down))
            let x0 = AgentWallTile.x(course: course, global: g)
            bricks.append(AgentWallBrick(course: course, x: x0, tone: .teal, remote: true))
            callouts.append(AgentWallCallout(id: remote.id, course: course, x: x0 + AgentWallTile.brickW / 2, title: remote.title,
                                             meta: "Portal · \(remote.agentName) · 11:15"))
        }
        self.bricks = bricks
        self.callouts = callouts
    }

    /// Restored (C127): one brick per workspace agent. SLOT RULE (deterministic, same input = same wall):
    ///   1. order: TBD's own agent first, then the workspace agents by name (case-insensitive);
    ///   2. slot `i` is course `courseOrder[i % 8]` (4,3,5,2,6,1,7,0), so the first slots sit mid-wall;
    ///   3. its column is brick number `firstColumn + i * columnSpacing` counted along that course on the endless wall;
    ///   4. tone by state: own = deep teal, online = teal, paused = amber, offline = no recolour (plain red, callout only).
    /// An offline agent keeps its slot so the wall does not reshuffle when an agent goes on or off line.
    static let firstColumn = 1, columnSpacing = 1
    init(roster: [WallAgent], showOffline: Bool) {
        lo = 0; hi = 0
        loopWidth = 3 * AgentWallTile.width
        ruler = false
        var bricks: [AgentWallBrick] = []
        var callouts: [AgentWallCallout] = []
        for (i, agent) in Self.ordered(roster).enumerated() {
            let course = AgentWallTile.courseOrder[i % AgentWallTile.courseOrder.count]
            let x0 = AgentWallTile.x(course: course, global: Self.firstColumn + i * Self.columnSpacing)
            if agent.state == .offline && !showOffline { continue }
            let tone: AgentBrickTone? = agent.own ? .deep : agent.state == .online ? .teal : agent.state == .paused ? .amber : nil
            if let tone { bricks.append(AgentWallBrick(course: course, x: x0, tone: tone)) }
            callouts.append(AgentWallCallout(id: agent.name, course: course, x: x0 + AgentWallTile.brickW / 2, title: agent.name,
                                             meta: "\(agent.harness)\n\(agent.state.rawValue)"))  // two short lines: neighbours one brick apart never touch
        }
        self.bricks = bricks
        self.callouts = callouts
    }

    static func ordered(_ roster: [WallAgent]) -> [WallAgent] {
        roster.filter(\.own) + roster.filter { !$0.own }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func x(forHour hour: Double) -> Double { (hour - lo) / (hi - lo) * loopWidth }
    static func short(_ hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

// MARK: - The wall band (v1: wallBand + drawBand)

struct WallBand: View {
    let photos: WallPhotos
    let plan: WallPlan
    let width: CGFloat
    let wallHeight: CGFloat
    let shift: Double          // frozen scroll offset, points
    /// v1: 190 pt between two labels on the same side. The roster labels are short (<= 26 mono characters), so B and C use 160.
    var crowding: CGFloat = 190
    static let calloutZone: CGFloat = 56
    static let rulerHeight: CGFloat = 24

    private var rulerHeight: CGFloat { plan.ruler ? Self.rulerHeight : 0 }
    private var k: CGFloat { wallHeight / CGFloat(AgentWallTile.height) }
    private var tile: CGSize { CGSize(width: wallHeight * AgentWallTile.aspect, height: wallHeight) }

    /// Screen rects for a brick, including its repeats around the loop.
    private func screenRects(course: Int, x brickX: Double) -> [CGRect] {
        let loop = plan.loopWidth * Double(k)
        let y = Self.calloutZone + CGFloat(AgentWallTile.brickTop(course: course)) * k
        var base = brickX * Double(k) + positiveMod(shift, loop)
        while base > Double(width) { base -= loop }
        var rects: [CGRect] = []
        var x = base
        while x > -loop { x -= loop }
        while x < Double(width) + loop {
            let r = CGRect(x: x, y: y, width: AgentWallTile.brickW * Double(k), height: AgentWallTile.brickH * Double(k))
            if r.maxX > -20 && r.minX < width + 20 { rects.append(r) }
            x += loop
        }
        return rects
    }

    struct Placement: Identifiable {
        let id: String
        let rect: CGRect
        let above: Bool
        let labelY: CGFloat
        let title: String
        let meta: String
    }

    /// v1's callout rule: courses >= 4 above, others below; skip a label within `crowding` (190) pt of one on the same side.
    private var placements: [Placement] {
        let wallTop = Self.calloutZone
        var placed: [(side: Int, x: CGFloat)] = []
        var out: [Placement] = []
        for callout in plan.callouts.sorted(by: { $0.x < $1.x }) {
            for rect in screenRects(course: callout.course, x: callout.x - AgentWallTile.brickW / 2) where rect.midX > width * 0.07 && rect.midX + 240 < width * 0.95 {
                let above = callout.course >= 4
                let side = above ? 0 : 1
                if placed.contains(where: { $0.side == side && abs($0.x - rect.midX) < crowding }) { continue }
                placed.append((side, rect.midX))
                let labelY: CGFloat = above ? 4 : wallTop + wallHeight + rulerHeight + 6
                let title = callout.title.count > 34 ? String(callout.title.prefix(33)) + "…" : callout.title
                out.append(Placement(id: callout.id, rect: rect, above: above, labelY: labelY, title: title, meta: callout.meta))
            }
        }
        return out
    }

    /// Hour ruler marks (x on screen, label).
    private var rulerMarks: [(x: Double, label: String)] {
        guard plan.ruler else { return [] }
        let loop = plan.loopWidth * Double(k)
        var out: [(Double, String)] = []
        for h in stride(from: ceil(plan.lo), through: floor(plan.hi), by: 1) {
            var hx = plan.x(forHour: h) * Double(k) + positiveMod(shift, loop)
            while hx > Double(width) { hx -= loop }
            while hx < -loop { hx += loop }
            var px = hx
            while px < Double(width) + 40 {
                if px > -40 { out.append((px, String(format: "%02d:00", Int(h) % 24))) }
                px += loop
            }
        }
        return out
    }

    private var fade: LinearGradient {
        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.05),
                               .init(color: .black, location: 0.95), .init(color: .clear, location: 1)],
                       startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        let total = Self.calloutZone * 2 + wallHeight + rulerHeight
        let marks = rulerMarks
        let pl = placements
        ZStack(alignment: .topLeading) {
            Canvas { context, size in draw(&context, size: size, marks: marks, placements: pl) }
                .mask(fade)
            // Ruler labels (faded with the wall).
            ZStack(alignment: .topLeading) {
                ForEach(Array(marks.enumerated()), id: \.offset) { _, m in
                    Text(m.label).font(TBDFonts.mono(10)).foregroundStyle(TBDColor.muted)
                        .frame(width: 60).offset(x: m.x - 30, y: Self.calloutZone + wallHeight + 8 + 6)
                }
            }
            .frame(width: width, height: total, alignment: .topLeading)
            .mask(fade)
            // Callout text.
            ForEach(pl) { p in
                VStack(alignment: .leading, spacing: 0) {
                    Text(p.title).font(TBDTokens.Typography.label).foregroundStyle(TBDColor.ink)
                    Text(p.meta).font(TBDFonts.mono(10)).foregroundStyle(TBDColor.muted).lineLimit(2).fixedSize().padding(.top, 2)
                }
                .lineLimit(1).fixedSize()
                .offset(x: p.rect.midX + 6, y: p.labelY)
            }
        }
        .frame(width: width, height: total, alignment: .topLeading)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, marks: [(x: Double, label: String)], placements: [Placement]) {
        let wallTop = Self.calloutZone
        let red = context.resolve(Image(nsImage: photos.red))
        let tones: [AgentBrickTone: GraphicsContext.ResolvedImage] = [
            .teal: context.resolve(Image(nsImage: photos.teal)), .deep: context.resolve(Image(nsImage: photos.deep)), .amber: context.resolve(Image(nsImage: photos.amber))]
        // Soft contact shadow under the wall.
        context.fill(Path(CGRect(x: 0, y: wallTop + wallHeight, width: size.width, height: 10)),
                     with: .linearGradient(Gradient(colors: [.black.opacity(0.18), .clear]), startPoint: CGPoint(x: 0, y: wallTop + wallHeight), endPoint: CGPoint(x: 0, y: wallTop + wallHeight + 10)))
        // Endless red wall.
        let offset = positiveMod(shift, Double(tile.width))
        var x = CGFloat(offset) - tile.width
        while x < size.width {
            context.draw(red, in: CGRect(x: x, y: wallTop, width: tile.width + 1, height: tile.height))   // +1 pt overlap: no hairline seam between tiles
            x += tile.width
        }
        // Session bricks: the same brick, cut from the recoloured render.
        for brick in plan.bricks {
            for rect in screenRects(course: brick.course, x: brick.x) {
                guard let image = tones[brick.tone] else { continue }
                context.drawLayer { layer in
                    layer.clip(to: Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 3))
                    // Tile origin aligned with the red wall so shading matches exactly.
                    var tx = CGFloat(offset) - tile.width
                    while tx + tile.width < rect.minX - 2 { tx += tile.width }
                    layer.draw(image, in: CGRect(x: tx, y: wallTop, width: tile.width + 1, height: tile.height))
                    layer.draw(image, in: CGRect(x: tx + tile.width, y: wallTop, width: tile.width, height: tile.height))
                }
                if brick.remote {   // the Portal marker
                    context.fill(Path(CGRect(x: rect.maxX - 9, y: rect.minY + 5, width: 5, height: 5)), with: .color(.white.opacity(0.9)))
                }
            }
        }
        // Ruler ticks (labels are Text above the canvas).
        let rulerY = wallTop + wallHeight + 8
        for m in marks { context.fill(Path(CGRect(x: m.x, y: rulerY - 6, width: 1, height: 6)), with: .color(TBDColor.muted.opacity(0.6))) }
        // Callout leaders and dots.
        for p in placements {
            let leaderStart = CGPoint(x: p.rect.midX, y: p.above ? p.rect.minY + 4 : p.rect.maxY - 4)
            let leaderEnd = CGPoint(x: p.rect.midX, y: p.above ? p.labelY + 33 : p.labelY - 3)
            var leader = Path(); leader.move(to: leaderStart); leader.addLine(to: leaderEnd)
            context.stroke(leader, with: .color(TBDColor.ink.opacity(0.55)), lineWidth: 1)
            let dot = Path(ellipseIn: CGRect(x: leaderStart.x - 2.5, y: leaderStart.y - 2.5, width: 5, height: 5))
            context.fill(dot, with: .color(.white))
            context.stroke(dot, with: .color(TBDColor.ink.opacity(0.7)), lineWidth: 1)
        }
    }
}

// MARK: - Seeds

struct WallAgent: Identifiable {
    enum State: String { case online, paused, offline }
    var id: String { name }
    let name: String
    let purpose: String
    let harness: String
    let state: State
    var own = false
}

enum WallSeed {
    /// A plausible v1 day, 09:00-15:00, lanes 0-5. The morning rush sits at 10:20-11:30 (where the frozen shot looks).
    static let day: [WallThread] = [
        WallThread(id: "t0", project: "Teal Brick", provider: "claude-code", lane: 0, title: "Fix flaky export test",
                   summary: "", spans: [9.0...10.5], waits: []),
        WallThread(id: "t1", project: "TBD", provider: "codex", lane: 1, title: "Refactor Listen library store",
                   summary: "", spans: [10.45...10.95, 11.3...12.6], waits: [10.95...11.3]),
        WallThread(id: "t2", project: "TBD", provider: "claude-code", lane: 2, title: "Draft onboarding copy",
                   summary: "", spans: [10.4...12.0], waits: []),
        WallThread(id: "t3", project: "Portal", provider: "codex", lane: 3, title: "Review Portal API schema",
                   summary: "", spans: [10.7...13.4], waits: []),
        WallThread(id: "t4", project: "Docs", provider: "claude-code", lane: 4, title: "Update the docs index",
                   summary: "", spans: [10.8...12.7], waits: []),
        WallThread(id: "t5", project: "Teal Brick", provider: "claude-code", lane: 5, title: "Triage CI failures",
                   summary: "", spans: [11.1...15.0], waits: [], active: true),
    ]
    static let remotes = [WallRemote(id: "r0", agentName: "Henry", title: "Weekly digest", hour: 11.25)]

    static let roster: [WallAgent] = [
        WallAgent(name: "TBD", purpose: "Your own agent", harness: "Built in", state: .online, own: true),
        WallAgent(name: "Henry", purpose: "Triage and drafts", harness: "Claude Agent SDK", state: .online),
        WallAgent(name: "Tempo", purpose: "Plan and reminders", harness: "Codex", state: .paused),
        WallAgent(name: "Nova", purpose: "Research", harness: "LangChain", state: .online),
        WallAgent(name: "Scribe", purpose: "Meeting notes", harness: "Claude Agent SDK", state: .offline),
        WallAgent(name: "Atlas", purpose: "Code review", harness: "Codex", state: .online),
    ]
}

// MARK: - The page (v1: AgentWallView)

enum WallScreen: String, CaseIterable {
    case v1, restored, restoredEmpty = "restored-empty"
    var restoredKind: Bool { self != .v1 }
}

struct WallMockup: View {
    let photos: WallPhotos
    let screen: WallScreen
    let size: CGSize
    static let headerHeight: CGFloat = 84

    private var roster: [WallAgent] { screen == .restoredEmpty ? WallSeed.roster.filter(\.own) : WallSeed.roster }
    private var plan: WallPlan {
        screen == .v1 ? WallPlan(threads: WallSeed.day, remotes: WallSeed.remotes, highlightWaiting: true) : WallPlan(roster: roster, showOffline: true)
    }

    var body: some View {
        // Everything fits one screen: the wall takes what is left after header, callouts, ruler and cards.
        // The kit's controls are taller than v1's small system ones, so the cards get 232...300 pt (v1: 170...210).
        let cardsHeight: CGFloat = screen == .restoredEmpty ? 190 : screen == .restored ? min(320, max(240, size.height * 0.31)) : min(300, max(232, size.height * 0.29))
        let notice: CGFloat = screen == .restoredEmpty ? 54 + TBDTokens.Space.lg : 0
        let ruler: CGFloat = screen == .v1 ? WallBand.rulerHeight : 0
        let chrome: CGFloat = 16 + Self.headerHeight + cardsHeight + notice + 2 * TBDTokens.Space.lg + 16
        let wallHeight = min(360, max(150, size.height - chrome - 2 * WallBand.calloutZone - ruler))
        let k = Double(wallHeight / CGFloat(AgentWallTile.height))
        let plan = self.plan
        // Frozen scroll offset: put the anchor (a time of day, or the first agent slot) 100 pt from the left edge.
        let anchorX: Double = screen == .v1
            ? plan.x(forHour: 10.25)
            : AgentWallTile.x(course: AgentWallTile.courseOrder[0], global: WallPlan.firstColumn)
        let shift = 100 - anchorX * k
        VStack(alignment: .leading, spacing: TBDTokens.Space.lg) {
            header.padding(.horizontal, 32).frame(height: Self.headerHeight, alignment: .top)
            WallBand(photos: photos, plan: plan, width: size.width, wallHeight: wallHeight, shift: shift, crowding: screen == .v1 ? 190 : 160)
            if screen == .restoredEmpty {
                TBDNotice("Connect agents to your workspace in Portal. They appear here.").padding(.horizontal, 32)
            }
            HStack(alignment: .top, spacing: TBDTokens.Space.lg) {
                if screen == .v1 {
                    v1Summary.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).tbdCard(padding: TBDTokens.Space.lg)
                    v1Sessions.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).tbdCard(padding: TBDTokens.Space.lg)
                    v1Controls.frame(width: 250).frame(maxHeight: .infinity, alignment: .topLeading).tbdCard(padding: TBDTokens.Space.lg)
                } else {
                    rosterSummary.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).tbdCard(padding: TBDTokens.Space.lg)
                    rosterList.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).tbdCard(padding: TBDTokens.Space.lg)
                    rosterLegend.frame(width: 250).frame(maxHeight: .infinity, alignment: .topLeading).tbdCard(padding: TBDTokens.Space.lg)
                }
            }
            .frame(height: cardsHeight)
            .padding(.horizontal, 32)
        }
        .padding(.vertical, 16)
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(TBDColor.paper)
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        if screen == .v1 {
            TBDPageHeader("Today", label: "Agents · 20 October 2026") {
                HStack(spacing: TBDTokens.Space.sm) {
                    Button {} label: { Image(systemName: "chevron.left") }.buttonStyle(TBDButtonStyle(.icon))
                    Button {} label: { Image(systemName: "calendar") }.buttonStyle(TBDButtonStyle(.icon))
                    Button {} label: { Image(systemName: "chevron.right") }.buttonStyle(TBDButtonStyle(.icon)).disabled(true)
                }
            }
        } else {
            TBDPageHeader("Agents", label: "Your workspace")
        }
    }

    // MARK: v1 cards

    private func metric(_ value: String, _ label: String, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(TBDFonts.nunito(TBDKit.textTitle, TBDKit.weightLabel)).monospacedDigit().foregroundStyle(color ?? TBDColor.ink)
            Text(label).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        }
    }

    private var v1Summary: some View {
        let working = WallSeed.day.reduce(0) { $0 + $1.workingHours }
        let waiting = WallSeed.day.reduce(0) { $0 + $1.waitingHours }
        let peak = stride(from: 9.0, through: 15.0, by: 0.05).map { h in WallSeed.day.filter { $0.spans.contains { $0.contains(h) } }.count }.max() ?? 0
        return VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            TBDLabel("Total hours worked by agents")
            Text(WallPlan.short(working)).font(TBDFonts.nunito(TBDKit.textNumeral, TBDKit.weightHead)).tracking(-1).foregroundStyle(TBDColor.ink)
            HStack(spacing: TBDTokens.Space.xl) {
                metric("\(WallSeed.day.count)", "sessions")
                metric("\(peak)", "at once")
                metric(WallPlan.short(waiting), "waiting on you", color: TBDColor.brickInk)
            }
        }
    }

    private func clock(_ hour: Double) -> String {
        let total = Int((hour * 60).rounded()); return String(format: "%02d:%02d", (total / 60) % 24, total % 60)
    }

    private var v1Sessions: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            TBDLabel("Sessions")
            ScrollView(.vertical, showsIndicators: false) { VStack(alignment: .leading, spacing: 2) {
                ForEach(WallSeed.day.sorted { $0.start < $1.start }) { t in
                    let on = t.active
                    HStack(alignment: .top, spacing: 10) {
                        Image(nsImage: on ? photos.deepBrick : photos.tealBrick).resizable().scaledToFill().frame(width: 22, height: 8)
                            .clipShape(RoundedRectangle(cornerRadius: 1.5)).padding(.top, 6).unredacted()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.title).font(TBDFonts.nunito(TBDKit.textHint, on ? TBDKit.weightLabel : TBDKit.weightNav)).foregroundStyle(TBDColor.ink).lineLimit(1)
                            Text("\(t.project) · \(clock(t.start))–\(clock(t.end)) · \(WallPlan.short(t.workingHours))" + (t.active ? " · running" : ""))
                                .font(TBDFonts.mono(10)).foregroundStyle(TBDColor.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(on ? TBDColor.tealWash : Color.clear, in: TBDBrickShape())
                }
                Rectangle().fill(TBDColor.line).frame(height: 1).padding(.vertical, 3)
                TBDLabel("Portal agents")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Weekly digest").font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightNav)).foregroundStyle(TBDColor.ink)
                    Text("Henry · last active 11:15").font(TBDFonts.mono(10)).foregroundStyle(TBDColor.muted)
                }.padding(.horizontal, 6)
            } }
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.86), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        }
    }

    private func legendRow(_ image: NSImage, _ label: String) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: image).resizable().scaledToFill().frame(width: 26, height: 10).clipShape(RoundedRectangle(cornerRadius: 1.5)).unredacted()
            Text(label).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.ink)
        }
    }

    private var v1Controls: some View {
        VStack(alignment: .leading, spacing: 5) {
            TBDLabel("One brick · ten minutes")
            legendRow(photos.redBrick, "The wall")
            legendRow(photos.tealBrick, "Agent working")
            legendRow(photos.deepBrick, "Running now · selected")
            legendRow(photos.amberBrick, "Waiting on you")
            Toggle("Highlight waiting", isOn: .constant(true)).toggleStyle(TBDSwitchStyle())
            Toggle("Include Portal agents", isOn: .constant(true)).toggleStyle(TBDSwitchStyle())
        }
    }

    // MARK: restored cards

    private var rosterSummary: some View {
        let others = roster.filter { !$0.own }
        func count(_ s: WallAgent.State) -> Int { others.filter { $0.state == s }.count }
        return VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            TBDLabel("Agents in your workspace")
            Text("\(others.count)").font(TBDFonts.nunito(TBDKit.textNumeral, TBDKit.weightHead)).tracking(-1).foregroundStyle(TBDColor.ink)
            HStack(spacing: TBDTokens.Space.xl) {
                metric("\(count(.online))", "online")
                metric("\(count(.paused))", "paused", color: count(.paused) > 0 ? TBDColor.brickInk : nil)
                metric("\(count(.offline))", "offline")
            }
            Text("TBD, your own agent, is always on the wall.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        }
    }

    private func tag(_ a: WallAgent) -> TBDTag {
        switch a.state {
        case .online: TBDTag("Online", status: .live)
        case .paused: TBDTag("Paused", status: .needsYou)
        case .offline: TBDTag("Offline", status: .idle)
        }
    }

    private var rosterList: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
            TBDLabel("Agents")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(WallPlan.ordered(roster)) { a in
                    HStack(spacing: 10) {
                        Image(nsImage: a.own ? photos.deepBrick : a.state == .online ? photos.tealBrick : a.state == .paused ? photos.amberBrick : photos.redBrick)
                            .resizable().scaledToFill().frame(width: 22, height: 8).clipShape(RoundedRectangle(cornerRadius: 1.5)).unredacted()
                        Text(a.name).font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightLabel)).foregroundStyle(TBDColor.ink).lineLimit(1)
                        Text(a.purpose).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(a.harness).font(TBDFonts.mono(10)).foregroundStyle(TBDColor.muted).lineLimit(1)
                        tag(a)
                    }
                    .padding(.horizontal, 6)
                }
            }
        }
    }

    private var rosterLegend: some View {
        VStack(alignment: .leading, spacing: 5) {
            TBDLabel("One brick · one agent")
            legendRow(photos.tealBrick, "Online")
            legendRow(photos.amberBrick, "Paused")
            legendRow(photos.redBrick, "Offline · plain wall")
            legendRow(photos.deepBrick, "TBD · your own agent")
            Toggle("Show offline agents", isOn: .constant(true)).toggleStyle(TBDSwitchStyle())
        }
    }
}

// MARK: - Run

/// Renders A, B and C at 1280x800 and 1600x1000, light and dark, with the rendered contrast audit.
@MainActor func runWallMockups(imagesDir: String) throws {
    let photos = try WallPhotos.load(imagesDir)
    let sizes = [CGSize(width: 1280, height: 800), CGSize(width: 1600, height: 1000)]
    for screen in WallScreen.allCases {
        for size in sizes {
            for dark in [false, true] {
                try render(WallMockup(photos: photos, screen: screen, size: size), size: size, dark: dark,
                           to: "wall-\(screen.rawValue)-\(Int(size.width))x\(Int(size.height))-\(dark ? "dark" : "light")")
            }
        }
    }
}
