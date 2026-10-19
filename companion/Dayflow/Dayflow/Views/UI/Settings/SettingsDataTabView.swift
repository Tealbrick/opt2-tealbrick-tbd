import TBDDesign
import SwiftUI

struct SettingsDataTabView: View {
  @ObservedObject var viewModel: OtherSettingsViewModel
  @State private var activeExportDatePicker: ExportDatePicker?
  @State private var isReprocessDatePickerExpanded = false

  private enum ExportDatePicker {
    case start
    case end
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
      exportSection
      reprocessSection
    }
  }

  // MARK: - Export

  private var exportSection: some View {
    let rangeInvalid =
      timelineDisplayDate(from: viewModel.exportStartDate)
      > timelineDisplayDate(from: viewModel.exportEndDate)

    return SettingsSection(
      title: "",   // the pane header "Export" names it
      isFirst: true
    ) {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .center, spacing: 10) {
          datePill(
            label: String(localized: "From"),
            date: viewModel.exportStartDate,
            isExpanded: activeExportDatePicker == .start,
            accessibilityLabel: String(localized: "Export start date"),
            onTap: {
              withAnimation(TBDMotion.quick) {
                activeExportDatePicker = activeExportDatePicker == .start ? nil : .start
                isReprocessDatePickerExpanded = false
              }
            }
          )

          Image(systemName: "arrow.right")
            .font(TBDFonts.symbol(12))
            .foregroundStyle(TBDColor.muted)

          datePill(
            label: String(localized: "To"),
            date: viewModel.exportEndDate,
            isExpanded: activeExportDatePicker == .end,
            accessibilityLabel: String(localized: "Export end date"),
            onTap: {
              withAnimation(TBDMotion.quick) {
                activeExportDatePicker = activeExportDatePicker == .end ? nil : .end
                isReprocessDatePickerExpanded = false
              }
            }
          )
        }

        if let activeExportDatePicker {
          inlineCalendar(
            date: exportDateBinding(for: activeExportDatePicker),
            onDateSelected: {
              withAnimation(TBDMotion.quick) {
                self.activeExportDatePicker = nil
              }
            }
          )
          .transition(.move(edge: .top).combined(with: .opacity))
        }

        Text(
          "Use Markdown exports to archive in Notion, share with teammates, or paste into ChatGPT / Claude / Gemini for deeper analysis."
        )
        .font(TBDTokens.Typography.hint)
        .foregroundStyle(TBDColor.muted)
        .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 12) {
          SettingsPrimaryButton(
            title: viewModel.isExportingTimelineRange
              ? String(localized: "Exporting…") : String(localized: "Export as Markdown"),
            systemImage: viewModel.isExportingTimelineRange ? nil : "square.and.arrow.down",
            isLoading: viewModel.isExportingTimelineRange,
            isDisabled: rangeInvalid,
            action: viewModel.exportTimelineRange
          )

          if rangeInvalid {
            TBDTag(String(localized: "Start must be on or before end."), status: .needsYou)
          }
        }

        if let message = viewModel.exportStatusMessage {
          TBDNotice(message, tone: .live)
        }

        if let error = viewModel.exportErrorMessage {
          TBDNotice(error, tone: .needsYou)
        }
      }
    }
  }

  // MARK: - Reprocess day

  private var reprocessSection: some View {
    let normalizedDate = timelineDisplayDate(from: viewModel.reprocessDayDate)
    let dayString = DateFormatter.yyyyMMdd.string(from: normalizedDate)

    return SettingsSection(
      title: String(localized: "Reprocess day"),
      subtitle: String(localized: "Re-run analysis for every batch on one timeline day.")
    ) {
      VStack(alignment: .leading, spacing: 14) {
        datePill(
          label: String(localized: "Day"),
          date: viewModel.reprocessDayDate,
          isExpanded: isReprocessDatePickerExpanded,
          accessibilityLabel: String(localized: "Reprocess day"),
          disabled: viewModel.isReprocessingDay,
          onTap: {
            withAnimation(TBDMotion.quick) {
              isReprocessDatePickerExpanded.toggle()
              activeExportDatePicker = nil
            }
          }
        )

        if isReprocessDatePickerExpanded {
          inlineCalendar(
            date: $viewModel.reprocessDayDate,
            disabled: viewModel.isReprocessingDay,
            onDateSelected: {
              withAnimation(TBDMotion.quick) {
                isReprocessDatePickerExpanded = false
              }
            }
          )
          .transition(.move(edge: .top).combined(with: .opacity))
        }

        Text(dayString)
          .font(TBDFonts.mono(13))
          .foregroundStyle(TBDColor.muted)

        VStack(alignment: .leading, spacing: 4) {
          Text(
            "Clears existing cards and observations for that day, then runs analysis again from the original recordings."
          )
          .font(TBDTokens.Typography.hint)
          .foregroundStyle(TBDColor.muted)
          .fixedSize(horizontal: false, vertical: true)

          Text("Heads up: this can consume a large number of API calls.")
            .font(TBDTokens.Typography.label)
            .foregroundStyle(TBDColor.ink)
        }

        HStack(spacing: 12) {
          SettingsPrimaryButton(
            title: viewModel.isReprocessingDay
              ? String(localized: "Reprocessing…") : String(localized: "Reprocess day"),
            systemImage: viewModel.isReprocessingDay ? nil : "arrow.clockwise",
            isLoading: viewModel.isReprocessingDay,
            prominent: false,
            action: { viewModel.showReprocessDayConfirm = true }
          )

          if let status = viewModel.reprocessStatusMessage {
            Text(status)
              .font(TBDTokens.Typography.hint)
              .foregroundStyle(TBDColor.muted)
          }
        }

        if let error = viewModel.reprocessErrorMessage {
          TBDNotice(error, tone: .needsYou)
        }
      }
      .alert("Reprocess day?", isPresented: $viewModel.showReprocessDayConfirm) {
        Button("Cancel", role: .cancel) {}
        Button("Reprocess", role: .destructive) { viewModel.reprocessSelectedDay() }
      } message: {
        Text(
          "This will delete existing timeline cards for \(dayString) and re-run analysis. It can consume many API calls."
        )
      }
    }
  }

  // MARK: - Date pill
  //
  // A small label+date button that opens the inline calendar. Visually
  // aligned with SettingsSecondaryButton but with a top-label for form
  // clarity. One style, used for all date inputs.

  private func datePill(
    label: String,
    date: Date,
    isExpanded: Bool,
    accessibilityLabel: String,
    disabled: Bool = false,
    onTap: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label)
        .font(TBDTokens.Typography.label)
        .foregroundStyle(TBDColor.muted)

      Button {
        guard !disabled else { return }
        onTap()
      } label: {
        HStack(spacing: 8) {
          Text(formattedTimelineDate(date))
            .font(TBDTokens.Typography.control)

          Spacer(minLength: 0)

          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(TBDFonts.symbol(10, .heavy))
        }
        .foregroundStyle(disabled ? TBDColor.disabledOn : TBDColor.fieldOn)
        .padding(.horizontal, TBDTokens.Control.paddingX)
        .frame(minWidth: 170, minHeight: TBDTokens.Control.minHeight, alignment: .leading)
        .background(disabled ? TBDColor.disabledFill : TBDColor.fieldFill, in: TBDBrickShape())
        .overlay(
          TBDBrickShape().strokeBorder(
            disabled ? TBDColor.line : TBDColor.fieldEdge, lineWidth: TBDKit.hair)
        )
        .contentShape(TBDBrickShape())
      }
      .buttonStyle(.plain)
      .disabled(disabled)
      .pointingHandCursor()
      .accessibilityLabel(Text(accessibilityLabel))
    }
  }

  // MARK: - Inline calendar
  //
  // Shown as an expanded panel underneath a date pill. Keeps its own
  // floating surface (tile + hairline ring) because it's an input
  // widget, not a section container — like any dropdown menu.

  private func inlineCalendar(
    date: Binding<Date>,
    disabled: Bool = false,
    onDateSelected: @escaping () -> Void
  ) -> some View {
    DayflowCalendarGrid(selectedDate: date, onDateSelected: onDateSelected)
      .disabled(disabled)
      .opacity(disabled ? 0.7 : 1)
  }

  // MARK: - Helpers

  private func formattedTimelineDate(_ date: Date) -> String {
    Self.dateLabelFormatter.string(from: timelineDisplayDate(from: date))
  }

  private func exportDateBinding(for picker: ExportDatePicker) -> Binding<Date> {
    switch picker {
    case .start: return $viewModel.exportStartDate
    case .end: return $viewModel.exportEndDate
    }
  }

  private static let dateLabelFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
    return formatter
  }()
}

// MARK: - Custom calendar grid

private struct DayflowCalendarGrid: View {
  @Binding var selectedDate: Date
  var onDateSelected: () -> Void

  @State private var displayedMonth: Date = Date()

  private let calendar = Calendar.current
  private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

  var body: some View {
    VStack(spacing: 12) {
      monthHeader
      weekdayLabels
      dayGrid
    }
    .padding(14)
    .frame(maxWidth: 290, alignment: .leading)
    // A dropdown-style floating panel: tile, brick, hair ring and the one float shadow.
    .tbdFloating()
    .onAppear {
      displayedMonth =
        calendar.date(
          from: calendar.dateComponents([.year, .month], from: selectedDate)
        ) ?? selectedDate
    }
  }

  private var monthHeader: some View {
    HStack {
      Text(monthYearString)
        .font(TBDTokens.Typography.control)
        .foregroundStyle(TBDColor.ink)

      Spacer()

      HStack(spacing: 2) {
        Button {
          changeMonth(by: -1)
        } label: {
          Image(systemName: "chevron.left")
            .font(TBDFonts.symbol(12))
        }
        .buttonStyle(TBDButtonStyle(.icon))
        .pointingHandCursor()

        Button {
          changeMonth(by: 1)
        } label: {
          Image(systemName: "chevron.right")
            .font(TBDFonts.symbol(12))
        }
        .buttonStyle(TBDButtonStyle(.icon))
        .pointingHandCursor()
      }
    }
  }

  private var weekdayLabels: some View {
    let symbols = calendar.veryShortWeekdaySymbols
    let firstWeekday = calendar.firstWeekday
    let ordered = Array(symbols[(firstWeekday - 1)...]) + Array(symbols[..<(firstWeekday - 1)])

    return LazyVGrid(columns: columns, spacing: 2) {
      ForEach(ordered.indices, id: \.self) { index in
        Text(ordered[index])
          .font(TBDTokens.Typography.label)
          .foregroundStyle(TBDColor.muted)
          .frame(maxWidth: .infinity)
          .frame(height: 22)
      }
    }
  }

  private var dayGrid: some View {
    let firstOfMonth = calendar.date(
      from: calendar.dateComponents([.year, .month], from: displayedMonth)
    )!
    let daysInMonth = calendar.range(of: .day, in: .month, for: firstOfMonth)!.count
    let weekday = calendar.component(.weekday, from: firstOfMonth)
    let offset = (weekday - calendar.firstWeekday + 7) % 7

    return LazyVGrid(columns: columns, spacing: 2) {
      ForEach(0..<offset, id: \.self) { _ in
        Color.clear.frame(height: 30)
      }

      ForEach(1...daysInMonth, id: \.self) { day in
        let date = makeDate(
          year: calendar.component(.year, from: firstOfMonth),
          month: calendar.component(.month, from: firstOfMonth),
          day: day)
        let isSelected = date.map { calendar.isDate($0, inSameDayAs: selectedDate) } ?? false
        let isToday = date.map { calendar.isDateInToday($0) } ?? false

        Button {
          if let date {
            selectedDate = date
            onDateSelected()
          }
        } label: {
          Text("\(day)")
            .font(
              isSelected || isToday
                ? TBDFonts.nunito(TBDKit.textControl, TBDKit.weightLabel)
                : TBDFonts.nunito(TBDKit.textControl, TBDKit.weightBody)
            )
            .foregroundStyle(
              isSelected ? TBDColor.primaryOn : (isToday ? TBDColor.tealInk : TBDColor.ink)
            )
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background {
              if isSelected {
                TBDBrickShape().fill(TBDColor.primaryFill).frame(width: 28, height: 28)
              } else if isToday {
                TBDBrickShape()
                  .strokeBorder(TBDColor.tealInk, lineWidth: TBDKit.hair)
                  .frame(width: 28, height: 28)
              }
            }
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
      }
    }
  }

  private var monthYearString: String {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("yMMMM")
    return formatter.string(from: displayedMonth)
  }

  private func changeMonth(by value: Int) {
    var components = calendar.dateComponents([.year, .month], from: displayedMonth)
    components.month = (components.month ?? 1) + value
    displayedMonth = calendar.date(from: components) ?? displayedMonth
  }

  private func makeDate(year: Int, month: Int, day: Int) -> Date? {
    calendar.date(from: DateComponents(year: year, month: month, day: day))
  }
}
