//
//  FlowPlanSheets.swift
//  TBD
//
//  Flow's two input sheets: "Paste a plan" (preview, then save) and "Add a task".
//

import SwiftUI
import TBDDesign
import TBDModels

/// A multi-line text box in the kit's field look.
struct FlowTextArea: View {
  @Binding var text: String
  var height: CGFloat = 140
  var monospaced = false

  var body: some View {
    TextEditor(text: $text)
      .font(monospaced ? TBDTokens.Typography.mono : TBDFonts.nunito(TBDKit.textControl, TBDKit.weightBody))
      .foregroundStyle(TBDColor.fieldOn)
      .scrollContentBackground(.hidden)
      .padding(TBDKit.s2)
      .frame(height: height)
      .background(TBDColor.fieldFill, in: TBDBrickShape())
      .overlay(TBDBrickShape().strokeBorder(TBDColor.fieldEdge, lineWidth: TBDKit.hair))
  }
}

enum FlowDayKey {
  static func key(_ date: Date, calendar: Calendar) -> String { TBDFlowDay.string(from: date, calendar: calendar) }

  /// `time` (hour and minute) placed on the calendar day of `day`.
  static func combine(day: Date, time: Date, calendar: Calendar) -> Date {
    let t = calendar.dateComponents([.hour, .minute], from: time)
    return calendar.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: 0, of: day) ?? day
  }
}

// MARK: - Paste a plan

struct FlowPasteSheet: View {
  @ObservedObject var planner: FlowPlanner
  /// Told what happened ("Saved 4 tasks.") so the page can show it after the sheet closes.
  var onDone: (String) -> Void
  @Environment(\.dismiss) private var dismiss

  @State private var text = ""
  @State private var day = Date()
  @State private var preview: TBDFlowPlanPreview?
  @State private var error: String?
  /// One key per text and day: a second tap on "Save" cannot add the tasks twice, and a changed text starts a new plan.
  @State private var importKey = UUID().uuidString

  private var calendar: Calendar { planner.currentCalendar }
  private var dayKey: String { FlowDayKey.key(day, calendar: calendar) }

  var body: some View {
    VStack(alignment: .leading, spacing: TBDKit.s4) {
      Text("Paste a plan").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
      Text("One task per line: 09:00-10:00 Title, or TODO Title. Indent \"- \" for subtasks and \"> \" for notes. Times use \(TimeZone.current.identifier).")
        .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).fixedSize(horizontal: false, vertical: true)
      HStack(spacing: TBDKit.s3) {
        Text("Day").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
        DatePicker("Day", selection: $day, displayedComponents: .date).labelsHidden()
        Spacer(minLength: 0)
      }
      FlowTextArea(text: $text, height: 150, monospaced: true)
      if let error {
        Text(error).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.dangerInk).fixedSize(horizontal: false, vertical: true)
      }
      if let preview { previewList(preview) }
      HStack(spacing: TBDKit.s2) {
        if let preview, !preview.drafts.isEmpty {
          Button("Save \(preview.drafts.count) task\(preview.drafts.count == 1 ? "" : "s")") { save(preview) }
            .buttonStyle(TBDButtonStyle(.primary))
          Button("Preview again") { runPreview() }.buttonStyle(TBDButtonStyle(.quiet))
        } else {
          Button("Preview") { runPreview() }.buttonStyle(TBDButtonStyle(.primary))
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Button("Cancel") { dismiss() }.buttonStyle(TBDButtonStyle(.quiet))
      }
    }
    .padding(TBDKit.s6)
    .frame(width: 560)
    .background(TBDColor.paper)
    .onChange(of: text) { reset() }
    .onChange(of: day) { reset() }
  }

  private func reset() {
    preview = nil
    error = nil
    importKey = UUID().uuidString
  }

  private func runPreview() {
    error = nil
    do {
      preview = try planner.previewPlan(text: text, day: dayKey)
    } catch {
      preview = nil
      self.error = error.localizedDescription
    }
  }

  private func save(_ preview: TBDFlowPlanPreview) {
    do {
      let result = try planner.commitPlan(preview, text: text, day: dayKey, idempotencyKey: importKey)
      let n = result.taskIDs.count
      onDone((result.replayed ? "Already saved: " : "Saved ") + "\(n) task\(n == 1 ? "" : "s").")
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func previewList(_ preview: TBDFlowPlanPreview) -> some View {
    VStack(alignment: .leading, spacing: TBDKit.s2) {
      HStack(spacing: TBDKit.s2) {
        Text("TBD understood").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted)
        TBDTag(preview.engine == .strict ? "Agent format" : "Guessed from a list", status: preview.engine == .strict ? .live : .needsYou)
      }
      if preview.requiresReview {
        Text("Check the times before you save." + (preview.strictError.map { " Not in the agent format: \($0)" } ?? ""))
          .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.inkSoft).fixedSize(horizontal: false, vertical: true)
      }
      ForEach(Array(preview.drafts.enumerated()), id: \.offset) { index, draft in
        HStack(alignment: .firstTextBaseline, spacing: TBDKit.s3) {
          Text("\(index + 1).").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
          VStack(alignment: .leading, spacing: 2) {
            Text(draft.title).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
            if let start = draft.startAt {
              Text(
                FlowTodayView.clockText(start) + (draft.endAt.map { " – " + FlowTodayView.clockText($0) } ?? "")
                  + (draft.durationMinutes > 0 ? " · " + FlowTodayView.duration(draft.durationMinutes) : "")
              )
              .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            } else {
              Text("No time").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            }
          }
        }
      }
      ForEach(preview.warnings, id: \.self) { warning in
        Text(warning).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.statusNeedsYouOn).fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(TBDKit.s3)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(TBDColor.tile, in: TBDBrickShape())
    .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
  }
}

// MARK: - Add a task

struct FlowAddTaskSheet: View {
  @ObservedObject var planner: FlowPlanner
  var onDone: (String) -> Void
  @Environment(\.dismiss) private var dismiss

  @State private var title = ""
  @State private var notes = ""
  @State private var day = Date()
  @State private var hasTime = false
  @State private var start = Date()
  @State private var end = Date().addingTimeInterval(30 * 60)
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: TBDKit.s4) {
      Text("Add a task").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
      TBDField("Title", text: $title, prompt: "What do you want to get done?", error: error)
      HStack(spacing: TBDKit.s3) {
        Text("Day").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
        DatePicker("Day", selection: $day, displayedComponents: .date).labelsHidden()
        Spacer(minLength: 0)
      }
      HStack(spacing: TBDKit.s3) {
        Toggle(isOn: $hasTime) { EmptyView() }.toggleStyle(TBDSwitchStyle()).labelsHidden().accessibilityLabel("Set a timebox")
        Text("Timebox").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
        if hasTime {
          DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute).labelsHidden()
          Text("to").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
          DatePicker("End", selection: $end, displayedComponents: .hourAndMinute).labelsHidden()
        }
        Spacer(minLength: 0)
      }
      Text("Notes (optional)").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
      FlowTextArea(text: $notes, height: 80)
      HStack(spacing: TBDKit.s2) {
        Button("Add task") { add() }.buttonStyle(TBDButtonStyle(.primary))
          .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Cancel") { dismiss() }.buttonStyle(TBDButtonStyle(.quiet))
      }
    }
    .padding(TBDKit.s6)
    .frame(width: 520)
    .background(TBDColor.paper)
    .onChange(of: title) { error = nil }
  }

  private func add() {
    let calendar = planner.currentCalendar
    let from = hasTime ? FlowDayKey.combine(day: day, time: start, calendar: calendar) : nil
    let to = hasTime ? FlowDayKey.combine(day: day, time: end, calendar: calendar) : nil
    do {
      let task = try planner.addTask(
        title: title.trimmingCharacters(in: .whitespacesAndNewlines), notes: notes,
        day: FlowDayKey.key(day, calendar: calendar), startAt: from, endAt: to)
      onDone("Added: \(task.title)")
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}
