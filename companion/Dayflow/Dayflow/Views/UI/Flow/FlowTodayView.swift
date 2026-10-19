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
  /// Plan vs actual from Companion's timeline (F5).
  @ObservedObject var dayModel: FlowDayModel
  let showsTasklistImport: Bool

  @State private var showPaste = false
  @State private var showAdd = false
  @State private var showTaskBoard = false
  /// The Task Board task whose tick is waiting for "Mark done on Task Board?" (inline).
  @State private var confirmingID: String?
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
      if let text = planner.storeNotice { TBDNotice(text, tone: .needsYou) }
      sourceNotice
      if !plan.isEmpty { FlowDayStripCard(model: dayModel) }
      ForEach(planner.reminders) { reminderRow($0) }
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: TBDKit.s6) {
          planColumn.frame(maxWidth: .infinity, alignment: .leading)
          rightColumn.frame(width: 340)
        }
        .frame(minWidth: 760)
        VStack(alignment: .leading, spacing: TBDKit.s5) {
          planColumn
          rightColumn
        }
      }
    }
    .sheet(isPresented: $showPaste) {
      FlowPasteSheet(planner: planner) { status = $0 }
    }
    .sheet(isPresented: $showAdd) {
      FlowAddTaskSheet(planner: planner) { status = $0 }
    }
    .sheet(isPresented: $showTaskBoard) {
      FlowTaskBoardSheet(planner: planner) { status = $0 }
    }
    .confirmationDialog(
      "TBD reads your Tasklist tasks. It does not change them.", isPresented: $confirmImport, titleVisibility: .visible
    ) {
      Button("Import open tasks") { runImport() }
      Button("Cancel", role: .cancel) {}
    }
  }

  // MARK: Source

  private var onTaskBoard: Bool { planner.taskBoard.isTaskBoard }

  /// The line above the plan: the quiet "Checking" hint, or the reason the list stays on this Mac. None for Task Board.
  @ViewBuilder
  private var sourceNotice: some View {
    if let text = planner.taskBoard.notice {
      if planner.taskBoard.mode == .local(.checking) {
        Text(text).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
      } else {
        TBDNotice(text, tone: .neutral)
      }
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
        Text(planCount).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
      }
      if plan.isEmpty {
        VStack(alignment: .leading, spacing: TBDKit.s1) {
          Text("No tasks for today").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
          Text(onTaskBoard ? "Add from Task Board, paste a plan or add a task." : "Paste a plan or add a task. The list stays on this Mac.")
            .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        }
        .padding(.vertical, TBDKit.s5)
        Rectangle().fill(TBDColor.line).frame(height: TBDKit.hair)
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(plan) { taskRow($0) }
        }
      }
      HStack(spacing: TBDKit.s2) {
        if onTaskBoard { Button("Add from Task Board") { showTaskBoard = true }.buttonStyle(TBDButtonStyle(.secondary)) }
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

  private var planCount: String {
    let base = plan.count == 1 ? "1 task" : "\(plan.count) tasks"
    let fromBoard = plan.filter { $0.source == .taskBoard }.count
    return onTaskBoard && fromBoard > 0 ? base + " · \(fromBoard) from Task Board" : base
  }

  /// "Task Board · TBD", "Only on this Mac" (only while Task Board is the source), or nil.
  private func sourceText(_ task: TBDFlowTask) -> String? {
    if task.source == .taskBoard {
      let project = task.taskBoardProject.flatMap { $0.isEmpty ? nil : $0 }
      return project.map { "Task Board · \($0)" } ?? "Task Board"
    }
    return onTaskBoard ? "Only on this Mac" : nil
  }

  private func tick(_ task: TBDFlowTask) {
    if planner.needsTaskBoardConfirm(task) {
      planner.clearTaskBoardRow(task)
      confirmingID = confirmingID == task.id ? nil : task.id
    } else {
      planner.toggleDone(task)
    }
  }

  private func taskRow(_ task: TBDFlowTask) -> some View {
    let done = task.status == .done
    let isNow = nowTask?.id == task.id
    let ended = TBDFlowSession.isTimeboxEnded(task, now: planner.clock)
    return VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: TBDKit.s3) {
        Button { tick(task) } label: {
          Image(systemName: done ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(done || isNow ? TBDColor.tealInk : TBDColor.muted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          done ? "Mark \(task.title) as not done"
            : planner.needsTaskBoardConfirm(task) ? "Mark \(task.title) as done on Task Board" : "Mark \(task.title) as done")
        VStack(alignment: .leading, spacing: TBDKit.s1) {
          HStack(spacing: TBDKit.s2) {
            Text(task.title).font(TBDTokens.Typography.control).foregroundStyle(done ? TBDColor.muted : TBDColor.ink)
            if isNow { TBDTag("Now", status: .live) }
            if ended { TBDTag("Timebox ended", status: .needsYou) }
          }
          if let line = Self.metaLine(range: Self.timeRange(task), source: sourceText(task)) {
            Text(line).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
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
        rowTrailing(task, done: done)
      }
      .padding(.vertical, TBDKit.s3).padding(.horizontal, TBDKit.s4)
      .background(isNow ? TBDColor.tealWash : Color.clear, in: TBDBrickShape())
      taskBoardExtras(task)
      Rectangle().fill(TBDColor.line).frame(height: TBDKit.hair)
    }
  }

  /// The right side of a plan row: the minutes the timeline put on the task, or "not started". A break row keeps its length.
  @ViewBuilder
  private func rowTrailing(_ task: TBDFlowTask, done: Bool) -> some View {
    if TBDFlowSession.isBreak(task) {
      if task.durationMinutes > 0 {
        Text(Self.duration(task.durationMinutes)).font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted)
      }
    } else {
      let minutes = Int((dayModel.snapshot.minutesPerTask[task.id] ?? 0).rounded())
      Text(minutes > 0 || done ? "\(FlowDayModel.minutesText(Double(minutes))) on plan" : "not started")
        .font(TBDTokens.Typography.label).foregroundStyle(TBDColor.inkSoft)
    }
  }

  // MARK: Task Board row parts (F4)

  /// Under a Task Board row: the inline confirm, the progress of a tap, and "Looks done". Nothing here writes by itself.
  @ViewBuilder
  private func taskBoardExtras(_ task: TBDFlowTask) -> some View {
    let state = planner.taskBoardRows[task.id]
    if task.source == .taskBoard, task.status != .done, task.status != .cancelled {
      VStack(alignment: .leading, spacing: TBDKit.s2) {
        if confirmingID == task.id, state == nil {
          HStack(spacing: TBDKit.s2) {
            Text("Mark done on Task Board?").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
            Spacer(minLength: 0)
            Button("Mark done") { confirmingID = nil; Task { await planner.completeOnTaskBoard(task) } }
              .buttonStyle(TBDButtonStyle(.primary))
            Button("Cancel") { confirmingID = nil }.buttonStyle(TBDButtonStyle(.quiet))
          }
        } else if task.looksDoneAt != nil, state == nil || state.map(Self.isFailure) == true {
          HStack(spacing: TBDKit.s2) {
            TBDTag("Looks done", status: .needsYou)
            Text("The observer thinks this is done.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            Spacer(minLength: 0)
            Button("Mark done on Task Board") { Task { await planner.completeOnTaskBoard(task) } }.buttonStyle(TBDButtonStyle(.primary))
            Button("Not yet") { planner.dismissLooksDone(task) }.buttonStyle(TBDButtonStyle(.quiet))
          }
        }
        switch state {
        case .working?:
          Text("Marking done on Task Board…").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        case .waiting(let message)?:
          HStack(spacing: TBDKit.s2) {
            TBDTag(message, status: .needsYou)
          }
        case .failed(let message)?:
          Text(message).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.dangerInk).fixedSize(horizontal: false, vertical: true)
        case nil:
          EmptyView()
        }
      }
      .padding(.leading, 28).padding(.trailing, TBDKit.s4).padding(.bottom, TBDKit.s3)
    }
  }

  private static func isFailure(_ state: FlowTaskBoardRowState) -> Bool {
    if case .failed = state { return true }
    return false
  }

  // MARK: Right column

  /// The Now card and, when today has tasks, the "Off plan today" card.
  private var rightColumn: some View {
    VStack(alignment: .leading, spacing: TBDKit.s5) {
      nowCard
      if !plan.isEmpty { FlowOffPlanCard(model: dayModel) }
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

  /// "9:40 AM – 11:30 AM · Task Board · TBD", either part alone, or nil.
  static func metaLine(range: String?, source: String?) -> String? {
    switch (range, source) {
    case (let r?, let s?): return r + " · " + s
    case (let r?, nil): return r
    case (nil, let s?): return s
    default: return nil
    }
  }

  /// "45 min", "1 h 10 min".
  static func duration(_ minutes: Int) -> String {
    minutes >= 60 ? (minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min") : "\(minutes) min"
  }
}
