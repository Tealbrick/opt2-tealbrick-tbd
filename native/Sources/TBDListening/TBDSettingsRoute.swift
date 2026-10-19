import Foundation

/// The host's Settings navigation (TBD-UX-01): one side-nav item per pane. The section names that links,
/// notifications and the menu bar send stay stable; three of them ("engine", "providers", "audioAI") are
/// pages of the one Models pane (v1 had one "Models" rail item and hid the other two).
public enum TBDSettingsRoute {
    /// One side-nav item, in the order shown.
    public enum Item: String, CaseIterable, Sendable {
        case account, models, permissions, connectors, other, about
        case privacy, storage, aiTools, data
        case capture, audioSystem

        public var title: String {
            switch self {
            case .account: return "Account"
            case .models: return "Models"
            case .permissions: return "Access"
            case .connectors: return "Connectors"
            case .other: return "General"
            case .about: return "About"
            case .privacy: return "Screen capture"
            case .storage: return "Storage"
            case .aiTools: return "Tools"
            case .data: return "Export"
            case .capture: return "Capture"
            case .audioSystem: return "System"
            }
        }

        /// One line under the pane title.
        public var subtitle: String {
            switch self {
            case .account: return "Your Teal Brick Portal sign-in and workspace."
            case .models: return "The models TBD uses for its agent, summaries, cleanup and screen analysis."
            case .permissions: return "The macOS permissions TBD needs."
            case .connectors: return "The accounts TBD's agent may use through Connect, and your choices for it."
            case .other: return "Language, appearance and how TBD starts."
            case .about: return "Version, updates and licences."
            case .privacy: return "Choose apps TBD should hide from screenshots."
            case .storage: return "Space used by screen recordings and timelapses."
            case .aiTools: return "The Companion command and its edit access for agents."
            case .data: return "Move your Companion timeline into tools you already use."
            case .capture: return "Microphone, dictation, transcription and meeting capture."
            case .audioSystem: return "Dictation history, retention and Listen storage."
            }
        }

        /// The section name this item opens.
        public var section: String { self == .models ? "engine" : rawValue }
    }

    /// Side-nav groups: the app first, then TBD's capture aspects (C142).
    public static let groups: [(title: String, items: [Item])] = [
        ("App", [.account, .models, .permissions, .connectors, .other, .about]),
        ("Companion", [.privacy, .storage, .aiTools, .data]),
        ("Listen", [.capture, .audioSystem]),
    ]

    /// Every section name the host accepts (deep links, notifications, the menu bar, design shots).
    public static let sections = [
        "account", "about", "permissions", "connectors", "storage", "privacy", "providers", "aiTools", "data", "other",
        "capture", "engine", "audioAI", "audioSystem",
    ]

    /// The pages of the Models pane.
    public static let modelsPages = ["Tasks", "Connections", "Transcription", "Advanced"]

    /// The side-nav item that is current for a section; nil for a name the host does not know.
    public static func item(for section: String) -> Item? {
        switch section {
        case "engine", "providers", "audioAI": return .models
        default: return Item(rawValue: section)
        }
    }

    /// The Models page a section opens; nil for every other pane.
    public static func modelsPage(for section: String) -> String? {
        switch section {
        case "engine": return "Tasks"
        case "providers": return "Advanced"
        case "audioAI": return "Transcription"
        default: return nil
        }
    }
}
