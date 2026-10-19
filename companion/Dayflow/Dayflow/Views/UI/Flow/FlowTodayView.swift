//
//  FlowTodayView.swift
//  TBD
//
//  Flow › Today: the plan list, reminders and the Now card on the local store (mockup "today-local").
//

import SwiftUI
import TBDDesign
import TBDModels

struct FlowTodayView: View {
  @ObservedObject var planner: FlowPlanner
  let showsTasklistImport: Bool

  @State private var showPaste = false
  @State private var showAdd = false
  @State private var confirmImport = false
  @State private var status: String?

  private var day: String { planner.todayKey }
  private var plan: [TBDFlowTask] {
    planner.tasks.filter { $0.day == day && $0.status != .cancelled }
      .sorted { ($0.startAt ?? .distantPast) < ($1.startAt ?? .distantPast) }
  }
  private var nowTask: TBDFlowTask? { TBDFlowSession.nowTask(planner.tasks, day: day, now: planner.clock) }
  private var nextTask: TBDFlowTask? { TBDFlowSession.nextTask(planner.tasks, day: day, now: planner.clock) }

  var body: some View {
    VStack(alignment: .leading, spacing: TBDKit.s5) {
      TBDNotice("Task list from Task Board: available with Task Board. Until then TBD keeps this list on this Mac.", tone: .neutral)
      ForEach(planner.reminders) { reminderRow($0) }
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: TBDKit.s6) {
          planColumn.frame(maxWidth: .infinity, alignment: .leading)
          nowCard.frame(width: 340)
        }
        .frame(minWidth: 760)
        VStack(alignment: .leading, spacing: TBDKit.s5) {
          planColumn
          nowCard
        }
      }
    }
    .sheet(isPresented: $showPaste) {
      FlowPasteSheet(planner: planner) { status = $0 }
    }
    .sheet(isPresented: $showAdd) {
      FlowAddTaskSheet(planner: planner) { status = $0 }
    }
    .confirmationDialog(
      "TBD reads your Tasklist tasks. It does not change them.", isPresented: $confirmImport, titleVisibility: .visible
    ) {
      Button("Import open tasks") { runImport() }
      Button("Cancel", role: .cancel) {}
    }
  }

  // MARK: Reminders

  private func reminderRow(_ reminder: TBDFlowReminder) -> some View {
    HStack(spacing: TBDKit.s3) {
      Image(systemName: "bell").foregroundStyle(TBDColor.statusNeedsYouOn).accessibilityHidden(true)
      Text(reminder.title).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.statusNeedsYouOn)
        .lineLimit(2)
      Spacer(minLength: 0)
      Button("Snooze 5 min") { planner.snooze(reminder, minutes: 5) }.buttonStyle(TBDButtonStyle(.quiet))
      Button("Done") { planner.acknowledge(reminder) }.buttonStyle(TBDButtonStyle(.secondary))
    }
    .padding(.horizontal, TBDKit.s4).padding(.vertical, TBDKit.s2)
    .background(TBDColor.statusNeedsYouFill, in: TBDBrickShape())
    .overlay(TBDBrickShape().strokeBorder(TBDColor.statusNeedsYouEdge, lineWidth: TBDKit.hair))
  }

  // MARK: Plan

  private var planColumn: some View {
    VStack(alignment: .leading, spacing: TBDKit.s3) {
      HStack(alignment: .firstTextBaseline) {
        Text("Plan").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
        Spacer(minLength: 0)
        Text(plan.count == 1 ? "1 task" : "\(plan.count) tasks").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
      }
      if plan.isEmpty {
        VStack(alignment: .leading, spacing: TBDKit.s1) {
          Text("No tasks for today").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
          Text("Paste a plan or add a task. The list stays on this Mac.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        }
        .padding(.vertical, TBDKit.s5)
        Rectangle().fill(TBDColor.line).frame(height: TBDKit.hair)
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(plan) { taskRow($0) }
        }
      }
      HStack(spacing: TBDKit.s2) {
        Button("Paste a plan") { showPaste = true }.buttonStyle(TBDButtonStyle(.secondary))
        Button("Add a task") { showAdd = true }.buttonStyle(TBDButtonStyle(.quiet))
        if showsTasklistImport {
          Button("Import from Tasklist") { confirmImport = true }.buttonStyle(TBDButtonStyle(.quiet))
        }
      }
      if let status {
        Text(status).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.inkSoft).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func taskRow(_ task: TBDFlowTask) -> some View {
    let done = task.status == .done
    let isNow = nowTask?.id == task.id
    let ended = TBDFlowSession.isTimeboxEnded(task, now: planner.clock)
    return VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: TBDKit.s3) {
        Button { planner.toggleDone(task) } label: {
          Image(systemName: done ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(done || isNow ? TBDColor.tealInk : TBDColor.muted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(done ? "Mark \(task.title) as not done" : "Mark \(task.title) as done")
        VStack(alignment: .leading, spacing: TBDKit.s1) {
          HStack(spacing: TBDKit.s2) {
            Text(task.title).font(TBDTokens.Typography.control).foregroundStyle(done ? TBDColor.muted : TBDColor.ink)
            if isNow { TBDTag("Now", status: .live) }
            if ended { TBDTag("Timebox ended", status: .needsYou) }
          }
          if let range = Self.timeRange(task) {
            Text(range).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
          }
          if !task.notes.isEmpty {
            Text(task.notes).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).lineLimit(3)
          }
          ForEach(task.subtasks) { sub in
            Button { planner.toggleSubtask(task, sub) } label: {
              HStack(alignment: .firstTextBaseline, spacing: TBDKit.s2) {
                Image(systemName: sub.done ? "checkmark.square.fill" : "square")
                  .foregroundStyle(sub.done ? TBDColor.tealInk : TBDColor.muted)
                Text(sub.title).font(TBDTokens.Typography.hint).foregroundStyle(sub.done ? TBDColor.muted : TBDColor.inkSoft)
              }
            }
            .buttonStyle(.plain)
          }
        }
        Spacer(minLength: 0)
        if task.durationMinutes > 0 {
          Text(Self.duration(task.durationMinutes)).font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted)
        }
      }
      .padding(.vertical, TBDKit.s3).padding(.horizontal, TBDKit.s4)
      .background(isNow ? TBDColor.tealWash : Color.clear, in: TBDBrickShape())
      Rectangle().fill(TBDColor.line).frame(height: TBDKit.hair)
    }
  }

  // MARK: Now card

  private var nowCard: some View {
    VStack(alignment: .leading, spacing: TBDKit.s3) {
      Text("Now").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted)
      if let focus = planner.focus, focus.isActive {
        Text(focusTitle(focus)).font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
        Text(focusLine(focus)).font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft).monospacedDigit()
        HStack(spacing: TBDKit.s2) {
          if focus.status == .paused {
            Button("Resume") { planner.resumeFocus() }.buttonStyle(TBDButtonStyle(.secondary))
          } else {
            Button("Pause") { planner.pauseFocus() }.buttonStyle(TBDButtonStyle(.secondary))
          }
          Button("Stop") { planner.stopFocus() }.buttonStyle(TBDButtonStyle(.quiet))
          if focus.mode == .focus {
            Button("Break \(planner.settings.breakMinutes) min") { planner.startBreak() }.buttonStyle(TBDButtonStyle(.quiet))
          }
        }
      } else if let task = nowTask {
        Text(task.title).font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
        if let range = Self.timeRange(task) { Text(range).font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft) }
        HStack(spacing: TBDKit.s2) {
          Button("Start focus") { planner.startFocus(task) }.buttonStyle(TBDButtonStyle(.secondary))
          Button("Break \(planner.settings.breakMinutes) min") { planner.startBreak() }.buttonStyle(TBDButtonStyle(.quiet))
        }
      } else {
        Text("Nothing scheduled right now").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
        Text(plan.isEmpty ? "Paste a plan or add a task." : "Your next timebox starts later.")
          .font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft)
        Button("Break \(planner.settings.breakMinutes) min") { planner.startBreak() }.buttonStyle(TBDButtonStyle(.quiet))
      }
      if let notice = planner.notice {
        Text(notice).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.dangerInk).fixedSize(horizontal: false, vertical: true)
      }
      Text(nextTask.map { "Next: \($0.title) at \(Self.clockText($0.startAt))" } ?? "No later task today")
        .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
    }
    .padding(TBDKit.s4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(TBDColor.paper, in: TBDBrickShape())
    .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
  }

  private func focusTitle(_ focus: TBDFlowFocus) -> String {
    if focus.mode == .break { return "Break" }
    return planner.tasks.first { $0.id == focus.taskID }?.title ?? "Focus"
  }

  private func focusLine(_ focus: TBDFlowFocus) -> String {
    let n = focus.remaining(at: planner.clock)
    let clock = String(format: "%d:%02d", n / 60, n % 60)
    let mode = focus.mode == .break ? "Break" : "Focus"
    return focus.status == .paused ? "\(mode) · paused · \(clock) left" : "\(mode) · \(clock) left"
  }

  // MARK: Import

  private func runImport() {
    do {
      let r = try planner.importFromTasklist()
      status = "Imported \(r.imported) task\(r.imported == 1 ? "" : "s") from Tasklist. \(r.alreadyImported) were already here, \(r.ignored) were left out."
    } catch {
      status = error.localizedDescription
    }
  }

  // MARK: Text helpers

  static func clockText(_ date: Date?) -> String {
    date?.formatted(date: .omitted, time: .shortened) ?? ""
  }

  /// "9:40 AM – 11:30 AM", "until 11:30 AM", "from 9:40 AM", or nil for a task without times.
  static func timeRange(_ task: TBDFlowTask) -> String? {
    switch (task.startAt, task.endAt) {
    case (let s?, let e?): return clockText(s) + " – " + clockText(e)
    case (let s?, nil): return "from " + clockText(s)
    case (nil, let e?): return "until " + clockText(e)
    default: return nil
    }
  }

  /// "45 min", "1 h 10 min".
  static func duration(_ minutes: Int) -> String {
    minutes >= 60 ? (minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min") : "\(minutes) min"
  }
}
