//
//  FlowCreatureView.swift
//  TBD
//
//  Plays the creature's HEVC-with-alpha animation clips (Videos/tb_brickie_<palette>_flow_*.mov)
//  in the desktop overlay. One shared player so the overlay controller can
//  finish with an exit clip before the panel fades out.
//
//  Clips are authored on a 1280×768 transparent canvas with the creature's
//  position baked in, but that position differs between clip families (the
//  side peek hugs the right edge, the drop-from-top lands mid-canvas, the
//  listening loop stands further right). Each clip carries an anchor naming
//  its family; when a variant chains clips from different families the layer
//  view shifts the canvas by the anchor difference so hand-offs don't jump.
//

import AVFoundation
import AppKit
import SwiftUI

enum FlowCreatureClip: String, CaseIterable {
  // Side layout: pops in past the right edge, waves, leaves.
  case entrance = "flow_entrance"
  case waveLoop = "flow_wave_loop"
  case sideToFull = "flow_side_to_full"
  case exitWave1 = "flow_exit_wave1"
  case exitWave2 = "flow_exit_wave2"
  case exitMove1 = "flow_exit_move1"
  case exitMove2 = "flow_exit_move2"
  // Full body, standing (listening pose).
  case listen1 = "flow_listen1"
  case listen2 = "flow_listen2"
  case exitPlane = "flow_exit_plane"
  case fireBegin = "flow_fire_begin"
  case fireLoop = "flow_fire_loop"
  case fireEnd = "flow_fire_end"
  // Drop from the top edge and land; the copter exit starts where it lands.
  case dropFromTop = "flow_drop_from_top"
  case exitCopter = "flow_exit_copter"
  // Half-body hanging down from the top edge.
  case peekEnter = "flow_peek_enter"
  case peekWaveLoop = "flow_peek_wave_loop"
  case peekExit = "flow_peek_exit"
  // Break: drags out a tub.
  case bathBegin = "flow_bath_begin"
  case bathLoop = "flow_bath_loop"
  case bathEnd = "flow_bath_end"

  /// The only character with clips. (impy and ottie have none, so TBD does not offer them.)
  static let character = "brickie"

  /// Bundle resource name for a palette: `tb_brickie_teal_flow_entrance`.
  func stem(palette: TealbrickPalette) -> String {
    "tb_\(Self.character)_\(palette.rawValue)_\(rawValue)"
  }

  /// The bundled clip for a palette. nil when it is missing: the creature fails soft (no clip, no crash, no fallback
  /// to another set).
  func url(palette: TealbrickPalette = .current, in bundle: Bundle = .main) -> URL? {
    bundle.url(forResource: stem(palette: palette), withExtension: "mov")
  }

  var url: URL? { url() }

  /// The exit clips the side layout picks from.
  static let sideExits: [FlowCreatureClip] = [.exitWave1, .exitWave2, .exitMove1, .exitMove2]

  static var randomExit: FlowCreatureClip {
    sideExits.randomElement() ?? .exitWave1
  }

  static var randomListen: FlowCreatureClip {
    [.listen1, .listen2].randomElement() ?? .listen1
  }

  /// Canvas point (1280×768 space) the creature is planted at in this clip:
  /// the foot of the side peek, the landing spot, the standing spot, or the
  /// top of the hanging half-body.
  enum Anchor {
    case side, land, stand, peek, tub

    var point: CGPoint {
      switch self {
      case .side: return CGPoint(x: 1280, y: 512)
      case .land: return CGPoint(x: 671, y: 447)
      case .stand: return CGPoint(x: 990, y: 527)
      case .peek: return CGPoint(x: 636, y: 0)
      case .tub: return .zero
      }
    }
  }

  var anchor: Anchor {
    switch self {
    case .entrance, .waveLoop, .sideToFull, .exitWave1, .exitWave2, .exitMove1, .exitMove2:
      return .side
    case .listen1, .listen2, .exitPlane, .fireBegin, .fireLoop, .fireEnd:
      return .stand
    case .dropFromTop, .exitCopter:
      return .land
    case .peekEnter, .peekWaveLoop, .peekExit:
      return .peek
    case .bathBegin, .bathLoop, .bathEnd:
      return .tub
    }
  }

  /// How far to shift the rendered canvas (in canvas pixels) so this clip's
  /// anchor lands where the variant's base clip put the creature. The side
  /// and peek variants only chain clips from one family, so they never shift.
  func canvasOffset(in variant: FlowNudgeVariant) -> CGPoint {
    guard variant == .top, anchor == .stand else { return .zero }
    let base = Anchor.land.point
    return CGPoint(x: base.x - anchor.point.x, y: base.y - anchor.point.y)
  }
}

@MainActor
final class FlowCreaturePlayer {
  static let shared = FlowCreaturePlayer()

  /// A queue player so the next clip (or the next copy of the loop) is
  /// already loaded when the current one ends. Swapping items on a plain
  /// AVPlayer left a blank frame at every hand-off, which read as a flicker.
  let player = AVQueuePlayer()

  private(set) var currentClip: FlowCreatureClip?
  /// Fired whenever the clip changes so the layer view can re-anchor it.
  var onClipChange: ((FlowCreatureClip?) -> Void)?
  private var loopClip: FlowCreatureClip?
  private var onceCompletion: (() -> Void)?
  /// Bumped per play request so a stale timeout can't fire a completion.
  private var playGeneration = 0
  /// Which clip each queued item plays, so the queue advancing can update
  /// `currentClip` (and the canvas anchor) at the exact hand-off.
  private var clipsByItem: [ObjectIdentifier: FlowCreatureClip] = [:]
  private var currentItemObservation: NSKeyValueObservation?

  private init() {
    player.actionAtItemEnd = .advance
    NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
    ) { [weak self] note in
      MainActor.assumeIsolated {
        self?.itemEnded(note)
      }
    }
    currentItemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
      MainActor.assumeIsolated {
        self?.currentItemChanged()
      }
    }
  }

  /// Play `clip` once, then keep looping `loop` (pass the same clip to loop
  /// it from the start).
  func play(_ clip: FlowCreatureClip, thenLoop loop: FlowCreatureClip?) {
    playGeneration += 1
    onceCompletion = nil
    loopClip = loop
    startQueue(with: clip)
    if let loop { enqueue(loop) }
  }

  /// If `loop` is already what's playing (or queued to loop), leave it alone;
  /// otherwise switch to it. Keeps the wave loop from restarting every time
  /// the overlay content changes.
  func ensureLoop(_ loop: FlowCreatureClip) {
    if currentClip == loop || loopClip == loop { return }
    play(loop, thenLoop: loop)
  }

  /// Play a one-shot clip (exit animations); calls `completion` when it ends,
  /// or after a safety timeout if playback stalls.
  func playOnce(_ clip: FlowCreatureClip, completion: @escaping () -> Void) {
    playGeneration += 1
    let gen = playGeneration
    loopClip = nil
    onceCompletion = completion
    startQueue(with: clip)

    // Longest exit clip is ~7s; anything past 10s means playback stalled.
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 10_000_000_000)
      guard gen == self.playGeneration, let pending = self.onceCompletion else { return }
      self.onceCompletion = nil
      pending()
    }
  }

  func refreshAppearance() {
    guard onceCompletion == nil, let clip = currentClip else { return }
    // Restart the current sequence with the new bundled character/palette.
    play(clip, thenLoop: loopClip)
  }

  private func startQueue(with clip: FlowCreatureClip) {
    guard clip.url != nil else {
      // Missing resource: fail soft, run any pending completion.
      let pending = onceCompletion
      onceCompletion = nil
      currentClip = nil
      onClipChange?(nil)
      pending?()
      return
    }
    player.pause()
    player.removeAllItems()
    clipsByItem.removeAll()
    currentClip = clip
    onClipChange?(clip)
    enqueue(clip)
    player.play()
  }

  @discardableResult
  private func enqueue(_ clip: FlowCreatureClip) -> AVPlayerItem? {
    guard let url = clip.url else { return nil }
    let item = AVPlayerItem(url: url)
    guard player.canInsert(item, after: nil) else { return nil }
    clipsByItem[ObjectIdentifier(item)] = clip
    player.insert(item, after: nil)
    return item
  }

  private func currentItemChanged() {
    guard let item = player.currentItem, let clip = clipsByItem[ObjectIdentifier(item)] else {
      return
    }
    if clip != currentClip {
      currentClip = clip
      onClipChange?(clip)
    }
    // Keep one spare copy of the loop queued so it never runs dry.
    if let loopClip, clip == loopClip, player.items().count < 2 {
      enqueue(loopClip)
    }
    // Drop bookkeeping for items that already played.
    let live = Set(player.items().map { ObjectIdentifier($0) })
    clipsByItem = clipsByItem.filter { live.contains($0.key) }
  }

  private func itemEnded(_ note: Notification) {
    guard let item = note.object as? AVPlayerItem, clipsByItem[ObjectIdentifier(item)] != nil else {
      return
    }
    if let pending = onceCompletion, player.items().count <= 1 {
      onceCompletion = nil
      pending()
    }
  }
}

/// Hosts the shared player's AVPlayerLayer with a transparent background,
/// re-anchoring the canvas per clip for the current variant.
struct FlowCreatureVideoView: NSViewRepresentable {
  let variant: FlowNudgeVariant

  func makeNSView(context: Context) -> FlowCreatureLayerView {
    let view = FlowCreatureLayerView(player: FlowCreaturePlayer.shared.player)
    view.variant = variant
    FlowCreaturePlayer.shared.onClipChange = { [weak view] clip in
      view?.clip = clip
    }
    view.clip = FlowCreaturePlayer.shared.currentClip
    return view
  }

  func updateNSView(_ nsView: FlowCreatureLayerView, context: Context) {
    nsView.variant = variant
  }
}

final class FlowCreatureLayerView: NSView {
  private static let canvasSize = CGSize(width: 1280, height: 768)
  private let playerLayer = AVPlayerLayer()

  var variant: FlowNudgeVariant = .side {
    didSet { needsLayout = true }
  }
  var clip: FlowCreatureClip? {
    didSet { needsLayout = true }
  }

  init(player: AVPlayer) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = .clear
    layer?.masksToBounds = false
    playerLayer.player = player
    playerLayer.videoGravity = .resizeAspect
    playerLayer.backgroundColor = .clear
    layer?.addSublayer(playerLayer)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // Top-left coordinates so canvas offsets read the same as the clip data.
  override var isFlipped: Bool { true }

  override func layout() {
    super.layout()
    let scale = bounds.width / Self.canvasSize.width
    let offset = clip?.canvasOffset(in: variant) ?? .zero
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    playerLayer.frame = bounds.offsetBy(dx: offset.x * scale, dy: offset.y * scale)
    CATransaction.commit()
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
