import AppKit
import Foundation
import TBDDesign
import TBDModels
import SwiftUI
import UserNotifications

extension DailyView {
  @ViewBuilder
  func actionButtons(scale: CGFloat) -> some View {
    HStack(spacing: 10 * scale) {
      if hasPersistedStandupEntry {
        standupCopyButton(scale: scale)
      }
      standupRegenerateButton(scale: scale)
      dailyProviderButton(scale: scale)
    }
  }

  /// "Before" layout: buttons in their own trailing-aligned row below the
  /// workflow grid instead of inline with the standup heading.
  @ViewBuilder
  func actionRow(scale: CGFloat) -> some View {
    HStack {
      Spacer(minLength: 0)
      actionButtons(scale: scale)
    }
  }
  func standupCopyButton(scale: CGFloat) -> some View {
    let transition = AnyTransition.opacity.combined(with: .scale(scale: 0.5))

    return Button(action: copyStandupUpdateToClipboard) {
      HStack(spacing: 6 * scale) {
        ZStack {
          if standupCopyState == .copied {
            Image(systemName: "checkmark")
              .font(TBDFonts.symbol(12 * scale, .bold))
              .transition(transition)
          } else {
            Image("Copy")
              .resizable()
              .interpolation(.high)
              .renderingMode(.template)
              .scaledToFit()
              .frame(width: 16 * scale, height: 16 * scale)
              .transition(transition)
          }
        }
        .frame(width: 16 * scale, height: 16 * scale)

        ZStack(alignment: .leading) {
          Text("Copy standup update")
            .lineLimit(1)
            .opacity(standupCopyState == .copied ? 0 : 1)

          Text("Copied")
            .lineLimit(1)
            .opacity(standupCopyState == .copied ? 1 : 0)
        }
        .frame(minWidth: 136 * scale, alignment: .leading)
      }
    }
    .buttonStyle(TBDButtonStyle(.secondary))
    .animation(TBDMotion.quick, value: standupCopyState)
    .pointingHandCursorOnHover(reassertOnPressEnd: true)
    .accessibilityLabel(
      Text(
        standupCopyState == .copied
          ? String(localized: "Copied standup update") : String(localized: "Copy standup update")))
  }
  func standupRegenerateButton(scale: CGFloat) -> some View {
    let transition = AnyTransition.opacity.combined(with: .scale(scale: 0.5))

    return Button(action: regenerateStandupFromTimeline) {
      HStack(spacing: 6 * scale) {
        ZStack {
          if standupRegenerateState == .regenerating {
            ProgressView()
              .progressViewStyle(.circular)
              .scaleEffect(0.5 * scale)
              .tint(TBDColor.ink)
          } else if standupRegenerateState == .regenerated {
            Image(systemName: "checkmark")
              .font(TBDFonts.symbol(12 * scale, .bold))
              .transition(transition)
          } else if standupRegenerateState == .noData {
            Image(systemName: "exclamationmark.circle")
              .font(TBDFonts.symbol(12 * scale, .bold))
              .transition(transition)
          } else {
            Image(systemName: "arrow.clockwise")
              .font(TBDFonts.symbol(12 * scale, .bold))
              .transition(transition)
          }
        }
        .frame(width: 16 * scale, height: 16 * scale)

        ZStack(alignment: .leading) {
          Text(regenerateButtonLabel)
            .lineLimit(1)
            .opacity(transientRegenerateButtonLabel == nil ? 1 : 0)

          Text(transientRegenerateButtonLabel ?? "")
            .lineLimit(1)
            .opacity(transientRegenerateButtonLabel == nil ? 0 : 1)
        }
        .frame(minWidth: stylePreviewAfter ? nil : 108 * scale, alignment: .leading)
      }
    }
    .buttonStyle(TBDButtonStyle(.secondary))
    .animation(TBDMotion.quick, value: standupRegenerateState)
    .disabled(!canRegenerateStandup)
    .pointingHandCursorOnHover(
      enabled: canRegenerateStandup, reassertOnPressEnd: true
    )
    .accessibilityLabel(Text("Regenerate standup highlights"))
    .help(regenerateButtonHelpText)
    .background {
      if standupRegenerateState == .regenerating {
        Color.clear
          .onReceive(Timer.publish(every: 0.45, on: .main, in: .common).autoconnect()) { _ in
            standupRegeneratingDotsPhase = (standupRegeneratingDotsPhase % 3) + 1
          }
      }
    }
    .onChange(of: standupRegenerateState) {
      if standupRegenerateState != .regenerating {
        standupRegeneratingDotsPhase = 1
      }
    }
  }
  @ViewBuilder
  func highlightsAndTasksSection(
    useSingleColumn: Bool,
    contentWidth: CGFloat,
    scale: CGFloat,
    heading: String,
    titles: DailyStandupSectionTitles
  ) -> some View {
    VStack(alignment: .leading, spacing: 8 * scale) {
      if stylePreviewAfter {
        HStack(alignment: .center, spacing: 12 * scale) {
          Text(heading)
            .font(TBDTokens.Typography.title)
            .foregroundStyle(TBDColor.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.75)

          Spacer(minLength: 0)

          actionButtons(scale: scale)
        }
      } else {
        Text(heading)
          .font(TBDTokens.Typography.title)
          .foregroundStyle(TBDColor.muted)
      }

      if !dailyRecapProvider.canGenerate && !hasPersistedStandupEntry {
        chooseModelPrompt(scale: scale)
      } else if useSingleColumn {
        VStack(alignment: .leading, spacing: 12 * scale) {
          DailyBulletCard(
            style: .highlights,
            seamMode: .standalone,
            title: titles.highlights,
            items: $standupDraft.highlights,
            blockersTitle: $standupDraft.blockersTitle,
            blockersBody: $standupDraft.blockersBody,
            scale: scale
          )
          DailyBulletCard(
            style: .tasks,
            seamMode: .standalone,
            title: titles.tasks,
            items: $standupDraft.tasks,
            blockersTitle: $standupDraft.blockersTitle,
            blockersBody: $standupDraft.blockersBody,
            scale: scale
          )
        }
      } else {
        // Figma overlaps borders by ~1px to avoid a visible gutter.
        let cardSpacing = -1 * scale
        let cardWidth = (contentWidth - cardSpacing) / 2
        HStack(alignment: .top, spacing: cardSpacing) {
          DailyBulletCard(
            style: .highlights,
            seamMode: .joinedLeading,
            title: titles.highlights,
            items: $standupDraft.highlights,
            blockersTitle: $standupDraft.blockersTitle,
            blockersBody: $standupDraft.blockersBody,
            scale: scale
          )
          .frame(width: cardWidth)

          DailyBulletCard(
            style: .tasks,
            seamMode: .joinedTrailing,
            title: titles.tasks,
            items: $standupDraft.tasks,
            blockersTitle: $standupDraft.blockersTitle,
            blockersBody: $standupDraft.blockersBody,
            scale: scale
          )
          .frame(width: cardWidth)
        }
      }
    }
  }
  /// Shown instead of the empty recap cards while Daily has no model (C137).
  func chooseModelPrompt(scale: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 10 * scale) {
      Text("Choose a model for Daily")
        .font(TBDFonts.nunito(TBDKit.textLabel, TBDKit.weightLabel))
        .foregroundStyle(TBDColor.ink)

      Text(
        "Daily needs a model to write the recap. Use TBD's agent model (Settings → Models) or pick another provider."
      )
      .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
      .foregroundStyle(TBDColor.muted)
      .fixedSize(horizontal: false, vertical: true)

      Button {
        refreshProviderAvailability()
        isShowingProviderPicker = true
      } label: {
        Text("Choose a model")
      }
      .buttonStyle(TBDButtonStyle(.primary))
      .pointingHandCursorOnHover(reassertOnPressEnd: true)

      // WP-ONB link: the setup's Models step (subscription CLI, API key or a model on this Mac).
      Button("Open setup") {
        NotificationCenter.default.post(name: .tbdOpenOnboarding, object: TBDOnboardingStep.models.rawValue)
      }
      .buttonStyle(TBDButtonStyle(.quiet))
    }
    .padding(16 * scale)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(TBDColor.tile, in: TBDBrickShape())
    .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
  }
  func copyStandupUpdateToClipboard() {
    let clipboardText = standupClipboardText(for: selectedDate)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(clipboardText, forType: .string)

    standupCopyResetTask?.cancel()

    withAnimation(TBDMotion.quick) {
      standupCopyState = .copied
    }


    standupCopyResetTask = Task {
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      guard !Task.isCancelled else { return }

      await MainActor.run {
        withAnimation(TBDMotion.quick) {
          standupCopyState = .idle
        }
        standupCopyResetTask = nil
      }
    }
  }
  func regenerateStandupFromTimeline() {
    guard standupRegenerateState != .regenerating else { return }
    let regenerateRunId = UUID().uuidString

    let targetDay = workflowDayInfo(for: selectedDate)
    let storageDayString = targetDay.dayString
    let selectedProvider = dailyRecapProvider
    let usesDayflowInputs = false

    guard selectedProvider.canGenerate else {
      standupDraft = .noProviderSelected
      standupRegenerateState = .idle
      return
    }
    let providerProps: [String: Any] = [
      "daily_provider": selectedProvider.analyticsName,
      "daily_provider_label": selectedProvider.displayName,
      "daily_runtime": selectedProvider.runtimeLabel,
      "daily_model_or_tool": selectedProvider.modelOrTool as Any,
    ]
    guard let sourceDayInfo = standupSourceDay ?? resolveStandupSourceDay(for: targetDay) else {
      standupRegenerateState = .noData
      scheduleStandupRegenerateReset()
      return
    }

    let dayString = sourceDayInfo.dayString
    let dayStartTs = Int(sourceDayInfo.startOfDay.timeIntervalSince1970)
    let dayEndTs = Int(sourceDayInfo.endOfDay.timeIntervalSince1970)
    let standupTitles = standupSectionTitles(for: selectedDate, sourceDay: sourceDayInfo)
    let currentHighlightsTitle = standupTitles.highlights
    let currentTasksTitle = standupTitles.tasks
    let currentBlockersTitle = standupTitles.blockers

    standupRegenerateTask?.cancel()
    standupRegenerateResetTask?.cancel()

    print(
      "[Daily] Regenerate started run_id=\(regenerateRunId) day=\(dayString) provider=\(selectedProvider.analyticsName) model=\(selectedProvider.modelOrTool ?? "default")"
    )

    standupRegenerateState = .regenerating

    standupRegenerateTask = Task.detached(priority: .userInitiated) {
      let startedAt = Date()
      let cards = StorageManager.shared.fetchTimelineCards(forDay: dayString)
      guard !cards.isEmpty else {
        guard !Task.isCancelled else { return }
        print(
          "[Daily] Regenerate failed run_id=\(regenerateRunId) day=\(dayString) reason=no_cards")
        await MainActor.run {

          guard isStillViewingWorkflowDay(storageDayString) else { return }

          standupRegenerateState = .noData
          standupRegenerateTask = nil
          scheduleStandupRegenerateReset()
        }
        return
      }

      let observations =
        usesDayflowInputs
        ? StorageManager.shared.fetchObservations(startTs: dayStartTs, endTs: dayEndTs) : []
      let priorEntries =
        usesDayflowInputs
        ? StorageManager.shared.fetchRecentDailyStandups(
          limit: priorStandupHistoryLimit,
          excludingDay: dayString
        ) : []
      let cardsText = DailyRecapGenerator.makeCardsText(day: dayString, cards: cards)
      let observationsText =
        usesDayflowInputs
        ? DailyRecapGenerator.makeObservationsText(day: dayString, observations: observations)
        : ""
      let priorDailyText =
        usesDayflowInputs ? DailyRecapGenerator.makePriorDailyText(entries: priorEntries) : ""
      let preferencesText =
        usesDayflowInputs
        ? DailyRecapGenerator.makePreferencesText(
          highlightsTitle: currentHighlightsTitle,
          tasksTitle: currentTasksTitle,
          blockersTitle: currentBlockersTitle
        ) : ""

      print(
        "[Daily] Regenerate payload run_id=\(regenerateRunId) day=\(dayString) "
          + "cards=\(cards.count) observations=\(observations.count) prior_daily=\(priorEntries.count) input_mode=\(usesDayflowInputs ? "cards_observations_prior" : "cards_only")"
      )

      do {
        let context = DailyRecapGenerationContext(
          targetDayString: storageDayString,
          sourceDayString: dayString,
          cards: cards,
          observations: observations,
          priorEntries: priorEntries,
          highlightsTitle: currentHighlightsTitle,
          tasksTitle: currentTasksTitle,
          blockersTitle: currentBlockersTitle
        )
        let regeneratedDraft = try await DailyRecapGenerator.shared.generate(context: context)

        guard let payloadJSON = regeneratedDraft.encodedJSONString() else {
          guard !Task.isCancelled else { return }
          print(
            "[Daily] Regenerate failed run_id=\(regenerateRunId) day=\(dayString) "
              + "reason=encode_failed"
          )
          await MainActor.run {

            guard isStillViewingWorkflowDay(storageDayString) else { return }

            standupRegenerateState = .idle
            standupRegenerateTask = nil
          }
          return
        }

        StorageManager.shared.saveDailyStandup(forDay: storageDayString, payloadJSON: payloadJSON)

        guard !Task.isCancelled else { return }
        let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let blockersCount = regeneratedDraft.blockersBody
          .split(whereSeparator: \.isNewline)
          .count
        print(
          "[Daily] Regenerate succeeded run_id=\(regenerateRunId) day=\(dayString) cards=\(cards.count) observations=\(observations.count) highlights=\(regeneratedDraft.highlights.count) tasks=\(regeneratedDraft.tasks.count) blockers=\(blockersCount) latency_ms=\(latencyMs)"
        )

        let shouldApplyVisibleResult = await MainActor.run {
          isStillViewingWorkflowDay(storageDayString)
        }

        await MainActor.run {
          print(
            "[Daily] Regenerate notification enqueue run_id=\(regenerateRunId) "
              + "day=\(storageDayString)"
          )
          NotificationService.shared.scheduleDailyRecapReadyNotification(forDay: storageDayString)

          guard shouldApplyVisibleResult else { return }

          standupDraft = regeneratedDraft
          loadedStandupDraftDay = storageDayString
          loadedStandupFallbackSourceDay = sourceDayInfo.dayString
          standupSourceDay = sourceDayInfo
          hasPersistedStandupEntry = true
          standupRegenerateTask = nil
          standupRegenerateState = .regenerated

          scheduleStandupRegenerateReset()
        }
      } catch {
        let nsError = error as NSError
        guard !Task.isCancelled else { return }
        print(
          "[Daily] Regenerate failed run_id=\(regenerateRunId) day=\(dayString) reason=api_error error_domain=\(nsError.domain) error_code=\(nsError.code) error_message=\(nsError.localizedDescription)"
        )
        await MainActor.run {

          guard isStillViewingWorkflowDay(storageDayString) else { return }

          standupRegenerateState = .idle
          standupRegenerateTask = nil
        }
      }
    }
  }
  func standupClipboardText(for date: Date) -> String {
    let targetDay = workflowDayInfo(for: date)
    let sourceDay = resolveStandupSourceDay(for: targetDay)
    let titles = standupSectionTitles(for: date, sourceDay: sourceDay)
    let yesterdayItems = sanitizedStandupItems(standupDraft.highlights)
    let todayItems = sanitizedStandupItems(standupDraft.tasks)
    let blockersItems = sanitizedBlockers(standupDraft.blockersBody)

    var lines: [String] = []
    lines.append(titles.highlights)
    if yesterdayItems.isEmpty {
      lines.append(String(localized: "- None right now"))
    } else {
      yesterdayItems.forEach { lines.append("- \($0)") }
    }
    lines.append("")

    lines.append(titles.tasks)
    if todayItems.isEmpty {
      lines.append(String(localized: "- None right now"))
    } else {
      todayItems.forEach { lines.append("- \($0)") }
    }
    lines.append("")

    lines.append(titles.blockers)
    if blockersItems.isEmpty {
      lines.append(String(localized: "- None right now"))
    } else {
      blockersItems.forEach { lines.append("- \($0)") }
    }

    return lines.joined(separator: "\n")
  }
  func sanitizedStandupItems(_ items: [DailyBulletItem]) -> [String] {
    items.compactMap { sanitizedBulletText($0.text) }
  }
  func sanitizedBlockers(_ text: String) -> [String] {
    let segments = text.split(whereSeparator: \.isNewline).map(String.init)
    if segments.isEmpty {
      return sanitizedBulletText(text).map { [$0] } ?? []
    }
    return segments.compactMap(sanitizedBulletText)
  }
  func sanitizedBulletText(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard
      trimmed.caseInsensitiveCompare(DailyStandupPlaceholder.notGeneratedMessage) != .orderedSame
    else {
      return nil
    }
    guard
      trimmed.caseInsensitiveCompare(DailyStandupPlaceholder.todayNotGeneratedMessage)
        != .orderedSame
    else {
      return nil
    }
    guard
      trimmed.caseInsensitiveCompare(DailyStandupPlaceholder.insufficientHistoryMessage)
        != .orderedSame
    else {
      return nil
    }
    guard
      trimmed.caseInsensitiveCompare(DailyStandupPlaceholder.noProviderSelectedMessage)
        != .orderedSame
    else {
      return nil
    }
    return trimmed
  }
  func refreshStandupDraftIfNeeded(
    storageDayString: String,
    sourceDay: DailyStandupDayInfo?
  ) {
    let fallbackSourceDayString = sourceDay?.dayString
    let isSameDraftDay = loadedStandupDraftDay == storageDayString
    let isSameFallbackSourceDay = loadedStandupFallbackSourceDay == fallbackSourceDayString
    let entry = StorageManager.shared.fetchDailyStandup(forDay: storageDayString)
    hasPersistedStandupEntry = entry != nil

    if !dailyRecapProvider.canGenerate, entry == nil {
      guard !isSameDraftDay || !isSameFallbackSourceDay || standupDraft != .noProviderSelected
      else {
        return
      }

      loadedStandupDraftDay = storageDayString
      loadedStandupFallbackSourceDay = fallbackSourceDayString
      standupDraft = .noProviderSelected
      return
    }

    if entry != nil {
      guard !isSameDraftDay else { return }
    } else {
      guard !isSameDraftDay || !isSameFallbackSourceDay else { return }
    }

    loadedStandupDraftDay = storageDayString
    loadedStandupFallbackSourceDay = fallbackSourceDayString

    guard let entry,
      let data = entry.payloadJSON.data(using: .utf8),
      var decoded = try? JSONDecoder().decode(DailyStandupDraft.self, from: data)
    else {
      standupDraft = placeholderStandupDraft(sourceDay: sourceDay)
      return
    }

    standupDraft = decoded
  }
  func scheduleStandupDraftSave() {
    guard let dayString = loadedStandupDraftDay else { return }
    let draftToSave = standupDraft

    standupDraftSaveTask?.cancel()
    standupDraftSaveTask = Task.detached(priority: .utility) {
      try? await Task.sleep(nanoseconds: 250_000_000)
      guard !Task.isCancelled else { return }

      let existing = StorageManager.shared.fetchDailyStandup(forDay: dayString)
      let placeholderDrafts: [DailyStandupDraft] = [
        .default,
        .insufficientHistory,
      ]
      if draftToSave == .noProviderSelected {
        return
      }
      if existing == nil && placeholderDrafts.contains(draftToSave) {
        return
      }

      guard let data = try? JSONEncoder().encode(draftToSave),
        let json = String(data: data, encoding: .utf8)
      else {
        return
      }

      StorageManager.shared.saveDailyStandup(forDay: dayString, payloadJSON: json)
      await MainActor.run {
        if loadedStandupDraftDay == dayString {
          hasPersistedStandupEntry = true
        }
      }
    }
  }
  func placeholderStandupDraft(sourceDay: DailyStandupDayInfo?) -> DailyStandupDraft {
    if !dailyRecapProvider.canGenerate {
      return .noProviderSelected
    }

    if sourceDay == nil {
      return .insufficientHistory
    }

    return .default
  }
  var regenerateButtonLabel: String {
    switch standupRegenerateState {
    case .regenerating:
      return String(localized: "Regenerating")
        + String(repeating: ".", count: standupRegeneratingDotsPhase)
    case .idle, .regenerated, .noData:
      return String(localized: "Regenerate")
    }
  }
  var transientRegenerateButtonLabel: String? {
    switch standupRegenerateState {
    case .regenerated:
      return String(localized: "Regenerated")
    case .noData:
      return String(localized: "No data")
    case .idle, .regenerating:
      return nil
    }
  }
  func scheduleStandupRegenerateReset() {
    standupRegenerateResetTask?.cancel()
    standupRegenerateResetTask = Task {
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      guard !Task.isCancelled else { return }

      await MainActor.run {
        standupRegenerateState = .idle
        standupRegenerateResetTask = nil
      }
    }
  }
  func standupSectionTitles(for date: Date, sourceDay: DailyStandupDayInfo?)
    -> DailyStandupSectionTitles
  {
    let targetDay = workflowDayInfo(for: date)
    return DailyStandupSectionTitles(
      highlights: standupHighlightsTitle(for: sourceDay),
      tasks: standupTasksTitle(for: targetDay),
      blockers: String(localized: "Blockers")
    )
  }
  func standupSectionHeading(for date: Date) -> String {
    String(localized: "Standup for \(dailyDateTitle(for: date))")
  }
  func standupHighlightsTitle(for sourceDay: DailyStandupDayInfo?) -> String {
    guard let sourceDay else { return String(localized: "Recent highlights") }

    let label = standupDayLabelText(for: sourceDay.startOfDay)
    return String(localized: "Highlights from \(label)")
  }
  func standupTasksTitle(for targetDay: DailyStandupDayInfo) -> String {
    let label = standupDayLabelText(for: targetDay.startOfDay)
    return String(localized: "Tasks for \(label)")
  }
  func standupDayLabelText(for date: Date) -> String {
    let calendar = Calendar.current
    let displayDate = normalizedTimelineDate(date)
    let timelineToday = timelineDisplayDate(from: Date())

    if calendar.isDate(displayDate, inSameDayAs: timelineToday) {
      return String(localized: "Today")
    }

    guard let timelineYesterday = calendar.date(byAdding: .day, value: -1, to: timelineToday)
    else {
      return dailyOtherDayDisplayFormatter.string(from: displayDate)
    }

    if calendar.isDate(displayDate, inSameDayAs: timelineYesterday) {
      return String(localized: "Yesterday")
    }

    let daysAgo = calendar.dateComponents([.day], from: displayDate, to: timelineToday).day ?? 99
    if (2...6).contains(daysAgo) {
      return dailyStandupWeekdayFormatter.string(from: displayDate)
    }

    return dailyOtherDayDisplayFormatter.string(from: displayDate)
  }
}
