import SwiftUI
import TBDDesign
import TBDSpeech

/// Hotkeys and dictation behaviour. Words, snippets and the text pipeline live on the Vocabulary page.
struct TBDDictationSettings: View {
    let context: TBDListeningContext
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var tick = 0

    var body: some View {
        let prefs = env.preferences
        VStack(alignment: .leading, spacing: 0) {
            TBDDictationHotkeyRows(context: context) { tick += 1 }
            TBDHotkeyRow(title: "Transform hotkey", help: "Rewrites the selected text with the current transform prompt.",
                         surface: .transform, context: context) { tick += 1 }
            TBDDictationPillSettings(context: context)
            TBDSettingsRow("Undo window", help: "How long cancel waits before discarding a dictation. Undo in the pill transcribes and pastes it.") {
                TBDSegmented(selection: tbdBinding({ prefs.dictationUndoWindow }, { prefs.dictationUndoWindow = $0 }, refresh: { tick += 1 }),
                             options: TBDCancelUndo.Window.allCases.map { ($0, $0.title) })
            }
            TBDDictationBehaviorSettings(context: context)
            TBDSettingsRow("Accessibility", help: "Needed for global hotkeys and pasting into other apps.") {
                if TBDPasteService.isTrusted && !context.hotkeyPermissionMissing {
                    TBDTag("Allowed", status: .live)
                } else {
                    Button("Allow…") { TBDPasteService.requestTrust(); TBDPasteService.openAccessibilitySettings() }
                        .buttonStyle(TBDButtonStyle(.secondary))
                }
            }
            TBDDictationTextSettings()
            TBDSettingsRow("Vocabulary", help: "Processing mode, filler removal, custom words, snippets, spoken punctuation and backup are on the Vocabulary page.") {
                Button("Open Vocabulary") { env.selectedTab = .vocabulary; context.bringToFront() }
                    .buttonStyle(TBDButtonStyle(.secondary))
            }
        }
        .id(tick)
    }
}

/// v1 Capture > Dictation hotkey rows: push to talk, hands-free, clipboard-only, AI polish, and the mode guide.
struct TBDDictationHotkeyRows: View {
    let context: TBDListeningContext
    let onChanged: () -> Void

    var body: some View {
        let prefs = context.env.preferences
        let handsFree = prefs.hotkey(for: .handsFree)
        let pushToTalk = prefs.hotkey(for: .pushToTalk)
        let shared = TBDDictationHotkeyPlan.isSharedGesture(handsFree: handsFree, pushToTalk: pushToTalk)
        VStack(alignment: .leading, spacing: 0) {
            TBDHotkeyRow(title: "Push to talk", help: "Hold to dictate, release to stop.", surface: .pushToTalk, context: context,
                         displayOverride: TBDDictationHotkeyPlan.pushToTalkLabelOverride(pushToTalk: pushToTalk, handsFree: handsFree),
                         onChanged: onChanged)
            TBDHotkeyRow(title: "Hands-free mode", help: shared ? "Double-tap to start; tap again to stop." : "Tap to start; tap again to stop.",
                         surface: .handsFree, context: context,
                         displayOverride: TBDDictationHotkeyPlan.handsFreeLabelOverride(handsFree: handsFree, pushToTalk: pushToTalk),
                         defaultLabelOverride: TBDDictationHotkeyPlan.handsFreeLabelOverride(handsFree: .fn, pushToTalk: pushToTalk),
                         onChanged: onChanged)
            TBDHotkeyRow(title: "Clipboard-only dictation",
                         help: "Optional extra shortcut. Tap to start or stop like hands-free. Copies the transcript instead of pasting into the focused field.",
                         surface: .dictationClipboard, context: context, onChanged: onChanged)
            TBDHotkeyRow(title: "AI polish this dictation",
                         help: "Optional extra shortcut. Tap to start or stop like hands-free (no hold-to-talk). Always runs cleanup for that take, even when dictation cleanup is off. Needs a model on the Cleanup route.",
                         surface: .dictationAIPolish, context: context, onChanged: onChanged)
            let guide = Self.guide(handsFree: handsFree, pushToTalk: pushToTalk, clipboard: prefs.hotkey(for: .dictationClipboard),
                                   aiPolish: prefs.hotkey(for: .dictationAIPolish))
            if !guide.isEmpty {
                VStack(alignment: .leading, spacing: TBDTokens.Space.xs) {
                    ForEach(guide, id: \.action) { row in
                        HStack(spacing: TBDTokens.Space.sm) {
                            TBDKeyCap(row.key)
                            Text(row.verb).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).lineLimit(1).fixedSize().frame(minWidth: 88, alignment: .leading)
                            Text(row.action).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
                            Text(row.detail).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                        }
                    }
                }
                .padding(.vertical, TBDTokens.Space.md)
            }
        }
    }

    struct GuideRow: Equatable {
        let key: String
        let verb: String
        let action: String
        let detail: String
    }

    /// v1 `dictationModeGuide`: one line per enabled dictation key.
    static func guide(handsFree: TBDHotkey?, pushToTalk: TBDHotkey?, clipboard: TBDHotkey?, aiPolish: TBDHotkey?) -> [GuideRow] {
        var rows: [GuideRow] = []
        if let pushToTalk { rows.append(GuideRow(key: pushToTalk.shortSymbol, verb: "Hold", action: "Push to talk", detail: "Release to stop")) }
        if let handsFree {
            let verb = TBDDictationHotkeyPlan.isSharedGesture(handsFree: handsFree, pushToTalk: pushToTalk) ? "Double-tap" : "Tap"
            rows.append(GuideRow(key: handsFree.shortSymbol, verb: verb, action: "Hands-free mode", detail: "Tap again to stop"))
        }
        if let clipboard { rows.append(GuideRow(key: clipboard.shortSymbol, verb: "Tap", action: "Clipboard-only", detail: "Copies; does not paste")) }
        if let aiPolish { rows.append(GuideRow(key: aiPolish.shortSymbol, verb: "Tap", action: "AI polish", detail: "Cleans this dictation")) }
        return rows
    }
}
