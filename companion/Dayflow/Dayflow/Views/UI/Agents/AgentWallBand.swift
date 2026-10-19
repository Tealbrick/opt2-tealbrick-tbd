//
//  AgentWallBand.swift
//  TBD
//
//  The wall band of the Agents page (WP-WALL): the v1 renderer, ported. The red photo is tiled across the band,
//  recoloured bricks are cut from the teal / deep teal / amber photos and clipped to the brick rects (a 1 pt tile overlap
//  stops hairline seams), a contact shadow sits under the wall and the ends fade 5%. Callouts are SwiftUI Text over the
//  Canvas (so VoiceOver and the contrast audit can see them) with a leader and a dot. Courses 4 and up label above, the
//  others below; a label within the crowding distance of another on the same side is skipped.
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

  struct Placement {
    let callout: WallCallout
    let rect: CGRect
    let above: Bool
    let labelY: CGFloat
    let title: String
  }

  /// Courses >= 4 label above, the others below. Two labels on one side need `crowding` points between them.
  func placements(crowding: CGFloat) -> [Placement] {
    var placed: [(side: Int, x: CGFloat)] = []
    var out: [Placement] = []
    let ordered = plan.callouts.sorted {
      AgentWallPlan.x(course: $0.course, column: $0.column) < AgentWallPlan.x(course: $1.course, column: $1.column)
    }
    for callout in ordered {
      for rect in rects(course: callout.course, column: callout.column) where rect.midX > width * 0.07 && rect.midX + 240 < width * 0.95 {
        let above = callout.course >= 4
        let side = above ? 0 : 1
        if placed.contains(where: { $0.side == side && abs($0.x - rect.midX) < crowding }) { continue }
        placed.append((side, rect.midX))
        let labelY: CGFloat = above ? 4 : Self.calloutZone + wallHeight + 6
        let title = callout.title.count > 34 ? String(callout.title.prefix(33)) + "…" : callout.title
        out.append(Placement(callout: callout, rect: rect, above: above, labelY: labelY, title: title))
      }
    }
    return out
  }
}

struct AgentWallBand: View {
  let plan: AgentWallPlan
  let selectedID: String?
  let width: CGFloat
  let wallHeight: CGFloat
  let shift: Double
  /// v1 used 190 pt; the roster labels are short (two lines, 26 mono characters at most), so the roster wall uses 160.
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
      ForEach(Array(placements.enumerated()), id: \.offset) { _, p in
        VStack(alignment: .leading, spacing: 0) {
          Text(p.title).font(TBDTokens.Typography.label).foregroundStyle(TBDColor.ink)
          Text(p.callout.meta).font(TBDFonts.mono(10)).foregroundStyle(TBDColor.muted).lineLimit(2).fixedSize().padding(.top, 2)
        }
        .lineLimit(1).fixedSize()
        .offset(x: p.rect.midX + 6, y: p.labelY)
      }
    }
    .frame(width: width, height: g.totalHeight, alignment: .topLeading)
  }

  private func draw(_ context: inout GraphicsContext, size: CGSize, geometry g: AgentWallGeometry, placements: [AgentWallGeometry.Placement]) {
    let wallTop = AgentWallGeometry.calloutZone
    let tile = g.tile
    let red = context.resolve(Image(AgentWallPhoto.red.assetName))
    var tones: [AgentWallPhoto: GraphicsContext.ResolvedImage] = [:]
    for photo in [AgentWallPhoto.teal, .deep, .amber] { tones[photo] = context.resolve(Image(photo.assetName)) }
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
            layer.draw(image, in: CGRect(x: tx + tile.width, y: wallTop, width: tile.width, height: tile.height))
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
