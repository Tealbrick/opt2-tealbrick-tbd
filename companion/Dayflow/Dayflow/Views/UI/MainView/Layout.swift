import AppKit
import TBDDesign
import TBDModels
import SwiftUI

extension MainView {
  // `mainLayout` is split into two chained computed properties because the
  // full modifier stack (20+ modifiers, several large inline closures) was
  // exceeding Swift's per-expression type-check budget. Each `some View`
  // boundary gives the solver a fresh, opaque anchor so the inner chain is
  // type-checked in isolation. Closure bodies that ran long (onAppear, the
  // tab-selection onChange, selectedDate onChange, toast overlay) are also
  // extracted to named methods / computed properties below for the same
  // reason.
  var mainLayout: some View {
    mainLayoutCore
      .environmentObject(retryCoordinator)
  }

  // Layer 1: layout + visual overlays.
  private var mainLayoutWithOverlays: some View {
    contentStack
      .padding([.top, .trailing, .bottom], 15)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.clear)
      .ignoresSafeArea()
      .blur(radius: goalFlowPresentation == nil ? 0 : 10)
      .allowsHitTesting(goalFlowPresentation == nil)
      // Hero animation overlay for video expansion (Emil Kowalski: shared element transitions)
      .overlay { overlayContent }
      .overlay(alignment: .bottomTrailing) { timelineFailureToastOverlayContent }
      .overlay(alignment: .bottomTrailing) { screenRecordingPermissionNoticeOverlayContent }
      .overlay { categoryEditorOverlay }
  }

  // Layer 2: sheet + lifecycle + notifications + state-change reactions.
  private var mainLayoutCore: some View {
    mainLayoutWithOverlays
      .sheet(isPresented: $showDatePicker) {
        DatePickerSheet(
          selectedDate: Binding(
            get: { selectedDate },
            set: {
              lastDateNavMethod = "picker"
              setSelectedDate($0)
            }
          ),
          isPresented: $showDatePicker
        )
      }
      .onAppear(perform: performMainLayoutOnAppear)
      .onDisappear(perform: performMainLayoutOnDisappear)
      .onChange(of: inactivity.pendingReset) { _, fired in
        if fired, selectedIcon != .settings {
          performIdleResetAndScroll()
          InactivityMonitor.shared.markHandledIfPending()
        }
      }
      .onChange(of: selectedIcon) { _, newIcon in
        handleTabSelectionChange(newIcon)
      }
      .onChange(of: selectedDate) { _, newDate in
        handleSelectedDateChange(newDate)
      }
      .onChange(of: refreshActivitiesTrigger) {
        updateCardsToReviewCount()
        loadWeeklyTrackedMinutes()
      }
      .onChange(of: selectedActivity?.id) {
        handleSelectedActivityIdChange()
      }
      // Second observer on selectedIcon: if user returns from Settings and a
      // reset was pending, perform it once. SwiftUI allows multiple onChange
      // handlers for the same value — they fire in declaration order.
      .onChange(of: selectedIcon) { _, newIcon in
        if newIcon != .settings, inactivity.pendingReset {
          performIdleResetAndScroll()
          InactivityMonitor.shared.markHandledIfPending()
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .navigateToWeekly)) { _ in
        withAnimation(TBDMotion.spring) {
          selectedIcon = .weekly
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .showTimelineFailureToast)) {
        handleShowTimelineFailureToastNotification($0)
      }
      .onReceive(NotificationCenter.default.publisher(for: .showScreenRecordingPermissionNotice)) {
        handleShowScreenRecordingPermissionNoticeNotification($0)
      }
      .onReceive(NotificationCenter.default.publisher(for: .timelineDataUpdated)) {
        handleTimelineDataUpdatedNotification($0)
      }
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      ) { _ in
        handleAppDidBecomeActive()
      }
  }

  // MARK: - Extracted overlays and event handlers
  //
  // Each of these corresponds to a closure or inline view that used to live
  // inline in the `mainLayout` modifier chain. Extraction is load-bearing:
  // without it, the combined type-check of `mainLayout`'s modifier chain +
  // each closure's body exceeded Swift's per-expression solver budget.

  @ViewBuilder
  private var timelineFailureToastOverlayContent: some View {
    if let payload = timelineFailureToastPayload {
      TimelineFailureToastView(
        title: payload.title,
        message: payload.message,
        actionTitle: payload.destination == .account
          ? String(localized: "Open Account") : String(localized: "Open Provider Settings"),
        onOpenSettings: { handleTimelineFailureToastOpenSettings(payload) },
        onDismiss: { handleTimelineFailureToastDismiss(payload) }
      )
      .padding(.trailing, 24)
      .padding(.bottom, 24)
      .transition(.move(edge: .trailing).combined(with: .opacity))
    }
  }

  @ViewBuilder
  private var screenRecordingPermissionNoticeOverlayContent: some View {
    if showScreenRecordingPermissionNotice {
      ScreenRecordingPermissionNoticeView(
        onOpenSettings: handleScreenRecordingPermissionNoticeOpenSettings,
        onDismiss: handleScreenRecordingPermissionNoticeDismiss
      )
      .padding(.trailing, 24)
      .padding(.bottom, 24)
      .transition(.move(edge: .trailing).combined(with: .opacity))
    }
  }

  private func performMainLayoutOnAppear() {
    syncCurrentUIContext()

    // screen viewed and initial timeline view
    // Orchestrated entrance animations following Emil Kowalski principles —
    // fast, under 300ms, natural spring motion, staggered by 50ms.
    withAnimation(TBDMotion.spring) {
      logoScale = 1.0
      logoOpacity = 1
    }
    withAnimation(TBDMotion.spring.delay(0.1)) {
      timelineOffset = 0
      timelineOpacity = 1
    }
    withAnimation(TBDMotion.spring.delay(0.15)) {
      sidebarOffset = 0
      sidebarOpacity = 1
    }
    withAnimation(TBDMotion.spring.delay(0.2)) {
      contentOpacity = 1
    }

    if !didInitialScroll {
      performInitialScrollIfNeeded()
    }
    showScreenRecordingNoticeIfNeeded()
    startDayChangeTimer()
    loadWeeklyTrackedMinutes()
    updateCardsToReviewCount()
    requestDailyGoalPromptIfNeeded()
  }

  private func performMainLayoutOnDisappear() {
    // Safety: stop timer if view disappears
    stopDayChangeTimer()
    reviewCountTask?.cancel()
    reviewCountTask = nil
    copyTimelineTask?.cancel()
    deleteTimelineTask?.cancel()
  }

  private func handleTabSelectionChange(_ newIcon: SidebarIcon) {
    // Clear tab-specific notification badges once the user visits the destination.
    if newIcon == .daily {
      if !consumePendingDailyRecapOpenIfNeeded(source: "daily_tab_selected") {
        NotificationBadgeManager.shared.clearDailyBadge()
      }
    }

    let tabName = newIcon.analyticsTabName
    syncCurrentUIContext(selectedTab: newIcon)

    if newIcon == .timeline {
      updateCardsToReviewCount()
      loadWeeklyTrackedMinutes()
    } else {
      showTimelineReview = false
    }
  }

  private func handleSelectedDateChange(_ newDate: Date) {
    let changeStart = CFAbsoluteTimeGetCurrent()
    let oldDate = previousDate
    let oldDay = dayString(oldDate)
    let newDay = dayString(newDate)
    let oldWeekRange = cachedTimelineWeekRange

    if let method = lastDateNavMethod, method == "picker" {
    }

    previousDate = newDate

    let newWeekRange = TimelineWeekRange.containing(newDate)
    let weekRangeChanged = newWeekRange != oldWeekRange

    timelinePerfLog(
      "selectedDateChange.begin mode=\(timelineMode.rawValue) old=\(oldDay) new=\(newDay) weekChanged=\(weekRangeChanged) navMethod=\(lastDateNavMethod ?? "nil")"
    )

    cachedTimelineWeekRange = newWeekRange
    updateCardsToReviewCount(trigger: "selectedDateChange")
    if weekRangeChanged {
      loadWeeklyTrackedMinutes(trigger: "selectedDateChange")
    }

    let durationMs = Int((CFAbsoluteTimeGetCurrent() - changeStart) * 1000)
    timelinePerfLog(
      "selectedDateChange.end mode=\(timelineMode.rawValue) old=\(oldDay) new=\(newDay) weekChanged=\(weekRangeChanged) duration_ms=\(durationMs)"
    )
  }

  private func handleSelectedActivityIdChange() {
    dismissFeedbackModal(animated: false)
    guard let a = selectedActivity else { return }
    let dur = a.endTime.timeIntervalSince(a.startTime)
  }

  private func handleTimelineDataUpdatedNotification(_ notification: Notification) {
    guard selectedIcon == .timeline else { return }
    if let refreshedDay = notification.userInfo?["dayString"] as? String {
      let selectedTimelineDay = DateFormatter.yyyyMMdd.string(
        from: timelineDisplayDate(from: selectedDate, now: Date())
      )
      guard refreshedDay == selectedTimelineDay else { return }
    }
    updateCardsToReviewCount()
    loadWeeklyTrackedMinutes()
  }

  private func handleShowTimelineFailureToastNotification(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
      let payload = TimelineFailureToastPayload(userInfo: userInfo)
    else {
      return
    }
    withAnimation(TBDMotion.spring) {
      timelineFailureToastPayload = payload
    }
  }

  private func handleShowScreenRecordingPermissionNoticeNotification(_ notification: Notification) {
    showScreenRecordingNoticeIfNeeded()
  }

  private func showScreenRecordingNoticeIfNeeded() {
    guard !didDismissScreenRecordingPermissionNoticeThisSession else { return }
    guard !ScreenRecordingPermissionNotice.isGranted else {
      showScreenRecordingPermissionNotice = false
      return
    }
    guard AppState.shared.getSavedPreference() == true || appState.isRecording else { return }

    withAnimation(TBDMotion.spring) {
      showScreenRecordingPermissionNotice = true
    }
  }

  private func handleAppDidBecomeActive() {
    if ScreenRecordingPermissionNotice.isGranted {
      showScreenRecordingPermissionNotice = false
      didDismissScreenRecordingPermissionNoticeThisSession = false
    }

    // Check if day changed while app was backgrounded
    handleMinuteTickForDayChange()
    requestDailyGoalPromptIfNeeded()
    // Ensure timer is running
    if dayChangeTimer == nil {
      startDayChangeTimer()
    }
    // Refresh weekly hours in case activities were added
    loadWeeklyTrackedMinutes()
  }

  private func handleTimelineFailureToastOpenSettings(_ payload: TimelineFailureToastPayload) {
    withAnimation(TBDMotion.spring) {
      selectedIcon = .settings
      timelineFailureToastPayload = nil
    }
    let settingsTab: Notification.Name =
      payload.destination == .account ? .openAccountSettings : .openProvidersSettings
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      NotificationCenter.default.post(name: settingsTab, object: nil)
    }
  }

  private func handleTimelineFailureToastDismiss(_ payload: TimelineFailureToastPayload) {
    withAnimation(TBDMotion.spring) {
      timelineFailureToastPayload = nil
    }
  }

  private func handleScreenRecordingPermissionNoticeOpenSettings() {
    didDismissScreenRecordingPermissionNoticeThisSession = true
    withAnimation(TBDMotion.spring) {
      showScreenRecordingPermissionNotice = false
    }
    // WP-ONB link: the setup's Permissions step asks macOS and offers "Quit and reopen TBD".
    NotificationCenter.default.post(name: .tbdOpenOnboarding, object: TBDOnboardingStep.permissions.rawValue)
  }

  private func handleScreenRecordingPermissionNoticeDismiss() {
    didDismissScreenRecordingPermissionNoticeThisSession = true
    withAnimation(TBDMotion.spring) {
      showScreenRecordingPermissionNotice = false
    }
  }

  private var overlayContent: some View {
    ZStack {
      VideoExpansionOverlay(
        expansionState: videoExpansionState,
        namespace: videoHeroNamespace
      )

      if selectedIcon == .timeline, showTimelineReview {
        TimelineReviewOverlay(
          isPresented: $showTimelineReview,
          selectedDate: selectedDate
        ) {
          updateCardsToReviewCount()
          reviewSummaryRefreshToken &+= 1
        }
        .environmentObject(categoryStore)
        .transition(.opacity)
        .zIndex(2)
      }

    }
  }

  @ViewBuilder
  private var categoryEditorOverlay: some View {
    if showCategoryEditor {
      ColorOrganizerRoot(
        presentationStyle: .sheet,
        onDismiss: { showCategoryEditor = false }, completionButtonTitle: String(localized: "Done"),
        showsTitles: true
      )
      .environmentObject(categoryStore)
      // Removed .contentShape(Rectangle()) and .onTapGesture to allow keyboard input
    }
  }
}

private struct TimelineFailureToastView: View {
  let title: String?
  let message: String
  let actionTitle: String
  let onOpenSettings: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(TBDFonts.symbol(14, TBDKit.weightBody))
          .foregroundStyle(TBDColor.brickInk)
          .padding(.top, 2)

        // Mirrors ScreenRecordingPermissionNoticeView: semibold title with a
        // quieter body. Untitled (generic fallback) toasts keep the old look.
        VStack(alignment: .leading, spacing: 3) {
          if let title {
            Text(title)
              .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightNav))
              .foregroundStyle(TBDColor.ink)
          }

          Text(message)
            .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
            .foregroundStyle(title == nil ? TBDColor.ink : TBDColor.muted)
            .fixedSize(horizontal: false, vertical: true)
        }

        Button(action: onDismiss) {
          Image(systemName: "xmark")
            .font(TBDFonts.symbol(11, TBDKit.weightNav))
        }
        .buttonStyle(TBDButtonStyle(.icon))
        .accessibilityLabel(Text("Close"))
        .pointingHandCursorOnHover(reassertOnPressEnd: true)
      }

      Button(action: onOpenSettings) {
        HStack(spacing: 6) {
          Image(systemName: "gearshape")
            .font(TBDFonts.symbol(12, TBDKit.weightNav))
          Text(actionTitle)
        }
      }
      .buttonStyle(TBDButtonStyle(.secondary))
      .pointingHandCursor()
    }
    .padding(14)
    .frame(width: 360, alignment: .leading)
    // Floating notice: brick with the one float shadow.
    .tbdFloating()
  }
}

private struct ScreenRecordingPermissionNoticeView: View {
  let onOpenSettings: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "record.circle.fill")
          .font(TBDFonts.symbol(15, TBDKit.weightBody))
          .foregroundStyle(TBDColor.brick)
          .padding(.top, 2)

        VStack(alignment: .leading, spacing: 3) {
          Text("Screen recording access needed")
            .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightNav))
            .foregroundStyle(TBDColor.ink)

          Text("Tealbrick cannot update your timeline until access is restored.")
            .font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightBody))
            .foregroundStyle(TBDColor.muted)
            .fixedSize(horizontal: false, vertical: true)
        }

        Button(action: onDismiss) {
          Image(systemName: "xmark")
            .font(TBDFonts.symbol(11, TBDKit.weightNav))
        }
        .buttonStyle(TBDButtonStyle(.icon))
        .accessibilityLabel(Text("Close"))
        .pointingHandCursorOnHover(reassertOnPressEnd: true)
      }

      Button(action: onOpenSettings) {
        HStack(spacing: 6) {
          Image(systemName: "gearshape")
            .font(TBDFonts.symbol(12, TBDKit.weightNav))
          Text("Open System Settings")
        }
      }
      .buttonStyle(TBDButtonStyle(.secondary))
      .pointingHandCursor()
    }
    .padding(14)
    .frame(width: 360, alignment: .leading)
    // Floating notice: brick with the one float shadow.
    .tbdFloating()
  }
}
