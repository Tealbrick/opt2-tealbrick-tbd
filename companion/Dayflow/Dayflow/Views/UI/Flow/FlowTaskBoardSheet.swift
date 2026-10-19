//
//  FlowTaskBoardSheet.swift
//  TBD
//
//  "Add from Task Board" (F4, mockup flow-add-from-taskboard): the owner's open issues, in progress first, then ready.
//  Each row has a checkbox and an optional time range. Adding makes Flow tasks on this Mac; nothing is written to Task
//  Board. Done in Flow = done on Task Board, only after the person's tap on the Today page.
//

import SwiftUI
import TBDDesign
import TBDModels

struct FlowTaskBoardSheet: View {
  @ObservedObject var planner: FlowPlanner
  var onDone: (String) -> Void
  /// Seeded state for design shots (checked ids and the times typed); the live sheet starts empty.
  @State private var picked: Set<String>
  @State private var times: [String: String]
  @State private var error: String?
  @Environment(\.dismiss) private var dismiss

  init(planner: FlowPlanner, picked: Set<String> = [], times: [String: String] = [:], onDone: @escaping (String) -> Void) {
    self.planner = planner
    self.onDone = onDone
    _picked = State(initialValue: picked)
    _times = State(initialValue: times)
  }

  private var issues: [TBDFlowTaskBoardIssue] {
    TBDFlowTaskBoardList(available: true, issues: planner.taskBoard.issues).pickable
  }
  private var onToday: Set<String> {
    Set(planner.tasks.filter { $0.day == planner.todayKey && $0.status != .cancelled }.compactMap(\.taskBoardID))
  }
  private var count: Int { issues.filter { picked.contains($0.id) && !onToday.contains($0.id) }.count }

  var body: some View {
    VStack(alignment: .leading, spacing: TBDKit.s4) {
      Text("Add from Task Board").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
      Text("Issues assigned to you. TBD keeps the times on this Mac; Task Board has no times.")
        .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).fixedSize(horizontal: false, vertical: true)
      if issues.isEmpty {
        Text("No open issues are assigned to you.").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.inkSoft)
          .padding(.vertical, TBDKit.s4)
      } else {
        ScrollView {
          VStack(spacing: 0) { ForEach(issues) { row($0) } }
        }
        .frame(maxHeight: 360)
      }
      if let error {
        Text(error).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.dangerInk).fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: TBDKit.s2) {
        Button("Add \(count) to today") { add() }.buttonStyle(TBDButtonStyle(.primary)).disabled(count == 0)
        Button("Cancel") { dismiss() }.buttonStyle(TBDButtonStyle(.quiet))
        Spacer(minLength: 0)
        Text("Done in Flow = done on Task Board, after your tap.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
      }
    }
    .padding(TBDKit.s6)
    .frame(width: 720)
    .background(TBDColor.paper)
  }

  private func row(_ issue: TBDFlowTaskBoardIssue) -> some View {
    let added = onToday.contains(issue.id)
    let isPicked = picked.contains(issue.id) && !added
    return VStack(spacing: 0) {
      HStack(spacing: TBDKit.s3) {
        Button {
          if isPicked { picked.remove(issue.id) } else { picked.insert(issue.id) }
          error = nil
        } label: {
          Image(systemName: added ? "checkmark.square" : (isPicked ? "checkmark.square.fill" : "square"))
            .foregroundStyle(isPicked ? TBDColor.tealInk : TBDColor.muted)
        }
        .buttonStyle(.plain).disabled(added)
        .accessibilityLabel(added ? "\(issue.title) is on today's plan" : (isPicked ? "Do not add \(issue.title)" : "Add \(issue.title)"))
        VStack(alignment: .leading, spacing: 2) {
          Text(issue.title).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink).lineLimit(2)
          if !issue.project.isEmpty { Text(issue.project).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted) }
        }
        Spacer(minLength: 0)
        if added {
          TBDTag("On today's plan", status: .idle)
        } else {
          TBDTag(issue.status == .inProgress ? "In progress" : "Ready", status: issue.status == .inProgress ? .live : .idle)
          timeField(issue)
        }
      }
      .padding(.vertical, TBDKit.s3)
      Rectangle().fill(TBDColor.line).frame(height: TBDKit.hair)
    }
  }

  private func timeField(_ issue: TBDFlowTaskBoardIssue) -> some View {
    let binding = Binding(get: { times[issue.id] ?? "" }, set: { times[issue.id] = $0; error = nil })
    return ZStack(alignment: .leading) {
      if (times[issue.id] ?? "").isEmpty {
        Text("No time").foregroundStyle(TBDColor.fieldPlaceholder).accessibilityHidden(true)
      }
      TextField(text: binding, prompt: Text("")) { Text("Time range for \(issue.title)") }
        .textFieldStyle(.plain).foregroundStyle(TBDColor.fieldOn)
    }
    .font(TBDTokens.Typography.control)
    .frame(width: 130, alignment: .leading)
    .padding(.horizontal, TBDKit.s3).frame(minHeight: 34)
    .background(TBDColor.fieldFill, in: TBDBrickShape())
    .overlay(TBDBrickShape().strokeBorder(TBDColor.fieldEdge, lineWidth: TBDKit.hair))
  }

  private func add() {
    let calendar = planner.currentCalendar
    let day = planner.clock
    var chosen: [FlowPlanner.TaskBoardPick] = []
    for issue in issues where picked.contains(issue.id) && !onToday.contains(issue.id) {
      switch TBDFlowTimeRange.parse(times[issue.id] ?? "", day: day, calendar: calendar) {
      case .none: chosen.append(.init(issue: issue, startAt: nil, endAt: nil))
      case .range(let start, let end): chosen.append(.init(issue: issue, startAt: start, endAt: end))
      case .invalid(let message):
        error = "\(issue.title): \(message)"
        return
      }
    }
    do {
      let n = try planner.addFromTaskBoard(chosen)
      onDone("Added \(n) from Task Board.")
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}
