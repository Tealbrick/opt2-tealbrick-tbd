import SwiftUI
import TBDDesign
import TBDSpeech

/// The detail view's Knowledge control: "Save to Knowledge", progress, or "Saved to Knowledge".
struct TBDKnowledgeButton: View {
    let item: TBDTranscription
    @ObservedObject var knowledge: TBDKnowledgeController
    @State private var sheet = false

    var body: some View {
        let _ = knowledge.revision
        Group {
            if let link = knowledge.link(for: item.id) {
                Label("Saved to Knowledge", systemImage: "checkmark.circle").font(TBDTokens.Typography.body).foregroundStyle(TBDColor.muted)
                    .help("Knowledge document \(link.documentId)")
            } else if let availability = knowledge.availability {
                TBDAvailableWith(availability)   // C282: Knowledge is not paid for or not installed in this workspace
            } else if let status = knowledge.status[item.id] {
                HStack(spacing: TBDTokens.Space.xs) {
                    ProgressView().controlSize(.small)
                    Text(status).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
                }
            } else {
                HStack(spacing: TBDTokens.Space.xs) {
                    Button { sheet = true } label: { Label("Save to Knowledge", systemImage: "books.vertical") }
                        .buttonStyle(TBDButtonStyle(.secondary)).disabled(item.status != .completed)
                    if let failure = knowledge.failures[item.id] {
                        Image(systemName: "exclamationmark.triangle").font(TBDFonts.symbol(14)).foregroundStyle(TBDColor.brickInk).help(failure)
                            .accessibilityLabel("Save to Knowledge failed: \(failure)")
                    }
                }
            }
        }
        // On the container: the sheet stays open while the button turns into progress.
        .sheet(isPresented: $sheet) { TBDKnowledgeSaveSheet(item: item, knowledge: knowledge) }
    }
}

/// Title and tags the person can edit before saving; the body is the transcript with a header block.
struct TBDKnowledgeSaveSheet: View {
    let item: TBDTranscription
    @ObservedObject var knowledge: TBDKnowledgeController
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var tags: [String] = []
    @State private var newTag = ""
    @State private var suggesting = true
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.md) {
            Text("Save to Knowledge").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
            TBDLabel("Title")
            TextField("Title", text: $title).tbdField()
            TBDLabel("Tags")
            HStack(spacing: TBDTokens.Space.xs) {
                ForEach(tags, id: \.self) { tag in
                    Button { tags.removeAll { $0 == tag } } label: { Label(tag, systemImage: "xmark") }
                        .buttonStyle(TBDButtonStyle(.quiet)).help("Remove tag").accessibilityLabel("Remove tag \(tag)")
                }
                if suggesting { ProgressView().controlSize(.small); Text("Suggesting tags…").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted) }
            }
            TextField("Add a tag and press Return", text: $newTag).tbdField()
                .onSubmit { tags = TBDKnowledgeTags.normalize(tags + [newTag]); newTag = "" }
            TBDLabel("Header")
            Text(TBDKnowledgeDocument.header(item).joined(separator: "\n"))
                .font(TBDFonts.mono()).foregroundStyle(TBDColor.muted).textSelection(.enabled)
            Text("The transcript text follows the header. TBD's agent saves it with its own access; the owner may need to approve.")
                .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).fixedSize(horizontal: false, vertical: true)
            if let status = knowledge.status[item.id] {
                HStack(spacing: TBDTokens.Space.xs) { ProgressView().controlSize(.small); Text(status).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted) }
            }
            if let error { Text(error).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.brickInk).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(saving ? "Close" : "Cancel") { dismiss() }.buttonStyle(TBDButtonStyle(.quiet))
                Button("Save") { save() }.buttonStyle(TBDButtonStyle(.primary))
                    .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(TBDTokens.Space.xl)
        .frame(width: 460)
        .background(TBDColor.tile)
        .task {
            title = item.title
            let suggested = await knowledge.suggestTags(item)
            tags = TBDKnowledgeTags.normalize(tags + suggested)
            suggesting = false
        }
    }

    private func save() {
        let pending = newTag.trimmingCharacters(in: .whitespaces)
        let request = TBDKnowledgeDocument.request(for: item, title: title, tags: pending.isEmpty ? tags : tags + [pending])
        saving = true; error = nil
        Task {
            do {
                try await knowledge.save(request)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}

/// Listening Settings › AI: automatic saves per transcript kind (default off).
struct TBDKnowledgeSettings: View {
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var tick = 0

    var body: some View {
        let prefs = env.preferences
        VStack(alignment: .leading, spacing: 0) {
            TBDLabel("Save to Knowledge").padding(.top, TBDTokens.Space.xl).padding(.bottom, TBDTokens.Space.xs)
            Text("Finished transcripts of these kinds are saved to Knowledge by TBD's agent, with suggested tags. Use “Save to Knowledge” on a transcript to save it by hand.")
                .font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft).fixedSize(horizontal: false, vertical: true).padding(.bottom, TBDTokens.Space.sm)
            TBDSettingsRow("Meetings") {
                Toggle("", isOn: tbdBinding({ prefs.autoSaveMeetingsToKnowledge }, { prefs.autoSaveMeetingsToKnowledge = $0 }, refresh: { tick += 1 }))
                    .labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize()
            }
            TBDSettingsRow("Link and YouTube transcripts") {
                Toggle("", isOn: tbdBinding({ prefs.autoSaveLinksToKnowledge }, { prefs.autoSaveLinksToKnowledge = $0 }, refresh: { tick += 1 }))
                    .labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize()
            }
        }
        .id(tick)
    }
}
