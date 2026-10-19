//
//  AgentWallModel.swift
//  TBD
//
//  The Agents brick wall (dev.15, WP-WALL, C280 C4, C127): the drawing model and the roster rules. The wall is read-only.
//  It shows one brick per agent of the workspace roster (TBD's own agent first). The model stays generic: a `WallBrick`
//  has a course, a start column and a length, so a later version can map time spans to bricks without changing the
//  renderer. Today every length is 1. Nothing here starts a process or reads a file.
//

import Foundation

// MARK: - Tile geometry (the v1 render: companion/design/agent-wall, metres)

enum AgentWallTile {
  static let bricksPerCourse = 8, courses = 8
  static let pitch = 0.225, course = 0.075, brickW = 0.215, brickH = 0.065, width = 1.8, height = 0.6
  static let aspect = CGFloat(width / height)
  /// The first agents fill the middle courses.
  static let courseOrder = [4, 3, 5, 2, 6, 1, 7, 0]
  /// Left edge (metres) of brick `k` in course `r`, within one tile.
  static func brickX(course r: Int, index k: Int) -> Double {
    Double(k) * pitch + (r % 2 == 1 ? pitch / 2 : 0) + (pitch - brickW) / 2
  }
  /// Top edge (metres from the top of the tile) of course `r`, course 0 at the bottom.
  static func brickTop(course r: Int) -> Double { height - (Double(r) * course + course / 2 + brickH / 2) }
  /// Left edge (metres) of the `g`-th brick of a course, counted along the endless wall.
  static func x(course r: Int, global g: Int) -> Double {
    Double(g / bricksPerCourse) * width + brickX(course: r, index: g % bricksPerCourse)
  }
}

func agentWallPositiveMod(_ value: Double, _ modulus: Double) -> Double {
  guard modulus > 0 else { return 0 }
  let r = value.truncatingRemainder(dividingBy: modulus)
  return r < 0 ? r + modulus : r
}

// MARK: - Agents and tones

enum WallAgentState: String, Equatable {
  case online, paused, offline

  var label: String { rawValue.capitalized }
}

/// What the wall paints for one brick. `.offline` is the plain wall (no recolour).
enum WallTone: Equatable {
  case own, online, paused, offline

  /// The recoloured photo used for this tone; nil for the plain wall.
  var photo: AgentWallPhoto? {
    switch self {
    case .own: return .deep
    case .online: return .teal
    case .paused: return .amber
    case .offline: return nil
    }
  }
}

enum AgentWallPhoto: CaseIterable {
  case red, teal, deep, amber

  var assetName: String {
    switch self {
    case .red: return "AgentWallRed"
    case .teal: return "AgentWallTeal"
    case .deep: return "AgentWallTealdeep"
    case .amber: return "AgentWallAmber"
    }
  }
}

struct WallAgent: Identifiable, Equatable {
  /// The id of TBD's own row in the roster (`runtime == "tbd-default"`).
  static let ownRuntime = "tbd-default"

  let id: String
  let name: String
  let purpose: String
  /// The harness label ("Built in" for TBD's own agent); empty when the card names none.
  let harness: String
  let state: WallAgentState
  let own: Bool

  var tone: WallTone {
    if own { return .own }
    switch state {
    case .online: return .online
    case .paused: return .paused
    case .offline: return .offline
    }
  }

  static var tbd: WallAgent {
    WallAgent(id: ownRuntime, name: "TBD", purpose: "Your own agent", harness: "Built in", state: .online, own: true)
  }
}

// MARK: - The roster (what listAgents answers)

struct AgentWallRoster: Equatable {
  /// TBD's own agent first, then the workspace agents in the order the helper gave them.
  var agents: [WallAgent]
  /// Why the workspace agents are missing (the helper's `rosterNotice` on TBD's row).
  var notice: String?

  static let ownOnly = AgentWallRoster(agents: [.tbd], notice: nil)

  /// Lenient decode of the helper's `[[String: Any]]`. Never throws: a bad row is skipped, a bad field gets a default.
  /// TBD's own row has no `workspace` key. If the answer has none, TBD's agent is added, so it is always on the wall.
  static func decode(_ value: Any?) -> AgentWallRoster {
    let rows = (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    var own: WallAgent?
    var notice: String?
    // First pass: TBD's own row (no `workspace` key), wherever it stands in the answer.
    for row in rows where row["workspace"] as? [String: Any] == nil && row["runtime"] as? String == WallAgent.ownRuntime {
      guard own == nil else { continue }
      let id = clean(row["id"]) ?? clean(row["name"]) ?? ""
      own = WallAgent(
        id: id.isEmpty ? WallAgent.ownRuntime : id, name: clean(row["name"]) ?? "TBD", purpose: "Your own agent",
        harness: "Built in", state: .online, own: true)
      notice = clean(row["rosterNotice"])
    }
    // The own id is taken: a workspace row with the same id (or with the default own id) is dropped.
    var seen: Set<String> = [own?.id ?? WallAgent.ownRuntime, WallAgent.ownRuntime]
    var others: [WallAgent] = []
    for row in rows {
      let workspace = row["workspace"] as? [String: Any]
      if workspace == nil, row["runtime"] as? String == WallAgent.ownRuntime { continue }
      let id = clean(row["id"]) ?? clean(row["name"]) ?? ""
      guard !id.isEmpty, seen.insert(id).inserted else { continue }
      let info = workspace ?? [:]
      others.append(
        WallAgent(
          id: id, name: clean(row["name"]) ?? id, purpose: clean(info["purpose"]) ?? "", harness: clean(info["harness"]) ?? "",
          state: state(info, row: row), own: false))
    }
    return AgentWallRoster(agents: [own ?? .tbd] + others, notice: notice)
  }

  /// `workspace.state`: online | offline | paused. Paused wins over the others (also when a `paused` flag says so);
  /// an unknown or missing state is offline.
  static func state(_ info: [String: Any], row: [String: Any]) -> WallAgentState {
    let text = (info["state"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased()
    if text == "paused" || info["paused"] as? Bool == true || row["paused"] as? Bool == true { return .paused }
    return text == "online" ? .online : .offline
  }

  private static func clean(_ value: Any?) -> String? {
    guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    return text
  }
}

// MARK: - The page state (roster + sign-in)

enum AgentWallMode: Equatable { case signedOut, empty, roster }

struct AgentWallNotice: Equatable {
  let text: String
  /// A failure to load shows in the needs-you tone; the plain hints are neutral.
  let needsYou: Bool
  /// The notice links to Settings › Account.
  let offersAccount: Bool

  static let signedOut = AgentWallNotice(text: "Sign in to Teal Brick to see your workspace agents.", needsYou: false, offersAccount: true)
  static let connect = AgentWallNotice(text: "Connect agents to your workspace in Portal. They appear here.", needsYou: false, offersAccount: false)
}

struct AgentWallState: Equatable {
  var roster = AgentWallRoster.ownOnly
  var signedIn = false
  /// True after the first answer (or failure) for the signed-in account.
  var loaded = false
  /// The account has told whether a session exists. Until then the wall shows TBD alone, with no sign-in notice
  /// (no signed-out flash at launch).
  var sessionChecked = true

  var mode: AgentWallMode {
    if !signedIn { return .signedOut }
    return roster.agents.contains { !$0.own } ? .roster : .empty
  }

  /// Signed out: only TBD's brick and the sign-in notice. Signed in with only TBD: the failure notice if there is one,
  /// else (once loaded) the "Connect agents" notice.
  var notice: AgentWallNotice? {
    switch mode {
    case .signedOut: return sessionChecked ? .signedOut : nil
    case .empty:
      if let text = roster.notice { return AgentWallNotice(text: text, needsYou: true, offersAccount: false) }
      return loaded ? .connect : nil
    case .roster:
      return roster.notice.map { AgentWallNotice(text: $0, needsYou: true, offersAccount: false) }
    }
  }

  /// Signed out shows TBD only, whatever an older answer held.
  var agents: [WallAgent] { mode == .signedOut ? [.tbd] : roster.agents }

  /// Agents that are on the wall and in the list (offline ones leave both when the toggle is off).
  func visible(showOffline: Bool) -> [WallAgent] {
    AgentWallPlan.ordered(agents).filter { showOffline || $0.state != .offline }
  }

  /// The one VoiceOver label of the wall band: "Agents wall: 6 agents, 3 online, 1 paused, 2 offline."
  var wallLabel: String {
    let c = counts
    return "Agents wall: \(c.total) \(c.total == 1 ? "agent" : "agents"), \(c.online) online, \(c.paused) paused, \(c.offline) offline."
  }

  /// Counts include TBD and every state, whatever the toggle says.
  var counts: (total: Int, online: Int, paused: Int, offline: Int) {
    let list = agents
    return (list.count, list.filter { $0.state == .online }.count, list.filter { $0.state == .paused }.count,
            list.filter { $0.state == .offline }.count)
  }
}

// MARK: - The plan (generic bricks)

/// A run of bricks of one course: `length` bricks from `startColumn`. A roster agent is one brick (length 1); a later
/// version can give an agent a span of time.
struct WallBrick: Equatable {
  var course: Int
  var startColumn: Int
  var length: Int
  var tone: WallTone
  var agentID: String

  var columns: Range<Int> { startColumn..<(startColumn + max(1, length)) }
}

struct WallCallout: Equatable {
  let agentID: String
  let course: Int
  /// The column of the first brick; the label hangs from its middle.
  let column: Int
  let title: String
  let meta: String
}

struct AgentWallPlan: Equatable {
  /// The first slot sits at this column of its course, each next slot one column further.
  static let firstColumn = 1, columnSpacing = 1

  let loopColumns: Int
  let bricks: [WallBrick]
  let callouts: [WallCallout]

  var loopWidth: Double { Double(loopColumns / AgentWallTile.bricksPerCourse) * AgentWallTile.width }

  /// TBD's own agent first, then the workspace agents by name (case-insensitive, id breaks a tie).
  static func ordered(_ agents: [WallAgent]) -> [WallAgent] {
    agents.filter(\.own)
      + agents.filter { !$0.own }.sorted {
        let order = $0.name.localizedCaseInsensitiveCompare($1.name)
        return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
      }
  }

  /// Slot `i`: course `courseOrder[i % 8]` (4,3,5,2,6,1,7,0), column `firstColumn + i * columnSpacing`.
  static func slot(_ i: Int) -> (course: Int, column: Int) {
    (AgentWallTile.courseOrder[i % AgentWallTile.courseOrder.count], firstColumn + i * columnSpacing)
  }

  /// The slot of every agent. TBD's own agent is always slot 0. The other agents take the place the slot book gave them
  /// (`order`: first-seen order, absent agents included, so nobody moves when an agent comes or goes). An agent the book
  /// does not know yet goes after the known ones, by name.
  static func slotIndices(_ agents: [WallAgent], order: [String]) -> [String: Int] {
    let ownIDs = Set(agents.filter(\.own).map(\.id))
    let known = order.filter { !ownIDs.contains($0) && $0 != WallAgent.ownRuntime }
    var result: [String: Int] = [:]
    for agent in agents where agent.own { result[agent.id] = 0 }
    let present = Set(agents.filter { !$0.own }.map(\.id))
    var placed = Set<String>()
    for (position, id) in known.enumerated() where present.contains(id) && placed.insert(id).inserted { result[id] = position + 1 }
    var next = known.count + 1
    for agent in ordered(agents.filter { !$0.own && result[$0.id] == nil }) {
      result[agent.id] = next
      next += 1
    }
    return result
  }

  /// One brick per agent. The slot comes from the slot order of ALL agents (see `slotIndices`), so an offline agent keeps
  /// its slot when it is hidden and the wall does not reshuffle when an agent goes on or off line or a new agent comes.
  /// Offline agents get no recolour.
  init(agents: [WallAgent], showOffline: Bool, slotOrder: [String] = []) {
    let slots = Self.slotIndices(agents, order: slotOrder)
    let ordered = agents.sorted { (slots[$0.id] ?? 0) < (slots[$1.id] ?? 0) }
    // The loop is at least three tiles; more slots widen it so two slots of one course never share a column.
    let lastSlot = slots.values.max() ?? 0
    let last = Self.firstColumn + lastSlot * Self.columnSpacing
    loopColumns = max(3, (last + AgentWallTile.bricksPerCourse) / AgentWallTile.bricksPerCourse) * AgentWallTile.bricksPerCourse
    var bricks: [WallBrick] = []
    var callouts: [WallCallout] = []
    for agent in ordered {
      if agent.state == .offline && !showOffline { continue }
      let slot = Self.slot(slots[agent.id] ?? 0)
      bricks.append(WallBrick(course: slot.course, startColumn: slot.column, length: 1, tone: agent.tone, agentID: agent.id))
      // Two short lines, so neighbours one brick apart never touch.
      let meta = [agent.harness, agent.state.rawValue].filter { !$0.isEmpty }.joined(separator: "\n")
      callouts.append(WallCallout(agentID: agent.id, course: slot.course, column: slot.column, title: agent.name, meta: meta))
    }
    self.bricks = bricks
    self.callouts = callouts
  }

  /// The wall x (metres) of the left edge of a cell.
  static func x(course: Int, column: Int) -> Double { AgentWallTile.x(course: course, global: column) }
}

// MARK: - Slot book (first-seen order, kept on this Mac)

/// The first-seen order of the agents, so a brick never moves when another agent comes or goes. Stored in UserDefaults
/// per workspace (`scope` = issuer + workspace; empty = signed out): `agentWallSlotOrder.<scope>` = [agentID] (TBD's own
/// id first), `agentWallSlotSeen.<scope>` = [agentID: last seen, seconds since 1970]. Another workspace never leaves gaps.
/// A new agent goes to the end (several new ones in name order). An agent that leaves keeps its slot for 30 days, then
/// the slot is pruned.
struct AgentWallSlotBook: Equatable {
  static let orderKey = "agentWallSlotOrder"
  static let seenKey = "agentWallSlotSeen"
  static let keepSeconds: TimeInterval = 30 * 86_400

  private(set) var order: [String] = []
  private(set) var lastSeen: [String: TimeInterval] = [:]

  init() {}

  /// The workspace the book belongs to.
  private(set) var scope = ""

  static func orderKey(_ scope: String) -> String { scope.isEmpty ? orderKey : "\(orderKey).\(scope)" }
  static func seenKey(_ scope: String) -> String { scope.isEmpty ? seenKey : "\(seenKey).\(scope)" }

  init(defaults: UserDefaults, scope: String = "") {
    self.scope = scope
    order = (defaults.array(forKey: Self.orderKey(scope)) as? [String]) ?? []
    lastSeen = (defaults.dictionary(forKey: Self.seenKey(scope)) as? [String: Double]) ?? [:]
  }

  func save(to defaults: UserDefaults) {
    defaults.set(order, forKey: Self.orderKey(scope))
    defaults.set(lastSeen, forKey: Self.seenKey(scope))
  }

  /// Merge one roster answer. Call it only with a real answer (not with the failure or the signed-out state).
  mutating func update(with agents: [WallAgent], now: Date) {
    let t = now.timeIntervalSince1970
    let ownIDs = agents.filter(\.own).map(\.id)
    let present = Set(agents.map(\.id))
    var kept: [String] = []
    for id in order where !ownIDs.contains(id) && !kept.contains(id) {
      if present.contains(id) {
        kept.append(id)
      } else {
        // Absent: the clock starts now if it never ran, the slot goes after 30 days.
        let seen = lastSeen[id] ?? t
        lastSeen[id] = seen
        if t - seen < Self.keepSeconds { kept.append(id) }
      }
    }
    for id in present { lastSeen[id] = t }
    let fresh = agents.filter { !$0.own && !kept.contains($0.id) }
    kept += AgentWallPlan.ordered(fresh).map(\.id)
    order = ownIDs + kept
    lastSeen = lastSeen.filter { order.contains($0.key) }
  }
}

// MARK: - Callout text

enum AgentWallLabelText {
  static let titleLimit = 34
  static let harnessLimit = 20

  /// `text` cut to `limit` characters with a final ellipsis.
  static func truncated(_ text: String, limit: Int) -> String {
    text.count > limit ? String(text.prefix(max(0, limit - 1))) + "…" : text
  }

  static func title(_ text: String) -> String { truncated(text, limit: titleLimit) }

  /// The meta lines of a callout ("Codex\npaused"): one `Text` each, the harness cut to about 20 characters.
  static func metaLines(_ meta: String) -> [String] {
    meta.split(separator: "\n", omittingEmptySubsequences: true).map { truncated(String($0), limit: harnessLimit) }
  }
}

// MARK: - Scroll

/// The endless scroll of the wall: 16 points a second, frozen while the pointer is on the wall, dragged by hand.
/// Reduce Motion turns the automatic scroll off; dragging still moves the wall.
struct AgentWallScroll: Equatable {
  static let speed: Double = 16
  var base: Double = 0
  var resumedAt: Date
  var paused = false
  var hovering = false
  var dragStart: Double?

  init(now: Date = Date()) { resumedAt = now }

  func shift(at now: Date, reduceMotion: Bool = false) -> Double {
    paused || reduceMotion ? base : base + now.timeIntervalSince(resumedAt) * Self.speed
  }

  /// The wall moves by itself (the frame clock runs).
  func isMoving(reduceMotion: Bool) -> Bool { !paused && !reduceMotion }

  mutating func hoverMoved(at now: Date, reduceMotion: Bool = false) {
    hovering = true
    if !paused {
      base = shift(at: now, reduceMotion: reduceMotion)
      paused = true
    }
  }

  mutating func hoverEnded(at now: Date) {
    hovering = false
    if paused && dragStart == nil { resume(at: now) }
  }

  mutating func dragChanged(translation: Double, at now: Date, reduceMotion: Bool = false) {
    if dragStart == nil {
      dragStart = shift(at: now, reduceMotion: reduceMotion)
      paused = true
    }
    base = (dragStart ?? 0) + translation
  }

  mutating func dragEnded(at now: Date) {
    dragStart = nil
    if !hovering { resume(at: now) }
  }

  private mutating func resume(at now: Date) {
    resumedAt = now
    paused = false
  }
}

// MARK: - Selection

enum AgentWallSelection {
  /// A click on a brick or a list row: the same agent again clears the selection, an empty spot clears it too.
  static func toggled(current: String?, hit: String?) -> String? {
    guard let hit, hit != current else { return nil }
    return hit
  }

  /// A selection that left the wall (offline hidden, agent gone) is dropped.
  static func valid(_ current: String?, in agents: [WallAgent]) -> String? {
    guard let current, agents.contains(where: { $0.id == current }) else { return nil }
    return current
  }
}
