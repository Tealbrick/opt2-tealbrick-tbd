//
//  SettingsLocalChoicesView.swift
//  TBD
//
//  Settings › Access, "Your choices for TBD's agent on this Mac" (dev.17, C280 C13 local part). The remembered Always / Never
//  answers for TBD's agent's shell commands, file writes and web requests, each with Remove. The words are in TBDLocalChoices;
//  the pane reads through `LocalChoicesStore`. Choices for connected accounts are in Settings › Connectors.
//

import AppKit
import SwiftUI
import TBDDesign
import TBDModels

struct SettingsLocalChoicesView: View {
  @ObservedObject private var store: LocalChoicesStore

  @MainActor
  init(store: LocalChoicesStore? = nil) {
    _store = ObservedObject(wrappedValue: store ?? .shared)
  }

  var body: some View {
    let state = store.state
    VStack(alignment: .leading, spacing: TBDKit.s3) {
      Rectangle().fill(TBDColor.line).frame(height: TBDKit.hair).padding(.bottom, TBDKit.s2)
      Text(TBDLocalChoices.title)
        .font(TBDTokens.Typography.title)
        .foregroundStyle(TBDColor.ink)
      Text(TBDLocalChoices.note)
        .font(TBDTokens.Typography.hint)
        .foregroundStyle(TBDColor.muted)
        .fixedSize(horizontal: false, vertical: true)
      if let issue = state.issue {
        TBDNotice(TBDLocalChoices.line(issue), tone: .needsYou)
      }
      if state.choices.isEmpty {
        // A failed read is not "no choices": only an answer of an empty list says that.
        if state.issue != .failed && state.loaded {
          Text(TBDLocalChoices.emptyLine)
            .font(TBDTokens.Typography.hint)
            .foregroundStyle(TBDColor.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(state.choices.enumerated()), id: \.element.id) { index, choice in
            choiceRow(choice, last: index == state.choices.count - 1)
          }
        }
      }
      if store.removeFailed {
        TBDNotice(TBDLocalChoices.removeFailedLine, tone: .needsYou)
      }
      Text(TBDLocalChoices.connectorsLine)
        .font(TBDTokens.Typography.hint)
        .foregroundStyle(TBDColor.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
    .background(AgentWallWindowObserver { visible in store.windowVisibilityChanged(visible) })
    .onAppear { store.pageDidAppear() }
    .onDisappear { store.pageDidDisappear() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      store.appDidBecomeActive()
    }
  }

  private func choiceRow(_ choice: TBDLocalChoice, last: Bool) -> some View {
    SettingsRow(label: choice.text(), showsDivider: !last) {
      Button("Remove") {
        Task { _ = await store.remove(choice) }
      }
      .buttonStyle(TBDButtonStyle(.secondary))
      .pointingHandCursor()
      .accessibilityLabel(Text("Remove: \(choice.text())"))
    }
  }
}
