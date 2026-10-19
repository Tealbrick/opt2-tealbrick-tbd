import TBDDesign
import TBDModels
import SwiftUI

struct TBDAboutView: View {
  @AppStorage(TBDProductLinks.supportKey) private var support = ""
  var body: some View {
    VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
      SettingsSection(title: "", isFirst: true) {   // the pane header "About" names it
        VStack(alignment: .leading, spacing: TBDKit.s4) {
          Text("Chat · Companion · Listen")
            .font(TBDTokens.Typography.body)
            .foregroundStyle(TBDColor.ink)
          TBDUpdatesSection()
          Link("Website", destination: TBDProductLinks.website)
            .font(TBDTokens.Typography.control)
            .foregroundStyle(TBDColor.link)
            .tint(TBDColor.link)
          TextField("Support URL (https://…)", text: $support).tbdField()
          if let url = TBDProductLinks.support() {
            Link("Open support", destination: url)
              .font(TBDTokens.Typography.control)
              .foregroundStyle(TBDColor.link)
              .tint(TBDColor.link)
          } else {
            Text("Support is not configured. No reports are sent to upstream projects.")
              .font(TBDTokens.Typography.hint)
              .foregroundStyle(TBDColor.muted)
          }
        }
      }
      SettingsSection(title: String(localized: "Privacy")) {
        Text("Speech recognition runs on this Mac. AI cleanup, summaries and screen analysis use the models you select and may send text or screenshots to a network endpoint. Vendor telemetry is disabled. Diagnostic files and histories remain local unless you explicitly export them.")
          .font(TBDTokens.Typography.body)
          .foregroundStyle(TBDColor.inkSoft)
      }
      SettingsSection(title: String(localized: "Data")) {
        Text("Storage manages screenshots and timelapses. System manages speech history, audio retention and downloads. Voice notes keep their raw transcript alongside optional cleanup; interrupted note audio remains in Listening/VoiceNotes for recovery.")
          .font(TBDTokens.Typography.body)
          .foregroundStyle(TBDColor.inkSoft)
      }
      SettingsSection(title: String(localized: "Open-source components")) {
        Text("Companion includes Dayflow (MIT); Chat started from an MIT-licensed chat client; Listen is a Tealbrick rewrite of MacParakeet's features (GPL-3.0) and uses FluidAudio (Apache-2.0), WhisperKit (MIT) and GRDB (MIT). Licences are bundled with this app. For video links Listen downloads yt-dlp (Unlicense) from its official GitHub release on first use.")
          .font(TBDTokens.Typography.hint)
          .foregroundStyle(TBDColor.inkSoft)
      }
    }
  }
}
