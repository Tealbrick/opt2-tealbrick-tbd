import XCTest
@testable import TBDModels

/// First-launch onboarding state (WP-ONB, C285/C286): persistence, resume after the self-relaunch, Back, edit mode,
/// background downloads, summary lines and the subscription flags (C287).
final class TBDOnboardingTests: XCTestCase {
    private var suites: [String] = []
    override func tearDown() {
        for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
        suites = []
        super.tearDown()
    }
    private func defaults() -> UserDefaults {
        let name = "tbd.tests.onboarding.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }
    private let allGranted = Set(TBDOnboardingPermission.allCases)

    func testFreshInstallStartsAtWelcomeAndForwardNeedsTheCheckOrANo() {
        let store = TBDOnboardingStore(defaults: defaults())
        var m = TBDOnboardingMachine(store: store)
        XCTAssertEqual(m.launch(), .flow(.welcome, editing: false))
        XCTAssertTrue(m.forward(TBDOnboardingChecks()))
        XCTAssertEqual(m.record.step, .portal)
        // Not signed in and no answer: Forward is refused.
        XCTAssertFalse(m.forward(TBDOnboardingChecks()))
        // Signed in but no workspace yet: still refused.
        XCTAssertFalse(m.forward(TBDOnboardingChecks(signedIn: true)))
        // "No" is a valid answer.
        m.update { $0.portal = .no }
        XCTAssertTrue(m.forward(TBDOnboardingChecks()))
        XCTAssertEqual(m.record.step, .agent)
        // Every move is saved.
        XCTAssertEqual(store.load()?.step, .agent)
        XCTAssertEqual(store.load()?.choices.portal, .no)
    }

    func testAgentStepNeedsAWorkingModelOrANoAndPairingNeverLocksIt() {
        var m = TBDOnboardingMachine(store: TBDOnboardingStore(defaults: defaults()))
        m.edit(.agent)
        m.update { $0.portal = .yes }
        XCTAssertFalse(m.isDone(.agent, TBDOnboardingChecks(signedIn: true, workspaceName: "W")))
        // Review dev.9 #5: a failed pairing must not lock the step; the summary shows the missing pairing instead.
        let unpaired = TBDOnboardingChecks(signedIn: true, workspaceName: "W", agentModelReady: true)
        XCTAssertTrue(m.isDone(.agent, unpaired))
        let line = TBDOnboardingSummary.lines(unpaired).first { $0.area == "TBD's agent" }
        XCTAssertEqual(line?.on, false)
        XCTAssertEqual(line?.text, "TBD's agent works on this Mac. It is not paired with W yet.")
        XCTAssertEqual(line?.fix, .step(.agent))
        m.update { $0.agent = .no }
        XCTAssertTrue(m.isDone(.agent, TBDOnboardingChecks()))
    }

    func testResumeAfterTheSelfRelaunchOpensAtPermissionsAndReChecks() {
        let d = defaults()
        var first = TBDOnboardingMachine(store: TBDOnboardingStore(defaults: d))
        _ = first.launch()
        first.update { $0.portal = .no; $0.agent = .no }
        first.edit(.permissions) // as if the person walked there
        first.markRelaunch(pid: 4242)
        XCTAssertEqual(TBDOnboardingStore(defaults: d).load()?.relaunch?.pid, 4242)

        // The next process: a new machine from the same defaults.
        var second = TBDOnboardingMachine(store: TBDOnboardingStore(defaults: d))
        XCTAssertEqual(second.launch(), .flow(.permissions, editing: second.record.editing))
        XCTAssertNil(second.record.relaunch, "the relaunch marker is cleared on start")
        XCTAssertNil(TBDOnboardingStore(defaults: d).load()?.relaunch)
        XCTAssertEqual(second.record.choices.agent, .no, "choices survive the relaunch")
        // The grant made in System Settings while TBD was closed counts at once.
        XCTAssertFalse(second.isDone(.permissions, TBDOnboardingChecks(granted: [.microphone])))
        XCTAssertTrue(second.isDone(.permissions, TBDOnboardingChecks(granted: allGranted)))
        // "Not now" is a valid answer per row.
        second.update { $0.permissionsNotNow = [.screenRecording, .accessibility, .notifications] }
        XCTAssertTrue(second.isDone(.permissions, TBDOnboardingChecks(granted: [.microphone])))
    }

    func testBackKeepsEveryChoice() {
        var m = TBDOnboardingMachine(store: TBDOnboardingStore(defaults: defaults()))
        _ = m.launch()
        m.forward(TBDOnboardingChecks())
        m.update { $0.portal = .no }
        m.forward(TBDOnboardingChecks())
        m.update { $0.agent = .yes; $0.agentRuntime = .local }
        m.back()
        XCTAssertEqual(m.record.step, .portal)
        m.back()
        XCTAssertEqual(m.record.step, .welcome)
        m.back()
        XCTAssertEqual(m.record.step, .welcome, "Back on the first step does nothing")
        XCTAssertEqual(m.record.choices, TBDOnboardingChoices(portal: .no, agent: .yes, agentRuntime: .local))
    }

    func testEditFromALinkGoesToTheStepThenToTheSummary() {
        let d = defaults()
        var m = TBDOnboardingMachine(store: TBDOnboardingStore(defaults: d))
        _ = m.launch()
        m.finish()
        XCTAssertEqual(m.launch(), .app)

        // "Choose a model for Daily" in the app → step Models in edit mode; completed stays true.
        m.edit(.models)
        XCTAssertTrue(m.record.editing)
        XCTAssertTrue(m.record.completed)
        // Quitting in the middle of the edit opens the app next time, not the flow (review dev.9 #8).
        var reopened = TBDOnboardingMachine(store: TBDOnboardingStore(defaults: d))
        XCTAssertEqual(reopened.launch(), .app)
        XCTAssertEqual(reopened.record.step, .models)
        XCTAssertFalse(reopened.forward(TBDOnboardingChecks()), "the step still needs its check or a No")
        XCTAssertTrue(reopened.forward(TBDOnboardingChecks(companionModelReady: true, speechModelOnDisk: true)))
        XCTAssertEqual(reopened.record.step, .summary, "edit mode skips the remaining steps")
        reopened.finish()
        XCTAssertEqual(reopened.launch(), .app)
        XCTAssertFalse(reopened.record.editing)
    }

    func testBackToTBDEndsAnEditWithoutOtherChanges() {
        var m = TBDOnboardingMachine(store: TBDOnboardingStore(defaults: defaults()))
        _ = m.launch()
        m.update { $0.portal = .no }
        m.finish()
        m.edit(.portal)
        m.endEdit()
        XCTAssertFalse(m.record.editing)
        XCTAssertTrue(m.record.completed)
        XCTAssertEqual(m.record.choices.portal, .no)
    }

    func testAnyMoveClearsAStaleRelaunchMarker() {
        let d = defaults()
        var m = TBDOnboardingMachine(store: TBDOnboardingStore(defaults: d))
        _ = m.launch()
        m.edit(.permissions)
        // The quit was cancelled (Listening guard): the person goes on in the same process.
        m.markRelaunch(pid: 1)
        m.back()
        XCTAssertNil(m.record.relaunch)
        m.markRelaunch(pid: 1)
        m.edit(.models)
        XCTAssertNil(m.record.relaunch)
        m.markRelaunch(pid: 1) // moves the step to Permissions
        XCTAssertTrue(m.forward(TBDOnboardingChecks(granted: allGranted)))
        XCTAssertNil(TBDOnboardingStore(defaults: d).load()?.relaunch)
    }

    func testARecordFromAnotherVersionNeverResetsTheFlow() throws {
        let d = defaults()
        // A later version added fields; an earlier one had fewer. Both still load.
        let json = #"{"version":2,"step":"models","completed":false,"editing":false,"newField":true,"choices":{"portal":"no","agent":"maybe","permissionsNotNow":["microphone","camera"]},"updatedAt":"2026-10-19T10:00:00Z"}"#
        d.set(Data(json.utf8), forKey: TBDOnboardingStore.key)
        let record = try XCTUnwrap(TBDOnboardingStore(defaults: d).load())
        XCTAssertEqual(record.step, .models)
        XCTAssertEqual(record.choices.portal, .no)
        XCTAssertNil(record.choices.agent, "an unknown answer reads as not answered")
        XCTAssertEqual(record.choices.permissionsNotNow, [.microphone])
        d.set(Data(#"{"step":"permissions"}"#.utf8), forKey: TBDOnboardingStore.key)
        XCTAssertEqual(TBDOnboardingStore(defaults: d).load()?.step, .permissions)
    }

    func testAnInstallThatFinishedTheOldSetupOpensOnceAtTheSummary() {
        let d = defaults()
        d.set(true, forKey: TBDOnboardingStore.legacyDoneKey)
        var m = TBDOnboardingMachine(store: TBDOnboardingStore(defaults: d))
        XCTAssertEqual(m.launch(), .flow(.summary, editing: true))
        m.finish()
        var again = TBDOnboardingMachine(store: TBDOnboardingStore(defaults: d))
        XCTAssertEqual(again.launch(), .app)
    }

    func testARunningDownloadLetsThePersonGoOn() {
        var m = TBDOnboardingMachine(store: TBDOnboardingStore(defaults: defaults()))
        m.edit(.models)
        XCTAssertFalse(m.isDone(.models, TBDOnboardingChecks()))
        XCTAssertTrue(m.isDone(.models, TBDOnboardingChecks(companionDownload: 0.1, speechDownload: 0.0)))
        m.update { $0.companion = .no; $0.speech = .no }
        XCTAssertTrue(m.isDone(.models, TBDOnboardingChecks()))
    }

    func testSummaryAllOn() {
        let c = TBDOnboardingChecks(signedIn: true, workspaceName: "Studio North", agentModelReady: true, agentModelName: "qwen3:8b",
                                    agentPaired: true, granted: allGranted, companionModelReady: true, companionModelName: "Qwen3-VL 4B",
                                    speechModelOnDisk: true, paidApps: [TBDPaidAppCheck(name: "Knowledge", function: "Save to Knowledge", access: .unlocked)])
        let lines = TBDOnboardingSummary.lines(c)
        XCTAssertEqual(lines.map(\.area), ["Workspace", "TBD's agent", "Screen activity", "Daily and Weekly", "Dictation and meetings", "Notifications", "Knowledge"])
        XCTAssertTrue(lines.allSatisfy(\.on))
        XCTAssertEqual(lines[0].text, "Signed in to Studio North. Your workspace agents and teams are in Chat.")
        XCTAssertEqual(lines[1].text, "TBD's agent runs on this Mac with qwen3:8b.")
        XCTAssertEqual(lines[6].text, "Save to Knowledge works.")
        XCTAssertEqual(TBDOnboardingSummary.headline(lines), "Everything is ready.")
    }

    func testSummarySomeSkippedSaysWhatIsMissingAndTheOneFix() {
        let c = TBDOnboardingChecks(signedIn: true, workspaceName: "Studio North", granted: [.screenRecording, .microphone, .notifications],
                                    paidApps: [TBDPaidAppCheck(name: "Knowledge", function: "Save to Knowledge", access: .locked)])
        let lines = TBDOnboardingSummary.lines(c)
        let off = lines.filter { !$0.on }
        XCTAssertEqual(off.map(\.text), [
            "TBD's agent is off. Chat has only your workspace agents.",
            "No model for Daily and Weekly. Your timeline is recorded, not summarised.",
            "Download the speech model to dictate.",
            "Allow Accessibility to type dictation into other apps.",
            "Knowledge is not in your workspace plan.",
        ])
        XCTAssertEqual(off.map(\.fix), [.step(.agent), .step(.models), .step(.models), .step(.permissions), .portal(app: "Knowledge")])
        XCTAssertEqual(TBDOnboardingSummary.headline(lines), "TBD works. 5 things are off.")
        // No product codes or jargon in the plain lines.
        for line in lines { XCTAssertFalse(line.text.lowercased().contains("provider")); XCTAssertFalse(line.text.lowercased().contains("entitlement")) }
    }

    func testSummaryShowsARunningDownloadAndHidesPaidAppsWhenSignedOut() {
        let c = TBDOnboardingChecks(granted: [.microphone, .accessibility], companionDownload: 0.62, speechDownload: 0.3,
                                    paidApps: [TBDPaidAppCheck(name: "Knowledge", function: "Save to Knowledge", access: .locked)])
        let lines = TBDOnboardingSummary.lines(c)
        XCTAssertTrue(lines.contains { $0.on && $0.text == "The model for Daily and Weekly is downloading (62%). Daily starts when it is done." })
        XCTAssertTrue(lines.contains { $0.on && $0.text == "The speech model is downloading (30%). Dictation works when it is done." })
        XCTAssertFalse(lines.contains { $0.text.contains("Download the speech model") })
        XCTAssertFalse(lines.contains { $0.area == "Knowledge" })
        XCTAssertEqual(lines.first?.text, "Not signed in. Chat shows only TBD's own agent.")
    }

    func testSummaryNamesTheCloudProvider() {
        var c = TBDOnboardingChecks(agentModelReady: true, agentModelName: "us.anthropic.claude-sonnet-4-6")
        c.agentCloud = "Amazon Bedrock"
        XCTAssertEqual(TBDOnboardingSummary.lines(c).first { $0.area == "TBD's agent" }?.text,
                       "TBD's agent runs on this Mac and uses us.anthropic.claude-sonnet-4-6 on Amazon Bedrock.")
    }

    func testSummaryPaidAppLinesFromTheEntitlements() {
        let paid = TBDEntitlements(apps: [.knowledge: .install], workspace: "ws1")
        let c = TBDOnboardingChecks(signedIn: true, workspaceName: "W", paidApps: paid.summaryChecks)
        let line = TBDOnboardingSummary.lines(c).first { $0.area == "Knowledge" }
        XCTAssertEqual(line?.on, false)
        XCTAssertEqual(line?.text, "Your plan has Knowledge. Install it in your workspace to use Save to Knowledge.")
        XCTAssertEqual(line?.fix, .portal(app: "Knowledge"))
        // Unknown (no read) = locked: never unlock without a read (C282).
        XCTAssertEqual(TBDEntitlements.none.summaryChecks.first?.access, .locked)
        let unlocked = TBDEntitlements(apps: [.knowledge: .unlocked], workspace: "ws1").summaryChecks
        XCTAssertEqual(TBDOnboardingSummary.lines(TBDOnboardingChecks(signedIn: true, workspaceName: "W", paidApps: unlocked))
            .first { $0.area == "Knowledge" }?.text, "Save to Knowledge works.")
    }

    func testSummarySaysWhenCaptureIsPaused() {
        let c = TBDOnboardingChecks(granted: [.screenRecording], capturePaused: true)
        XCTAssertEqual(TBDOnboardingSummary.lines(c).first { $0.area == "Screen activity" }?.text,
                       "Screen recording is allowed. Capture is paused now; start it from the menu bar.")
    }

    func testSubscriptionIsHiddenForTheAgentSDKAndShownForTheCLI() {
        // C287: no Claude.ai login in an Agent SDK app; only the person's own CLI.
        XCTAssertFalse(TBDSubscriptionPolicy.isAllowed(.claudeAgentSDK))
        XCTAssertTrue(TBDSubscriptionPolicy.isAllowed(.claudeCodeCLI))
        XCTAssertFalse(TBDSubscriptionPolicy.isAllowed(.eve))
        XCTAssertFalse(TBDSubscriptionPolicy.isAllowed(.langChain))
    }
}
