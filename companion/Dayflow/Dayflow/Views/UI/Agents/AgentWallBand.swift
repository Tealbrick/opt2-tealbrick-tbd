//
//  AgentWallBand.swift
//  TBD
//
//  The wall band of the Agents page (WP-WALL): the v1 renderer, ported. The red photo is tiled across the band,
//  recoloured bricks are cut from the teal / deep teal / amber photos and clipped to the brick rects (a 1 pt tile overlap
//  stops hairline seams), a contact shadow sits under the wall and the ends fade 5%. Callouts are SwiftUI Text over the
//  Canvas (so the contrast audit and sighted users see them) with a leader and a dot. The page makes the whole wall ONE
//  accessibility element (`.accessibilityElement(children: .ignore)` with one label that counts the agents); the list
//  below it has each agent for VoiceOver. Courses 4 and up label above, the others below. A label is a fixed width of
//  crowding - 12 points and a label within the crowding distance of another on the same side is skipped, so two labels of
//  one side never touch. The four photos are decoded once (`AgentWallPhotoCache`), never per frame.
//

import AppKit
import SwiftUI
import TBDDesign

/// Where everything is on screen for one frame. Pure: the same numbers draw, label and hit-test.
struct AgentWallGeometry {
  static let calloutZone: CGFloat = 56

  let plan: AgentWallPlan
  let width: CGFloat
  let wallHeight: CGFloat
  /// Points the wall has moved (left to right).
  let shift: Double

  var k: CGFloat { wallHeight / CGFloat(AgentWallTile.height) }
  var tile: CGSize { CGSize(width: wallHeight * AgentWallTile.aspect, height: wallHeight) }
  var loop: Double { plan.loopWidth * Double(k) }
  var totalHeight: CGFloat { Self.calloutZone * 2 + wallHeight }
  /// The red tiles' scroll offset: bricks and tiles share it so the shading matches.
  var tileOffset: Double { agentWallPositiveMod(shift, Double(tile.width)) }

  /// Screen rects of one cell, including its repeats around the loop.
  func rects(course: Int, column: Int) -> [CGRect] {
    let x0 = AgentWallPlan.x(course: course, column: column)
    let y = Self.calloutZone + CGFloat(AgentWallTile.brickTop(course: course)) * k
    var base = x0 * Double(k) + agentWallPositiveMod(shift, loop)
    while base > Double(width) { base -= loop }
    var out: [CGRect] = []
    var x = base
    while x > -loop { x -= loop }
    while x < Double(width) + loop {
      let r = CGRect(x: x, y: y, width: AgentWallTile.brickW * Double(k), height: AgentWallTile.brickH * Double(k))
      if r.maxX > -20 && r.minX < width + 20 { out.append(r) }
      x += loop
    }
    return out
  }

  func rects(of brick: WallBrick) -> [CGRect] { brick.columns.flatMap { rects(course: brick.course, column: $0) } }

  func brick(at point: CGPoint) -> WallBrick? {
    plan.bricks.first { rects(of: $0).contains { $0.insetBy(dx: -2, dy: -2).contains(point) } }
  }

  /// The distance between two same-side labels. It follows the brick pitch (two columns is the nearest same-side pair of
  /// the slot rule), between 112 and 160 points: a small wall gets narrower labels instead of lost ones.
  static func crowding(wallHeight: CGFloat) -> CGFloat {
    min(160, max(112, 2 * CGFloat(AgentWallTile.pitch) * wallHeight / CGFloat(AgentWallTile.height)))
  }

  /// The width of a label for a crowding distance.
  static func labelWidth(crowding: CGFloat) -> CGFloat { max(40, crowding - 12) }
  static let labelHeight: CGFloat = 44

  struct Placement: Identifiable {
    /// Agent id + the copy of the loop, so a repeat keeps its identity while the wall scrolls.
    let id: String
    let callout: WallCallout
    let rect: CGRect
    let above: Bool
    let labelY: CGFloat
    let title: String
    let metaLines: [String]
    let labelFrame: CGRect
  }

  /// Courses >= 4 label above, the others below. Two labels on one side need `crowding` points between them; a label is
  /// `crowding - 12` points wide, so two labels of one side never touch.
  func placements(crowding: CGFloat) -> [Placement] {
    var placed: [(side: Int, x: CGFloat)] = []
    var out: [Placement] = []
    let labelWidth = Self.labelWidth(crowding: crowding)
    let ordered = plan.callouts.sorted {
      AgentWallPlan.x(course: $0.course, column: $0.column) < AgentWallPlan.x(course: $1.course, column: $1.column)
    }
    for callout in ordered {
      let x0 = AgentWallPlan.x(course: callout.course, column: callout.column) * Double(k) + shift
      for rect in rects(course: callout.course, column: callout.column) where rect.midX > width * 0.07 && rect.midX + crowding < width * 0.95 {
        let above = callout.course >= 4
        let side = above ? 0 : 1
        if placed.contains(where: { $0.side == side && abs($0.x - rect.midX) < crowding }) { continue }
        placed.append((side, rect.midX))
        let labelY: CGFloat = above ? 4 : Self.calloutZone + wallHeight + 6
        let copy = loop > 0 ? Int(((Double(rect.minX) - x0) / loop).rounded()) : 0
        out.append(
          Placement(
            id: "\(callout.agentID)#\(copy)", callout: callout, rect: rect, above: above, labelY: labelY,
            title: AgentWallLabelText.title(callout.title), metaLines: AgentWallLabelText.metaLines(callout.meta),
            labelFrame: CGRect(x: rect.midX + 6, y: labelY, width: labelWidth, height: Self.labelHeight)))
      }
    }
    return out
  }

  /// True when at least one brick can lose its label somewhere on the endless wall: two same-side bricks of the plan are
  /// closer than `crowding` (also across the end of the loop). The list has every name.
  func hasUnlabelledBricks(crowding: CGFloat) -> Bool {
    guard loop > 0 else { return false }
    for above in [true, false] {
      let xs = plan.callouts.filter { ($0.course >= 4) == above }.map {
        agentWallPositiveMod((AgentWallPlan.x(course: $0.course, column: $0.column) + AgentWallTile.brickW / 2) * Double(k), loop)
      }.sorted()
      guard xs.count > 1, let first = xs.first, let last = xs.last else { continue }
      let gaps = zip(xs, xs.dropFirst()).map { $1 - $0 } + [first + loop - last]
      if gaps.contains(where: { $0 < Double(crowding) }) { return true }
    }
    return false
  }
}

// MARK: - Photos for the wall (decoded once)

/// The four wall photos as CGImages, decoded once for the whole app. `Canvas` resolves an `Image` per frame; resolving a
/// decoded CGImage costs no decode.
final class AgentWallPhotoCache: @unchecked Sendable {
  static let shared = AgentWallPhotoCache()
  private let lock = NSLock()
  private var images: [AgentWallPhoto: CGImage] = [:]

  func cgImage(_ photo: AgentWallPhoto) -> CGImage? {
    lock.lock()
    defer { lock.unlock() }
    if let hit = images[photo] { return hit }
    guard let cg = NSImage(named: photo.assetName)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    images[photo] = cg
    return cg
  }

  func image(_ photo: AgentWallPhoto) -> Image {
    cgImage(photo).map { Image(decorative: $0, scale: 1) } ?? Image(photo.assetName)
  }
}

struct AgentWallBand: View {
  let plan: AgentWallPlan
  let selectedID: String?
  let width: CGFloat
  let wallHeight: CGFloat
  let shift: Double
  /// v1 used 190 pt; the roster labels are short (title + two cut lines), so the roster wall uses 112...160
  /// (`AgentWallGeometry.crowding(wallHeight:)`). A label is `crowding - 12` points wide.
  var crowding: CGFloat = 160

  private var geometry: AgentWallGeometry { AgentWallGeometry(plan: plan, width: width, wallHeight: wallHeight, shift: shift) }

  private var fade: LinearGradient {
    LinearGradient(
      stops: [
        .init(color: .clear, location: 0), .init(color: .black, location: 0.05),
        .init(color: .black, location: 0.95), .init(color: .clear, location: 1),
      ], startPoint: .leading, endPoint: .trailing)
  }

  var body: some View {
    let g = geometry
    let placements = g.placements(crowding: crowding)
    ZStack(alignment: .topLeading) {
      Canvas { context, size in draw(&context, size: size, geometry: g, placements: placements) }
        .mask(fade)
      ForEach(placements) { p in
        VStack(alignment: .leading, spacing: 0) {
          Text(p.title).font(TBDTokens.Typography.label).foregroundStyle(TBDColor.ink).lineLimit(1).truncationMode(.tail)
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(p.metaLines.enumerated()), id: \.offset) { _, line in
              Text(line).font(TBDFonts.mono(10)).foregroundStyle(TBDColor.muted).lineLimit(1).truncationMode(.tail)
            }
          }
          .padding(.top, 2)
        }
        .frame(width: p.labelFrame.width, alignment: .leading)
        .offset(x: p.labelFrame.minX, y: p.labelFrame.minY)
      }
    }
    .frame(width: width, height: g.totalHeight, alignment: .topLeading)
  }

  private func draw(_ context: inout GraphicsContext, size: CGSize, geometry g: AgentWallGeometry, placements: [AgentWallGeometry.Placement]) {
    let wallTop = AgentWallGeometry.calloutZone
    let tile = g.tile
    // Only the photos this frame paints, from the decoded cache.
    let cache = AgentWallPhotoCache.shared
    let red = context.resolve(cache.image(.red))
    var needed = Set(plan.bricks.compactMap { $0.tone.photo })
    if selectedID != nil { needed.insert(.deep) }
    var tones: [AgentWallPhoto: GraphicsContext.ResolvedImage] = [:]
    for photo in needed where photo != .red { tones[photo] = context.resolve(cache.image(photo)) }
    // Soft contact shadow under the wall.
    let shadowTop = wallTop + wallHeight
    context.fill(
      Path(CGRect(x: 0, y: shadowTop, width: size.width, height: 10)),
      with: .linearGradient(
        Gradient(colors: [.black.opacity(0.18), .clear]), startPoint: CGPoint(x: 0, y: shadowTop), endPoint: CGPoint(x: 0, y: shadowTop + 10)))
    // Endless red wall. +1 pt overlap: no hairline seam between tiles.
    let offset = g.tileOffset
    var x = CGFloat(offset) - tile.width
    while x < size.width {
      context.draw(red, in: CGRect(x: x, y: wallTop, width: tile.width + 1, height: tile.height))
      x += tile.width
    }
    // Agent bricks: the same brick, cut from the recoloured render. Offline bricks stay the plain wall.
    for brick in plan.bricks {
      let photo = brick.agentID == selectedID ? AgentWallPhoto.deep : brick.tone.photo
      for rect in g.rects(of: brick) {
        if let photo, let image = tones[photo] {
          context.drawLayer { layer in
            layer.clip(to: Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: TBDKit.radiusSwatch))
            // Tile origin aligned with the red wall so the shading matches exactly.
            var tx = CGFloat(offset) - tile.width
            while tx + tile.width < rect.minX - 2 { tx += tile.width }
            layer.draw(image, in: CGRect(x: tx, y: wallTop, width: tile.width + 1, height: tile.height))
            layer.draw(image, in: CGRect(x: tx + tile.width, y: wallTop, width: tile.width + 1, height: tile.height))
          }
        }
        if brick.agentID == selectedID {
          context.stroke(Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: TBDKit.radiusSwatch), with: .color(TBDColor.ink), lineWidth: 2)
        }
      }
    }
    // Callout leaders and dots.
    for p in placements {
      let start = CGPoint(x: p.rect.midX, y: p.above ? p.rect.minY + 4 : p.rect.maxY - 4)
      let end = CGPoint(x: p.rect.midX, y: p.above ? p.labelY + 33 : p.labelY - 3)
      var leader = Path()
      leader.move(to: start)
      leader.addLine(to: end)
      context.stroke(leader, with: .color(TBDColor.ink.opacity(0.55)), lineWidth: 1)
      let dot = Path(ellipseIn: CGRect(x: start.x - 2.5, y: start.y - 2.5, width: 5, height: 5))
      context.fill(dot, with: .color(.white))
      context.stroke(dot, with: .color(TBDColor.ink.opacity(0.7)), lineWidth: 1)
    }
  }
}

// MARK: - Photos for the swatches

/// One brick cut from each photo: the legend and list swatches (the same bricks as on the wall).
@MainActor
enum AgentWallSwatches {
  private static var cache: [AgentWallPhoto: NSImage] = [:]

  static func image(_ photo: AgentWallPhoto) -> NSImage? {
    if let hit = cache[photo] { return hit }
    guard let source = NSImage(named: photo.assetName) else { return nil }
    let cut = brick(source)
    cache[photo] = cut
    return cut
  }

  /// Course 4, brick 0, inset a few pixels so the joint is not in the swatch. 1 m = 1500 px in the 2700 x 900 photos.
  private static func brick(_ image: NSImage) -> NSImage {
    let ppm = 1500.0
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
    let rect = CGRect(
      x: AgentWallTile.brickX(course: 4, index: 0) * ppm + 8, y: AgentWallTile.brickTop(course: 4) * ppm + 8,
      width: AgentWallTile.brickW * ppm - 16, height: AgentWallTile.brickH * ppm - 16)
    guard let cut = cg.cropping(to: rect) else { return image }
    return NSImage(cgImage: cut, size: NSSize(width: rect.width, height: rect.height))
  }
}
