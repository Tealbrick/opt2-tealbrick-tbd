//
//  FlowScreenSource.swift
//  TBD
//
//  Where the observer gets the screen from. The protocol keeps ScreenCaptureKit and Vision out of the tests: the
//  XCTest host never runs the real source (the tests inject a fake). Port of v1 `captureScreenshotJPEG` and
//  `recognizeScreenText`.
//

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

protocol FlowScreenSource: Sendable {
  /// Writes one JPEG of the main display to `url`, `height` pixels high.
  func capture(to url: URL, height: Int, quality: Double) async throws
  /// The text Apple Vision reads in the JPEG at `url` (text mode). Never the image itself.
  func recognizeText(at url: URL) -> String
}

enum FlowScreenText {
  /// OCR lines below this confidence are dropped.
  static let minimumConfidence: Float = 0.3
  static let maximumCharacters = 4000

  /// v1: lines with confidence >= 0.3, joined, cut at 4000 characters, with a fallback line when nothing was read.
  static func format(_ blocks: [(text: String, confidence: Float)]) -> String {
    let lines = blocks.filter { $0.confidence >= minimumConfidence }.map(\.text)
    var text = lines.joined(separator: "\n")
    if text.count > maximumCharacters {
      text = String(text.prefix(maximumCharacters)) + "\n[truncated]"
    }
    return text.isEmpty ? String(localized: "[no text detected on screen]") : text
  }
}

/// ScreenCaptureKit + Apple Vision. Needs Screen Recording (TBD asks for it in setup). Not used in tests.
struct FlowSystemScreenSource: FlowScreenSource {
  func capture(to url: URL, height: Int, quality: Double) async throws {
    // A check that does not prompt: without the permission the observer says so instead of showing a system dialog.
    guard CGPreflightScreenCaptureAccess() else {
      throw NSError(
        domain: "FlowObserver", code: -3,
        userInfo: [
          NSLocalizedDescriptionKey: "TBD cannot see the screen. Allow Screen Recording for TBD in System Settings."
        ])
    }
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first else {
      throw NSError(
        domain: "FlowObserver", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
    }
    let configuration = SCStreamConfiguration()
    let aspectRatio = Double(display.width) / Double(max(1, display.height))
    configuration.height = height
    configuration.width = Int(Double(height) * aspectRatio)
    configuration.scalesToFit = true
    configuration.showsCursor = true
    let image = try await SCScreenshotManager.captureImage(
      contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration)
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
      throw NSError(
        domain: "FlowObserver", code: -2, userInfo: [NSLocalizedDescriptionKey: "JPEG conversion failed"])
    }
    try jpeg.write(to: url, options: .atomic)
  }

  func recognizeText(at url: URL) -> String {
    let blocks = (try? AppleVisionClaudeFrameTextRecognizer().recognizeText(in: url)) ?? []
    return FlowScreenText.format(blocks.map { ($0.text, $0.confidence) })
  }
}
