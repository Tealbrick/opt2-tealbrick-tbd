// tbd-design-shots: renders TBD screens and the TBDDesign component sheet to PNG (light and dark, 2x) and runs a
// RENDERED contrast check on every screen.
// Usage: swift run tbd-design-shots <outDir> [prefix]
// The views are the real TBDDesign / TBDListening views in an offscreen NSHostingView. Settings use an isolated
// UserDefaults suite and an in-memory key store; Listen runs on a seeded scratch library (TBD_LISTENING_ROOT) without
// starting capture, hotkeys or downloads. Nothing reads or writes the person's settings, library or Keychain.
// Contrast (rendered): each screen is rendered twice, as is and `.redacted(.placeholder)`; the pixels that differ are the
// text. For each text box the ground is the commonest colour around it and the ink the 97th-percentile-contrast pixel
// inside (glyph cores). The ink is matched to a kit colour: text inks need 4.5 (3.0 for lines 30pt and taller), marks and
// control edges 3.0, washes and hairlines are decoration. Boxes whose ink is no kit colour (anti-aliased edges that moved)
// are counted as "unclassified". Report: <outDir>/<prefix>-native-contrast.json; exit 1 on any failure.
import AppKit
import SwiftUI
import TBDDesign
import TBDListening
import TBDModels
import TBDSpeech

// Before anything touches TBDListeningPaths: a scratch Listening root for this run only.
let listenRoot = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-design-shots-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
setenv(TBDListeningPaths.rootEnvironmentKey, listenRoot.path, 1)
defer { try? FileManager.default.removeItem(at: listenRoot) }

let args = CommandLine.arguments
guard args.count >= 2 else { FileHandle.standardError.write(Data("usage: tbd-design-shots <outDir> [prefix] | --sameness <outDir>\n".utf8)); exit(2) }
// Sameness proof (native column): `tbd-design-shots --sameness <outDir>` -> Sameness.swift, then exit.
if args[1] == "--sameness" {
    guard args.count >= 3 else { FileHandle.standardError.write(Data("usage: tbd-design-shots --sameness <outDir>\n".utf8)); exit(2) }
    do { try MainActor.assumeIsolated { try runSameness(outDir: URL(fileURLWithPath: args[2], isDirectory: true)) } }
    catch { FileHandle.standardError.write(Data("tbd-design-shots --sameness: \(error)\n".utf8)); exit(1) }
    exit(0)
}
// WP3 shell mockups (static, not app code): `tbd-design-shots --shell-mockups <outDir>` -> ShellMockups.swift, then exit.
let shellMockups = args[1] == "--shell-mockups"
if shellMockups && args.count < 3 { FileHandle.standardError.write(Data("usage: tbd-design-shots --shell-mockups <outDir>\n".utf8)); exit(2) }
let outDir = URL(fileURLWithPath: shellMockups ? args[2] : args[1], isDirectory: true)
let prefix = shellMockups ? "shell" : (args.count >= 3 ? args[2] : "tbd")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
TBDFonts.register()

@MainActor func bitmap<V: View>(_ view: V, size: CGSize, dark: Bool) throws -> (NSBitmapImageRep, NSView) {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(2.0))   // lets async loads (the library list) land
    host.layoutSubtreeIfNeeded()
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw CocoaError(.fileWriteUnknown) }
    rep.size = size
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        host.cacheDisplay(in: host.bounds, to: rep)
    }
    return (rep, host)
}

struct ContrastFailure: Encodable { let screen: String; let x: Int; let y: Int; let w: Int; let h: Int; let ink: String; let ground: String; let ratio: Double; let need: Double }
struct ScreenResult: Encodable { let screen: String; let textBoxes: Int; let failures: Int; let unclassified: Int }
var failures: [ContrastFailure] = []
var results: [ScreenResult] = []

@MainActor func render<V: View>(_ view: V, size: CGSize, dark: Bool, to name: String, audit: Bool = true) throws {
    let (rep, _) = try bitmap(view, size: size, dark: dark)
    guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    let url = outDir.appendingPathComponent("\(name).png")
    try png.write(to: url)
    print(url.path)
    guard audit else { return }
    let (redacted, _) = try bitmap(view.redacted(reason: .placeholder), size: size, dark: dark)
    let (count, fails, unclassified) = auditContrast(rep, redacted, dark: dark, screen: name)
    results.append(ScreenResult(screen: name, textBoxes: count, failures: fails.count, unclassified: unclassified))
    failures += fails
}

typealias RGB = (Int, Int, Int)
/// Kit colours resolved for one appearance, to classify what was drawn.
func palette(dark: Bool) -> [(String, RGB)] {
    var out: [(String, RGB)] = []
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        for (name, color) in TBDColor.all {
            guard let c = NSColor(color).usingColorSpace(.sRGB), c.alphaComponent > 0.99 else { continue }
            out.append((name, (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))))
        }
    }
    return out
}
/// Text inks need 4.5; marks and control edges 3.0; washes, hairlines and grounds are decoration (not checked).
let decorative: Set<String> = ["line", "tealWashLine", "statusIdleEdge", "statusLiveEdge", "statusBusyEdge", "plate", "tealWash", "brickWash",
                               "selection", "paper", "tile", "film", "filmFrame", "spotPaper", "handSwatch", "scrollTrack", "scrollThumb",
                               "scrollThumbHover", "optionHoverFill", "disabledFill", "disabledOn", "optionDisabledOn"]
let uiOnly: Set<String> = ["lineStrong", "fieldEdge", "quietEdge", "tabEdge", "teal", "brick", "toneTeal", "toneBrick", "toneStone", "toneWood",
                           "toneMoss", "wireLive", "countFill", "dangerEdge", "fieldInvalidEdge", "danger", "scrollThumbActive"]

/// Rendered contrast (see the header). Returns (text boxes checked, failures, boxes whose ink is not a kit colour).
func auditContrast(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, dark: Bool, screen: String) -> (Int, [ContrastFailure], Int) {
    let w = a.pixelsWide, h = a.pixelsHigh
    guard let pa = a.bitmapData, let pb = b.bitmapData else { return (0, [], 0) }
    let rowA = a.bytesPerRow, rowB = b.bytesPerRow, spp = a.samplesPerPixel
    func px(_ p: UnsafeMutablePointer<UInt8>, _ row: Int, _ x: Int, _ y: Int) -> RGB { let o = y * row + x * spp; return (Int(p[o]), Int(p[o + 1]), Int(p[o + 2])) }
    let kit = palette(dark: dark)
    func token(_ c: RGB) -> String? {
        var best: (String, Int)?
        for (n, k) in kit { let d = abs(k.0 - c.0) + abs(k.1 - c.1) + abs(k.2 - c.2); if d <= 9, d < (best?.1 ?? .max) { best = (n, d) } }
        return best?.0
    }
    var mask = [Bool](repeating: false, count: w * h)
    for y in 0..<h { for x in 0..<w {
        let p = px(pa, rowA, x, y), q = px(pb, rowB, x, y)
        if abs(p.0 - q.0) + abs(p.1 - q.1) + abs(p.2 - q.2) > 60 { mask[y * w + x] = true }
    } }
    // Connected boxes on a 6px cell grid (joins the letters of a line, keeps lines apart).
    let cell = 6, cw = (w + cell - 1) / cell, ch = (h + cell - 1) / cell
    var on = [Bool](repeating: false, count: cw * ch)
    for y in 0..<h { for x in 0..<w where mask[y * w + x] { on[(y / cell) * cw + x / cell] = true } }
    var seen = [Bool](repeating: false, count: cw * ch)
    var boxes: [(Int, Int, Int, Int)] = []
    for start in 0..<(cw * ch) where on[start] && !seen[start] {
        var stack = [start]; seen[start] = true
        var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
        while let c = stack.popLast() {
            let cx = c % cw, cy = c / cw
            minX = min(minX, cx); maxX = max(maxX, cx); minY = min(minY, cy); maxY = max(maxY, cy)
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = cx + dx, ny = cy + dy
                guard nx >= 0, ny >= 0, nx < cw, ny < ch else { continue }
                let n = ny * cw + nx
                if on[n] && !seen[n] { seen[n] = true; stack.append(n) }
            }
        }
        boxes.append((minX * cell, minY * cell, min(w, (maxX + 1) * cell), min(h, (maxY + 1) * cell)))
    }
    func lum(_ c: RGB) -> Double {
        func f(_ v: Int) -> Double { let x = Double(v) / 255; return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(c.0) + 0.7152 * f(c.1) + 0.0722 * f(c.2)
    }
    func ratio(_ p: RGB, _ q: RGB) -> Double { let l1 = lum(p), l2 = lum(q); return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05) }
    func hex(_ c: RGB) -> String { String(format: "#%02x%02x%02x", c.0, c.1, c.2) }
    var out: [ContrastFailure] = []
    var counted = 0, unclassified = 0
    for (x0, y0, x1, y1) in boxes where (x1 - x0) >= 16 && (y1 - y0) >= 16 {
        // Ground: the commonest colour on a ring just outside the box.
        var counts: [Int: Int] = [:]
        for y in max(0, y0 - 4)..<min(h, y1 + 4) { for x in max(0, x0 - 4)..<min(w, x1 + 4) {
            if (x >= x0 - 1 && x < x1 + 1 && y >= y0 - 1 && y < y1 + 1) || mask[y * w + x] { continue }
            let c = px(pa, rowA, x, y); counts[(c.0 << 16) | (c.1 << 8) | c.2, default: 0] += 1
        } }
        guard let g = counts.max(by: { $0.value < $1.value })?.key else { continue }
        let ground: RGB = (g >> 16 & 255, g >> 8 & 255, g & 255)
        var ratios: [(Double, RGB)] = []
        for y in y0..<y1 { for x in x0..<x1 where mask[y * w + x] { let c = px(pa, rowA, x, y); ratios.append((ratio(c, ground), c)) } }
        guard ratios.count >= 12 else { continue }
        ratios.sort { $0.0 < $1.0 }
        guard let top = ratios.last, top.0 >= 1.5 else { continue }   // nothing drawn: a shape that only moved
        let ink = ratios[min(ratios.count - 1, Int(Double(ratios.count) * 0.97))]
        guard let name = token(ink.1) else {
            unclassified += 1
            if ProcessInfo.processInfo.environment["TBD_SHOTS_DEBUG"] != nil {
                let near = kit.min { abs($0.1.0 - ink.1.0) + abs($0.1.1 - ink.1.1) + abs($0.1.2 - ink.1.2) < abs($1.1.0 - ink.1.0) + abs($1.1.1 - ink.1.1) + abs($1.1.2 - ink.1.2) }
                print("UNCL \(screen) (\(x0 / 2),\(y0 / 2) \((x1 - x0) / 2)x\((y1 - y0) / 2)) \(hex(ink.1)) on \(hex(ground)) r=\((ink.0 * 100).rounded() / 100) near=\(near?.0 ?? "")")
            }
            continue
        }   // anti-aliased blend of an edge
        if decorative.contains(name) { continue }
        counted += 1
        let large = Double(y1 - y0) / 2 >= 30
        let need = uiOnly.contains(name) || large ? 3.0 : 4.5
        if ink.0 < need {
            out.append(ContrastFailure(screen: screen, x: x0 / 2, y: y0 / 2, w: (x1 - x0) / 2, h: (y1 - y0) / 2,
                                       ink: "\(name) \(hex(ink.1))", ground: hex(ground), ratio: (ink.0 * 100).rounded() / 100, need: need))
        }
    }
    return (counted, out, unclassified)
}

/// An isolated registry with a stored Anthropic key, so the form opens in its "key stored" state.
func isolatedRegistry() -> TBDModelRegistry {
    let suite = "tbd.design-shots.\(ProcessInfo.processInfo.processIdentifier)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let registry = TBDModelRegistry(defaults: defaults, credentials: TBDMemorySecretStore())
    _ = try? TBDAgentModelSetup.save(provider: .anthropic, endpoint: "", apiKey: "demo-key-not-real", model: TBDAgentModelSetup.defaultModel, registry: registry)
    return registry
}

/// Settings → Models as the companion lays it out (TBDModelsView): page header, page picker, the one-form setup.
struct ModelsProof: View {
    let registry: TBDModelRegistry
    @State private var page = "Tasks"
    var body: some View {
        VStack(alignment: .leading, spacing: TBDKit.s6) {
            TBDPageHeader("Models", label: "Settings")
            TBDSegmented(selection: $page, options: ["Tasks", "Connections", "Transcription", "Advanced"].map { ($0, $0) })
            Text("Choose a connection once and reuse it. No automatic fallback between providers.")
                .font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft)
            TBDAgentModelForm(registry: registry) {}
            Spacer(minLength: 0)
        }
        .padding(TBDKit.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TBDColor.paper)
    }
}

struct Row<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        HStack(alignment: .center, spacing: TBDKit.s4) {
            Text(title).font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted).frame(width: 110, alignment: .leading)
            content
        }
    }
}

/// Every TBDDesign component in every state (forced like the kit's .is-hover / .is-focus specimen classes).
struct ComponentSheet: View {
    @State private var text = "claude-opus-5-5"
    @State private var empty = ""
    @State private var choice = "Anthropic"
    @State private var on = true
    @State private var off = false
    @State private var step = 1
    private let states: [(String, TBDControlState?)] = [("Default", nil), ("Hover", .hover), ("Pressed", .pressed), ("Focus", .focus)]
    var body: some View {
        HStack(alignment: .top, spacing: TBDKit.s8) {
            VStack(alignment: .leading, spacing: TBDKit.s4) {
                TBDPageHeader("TBDDesign", label: "Components")
                ForEach([("Primary", TBDButtonRole.primary), ("Secondary", .secondary), ("Quiet", .quiet), ("Destructive", .destructive), ("Confirm", .destructiveConfirm)], id: \.0) { name, role in
                    Row(title: name) {
                        ForEach(states, id: \.0) { label, state in
                            Button(label) {}.buttonStyle(TBDButtonStyle(role)).environment(\.tbdForcedState, state)
                        }
                        Button("Disabled") {}.buttonStyle(TBDButtonStyle(role)).disabled(true)
                    }
                }
                Row(title: "Icon, large") {
                    Button {} label: { Image(systemName: "plus") }.buttonStyle(TBDButtonStyle(.icon))
                    Button {} label: { Image(systemName: "mic") }.buttonStyle(TBDButtonStyle(.icon)).environment(\.tbdForcedState, .hover)
                    Button("Save and continue") {}.buttonStyle(TBDButtonStyle(.primary, size: .large))
                }
                Row(title: "Fields") {
                    TBDField("Model ID", text: $text).frame(width: 200)
                    TBDField("Hover", text: $text).frame(width: 160).environment(\.tbdForcedState, .hover)
                    TBDField("Focus", text: $empty, prompt: "Placeholder").frame(width: 160).environment(\.tbdForcedState, .focus)
                }
                Row(title: "") {
                    TBDField("Invalid", text: $empty, prompt: "https://", error: "Enter an https address.").frame(width: 200)
                    TBDField("Disabled", text: $text).frame(width: 160).disabled(true)
                    TBDSelect("Select", selection: $choice, options: [("Anthropic", "Anthropic"), ("Compatible", "Anthropic-compatible")]).frame(width: 200)
                }
                Row(title: "Tags") {
                    TBDTag("Idle"); TBDTag("Online", status: .live); TBDTag("Running", status: .busy)
                    TBDTag("Needs you", status: .needsYou); TBDTag("Not deployed", status: .open)
                    TBDCount(3); TBDCount(12, ink: true)
                }
                Row(title: "Chips") {
                    TBDFilterChip("Meetings", isOn: $on); TBDFilterChip("Dictation", isOn: $off)
                    TBDFilterChip("Hover", isOn: $off).environment(\.tbdForcedState, .hover)
                    TBDChip("Listen", color: TBDColor.teal)
                }
                Row(title: "Switch") {
                    Toggle("Clean up voice notes", isOn: $on).toggleStyle(TBDSwitchStyle()).frame(width: 240)
                    Toggle("Off", isOn: $off).toggleStyle(TBDSwitchStyle()).frame(width: 120)
                }
                Row(title: "Segmented") {
                    TBDSegmented(selection: $choice, options: [("Anthropic", "Anthropic"), ("Compatible", "Anthropic-compatible")])
                    TBDStatusPill("Recording 02:14", tone: TBDColor.brick)
                }
                Row(title: "Notices") {
                    TBDNotice("Saved. Go back to Chat.", tone: .live).frame(width: 220)
                    TBDNotice("The API key was refused.", tone: .needsYou).frame(width: 220)
                    TBDNotice("Neutral notice.").frame(width: 160)
                }
            }
            VStack(alignment: .leading, spacing: TBDKit.s4) {
                TBDKicker("StepFlow (C126, C128)")
                TBDStepFlow(steps: [
                    TBDStep("Provider") { Text("Choose a provider.").font(TBDTokens.Typography.body) },
                    TBDStep("Key", optional: true, skipLabel: "Skip, add the key later") {
                        TBDField("API key", text: $empty, prompt: "sk-ant-…", secure: true, hint: "Kept in your Keychain.")
                    },
                    TBDStep("Model", nextLabel: "Save") { Text("Pick a model.") },
                ], current: $step, size: CGSize(width: 480, height: 330)) {}
                .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
                .clipShape(TBDBrickShape())
                Text("Card").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink).frame(maxWidth: .infinity, alignment: .leading).tbdCard()
                Text("Tinted panel").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink).frame(maxWidth: .infinity, alignment: .leading).tbdPanelTint()
                Text("Floating surface").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink).padding(TBDKit.s4).tbdFloating()
            }
            .frame(width: 480)
        }
        .padding(TBDKit.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TBDColor.paper)
    }
}

/// A small demo library in the scratch root (neutral demo content only).
func seedListen() throws -> String {
    let db = try TBDListeningDatabase()
    var meeting = TBDTranscription(title: "Weekly planning", sourceKind: .meeting, status: .completed)
    meeting.durationMs = 1_520_000
    meeting.engine = "parakeet"
    meeting.speakers = [TBDSpeaker(id: "S1", label: "You"), TBDSpeaker(id: "S2", label: "Speaker 2")]
    meeting.segments = [
        TBDSegment(start: 0, end: 6_000, text: "Let's start with the release plan for next week.", speaker: "S1"),
        TBDSegment(start: 6_000, end: 14_000, text: "The design tokens are merged. The Listen screens are next, then Settings.", speaker: "S2"),
        TBDSegment(start: 14_000, end: 21_000, text: "Good. Who owns the screenshots and the contrast check?", speaker: "S1"),
        TBDSegment(start: 21_000, end: 30_000, text: "I do. They run on a scratch library, so nothing touches real data.", speaker: "S2"),
    ]
    meeting.rawText = meeting.segments.map(\.text).joined(separator: " ")
    try db.save(meeting)
    var file = TBDTranscription(title: "Interview notes.m4a", sourceKind: .file, status: .completed)
    file.durationMs = 640_000; file.rawText = "A short interview about onboarding and first-run friction."
    try db.save(file)
    var link = TBDTranscription(title: "Conference talk: building calm tools", sourceKind: .url, sourceURL: "https://example.com/talk", status: .completed)
    link.durationMs = 2_400_000; link.rawText = "Calm tools respect attention."
    try db.save(link)
    try db.save(TBDDictation(durationMs: 4_200, rawText: "Send the agenda to the team before ten.", targetApp: "Mail"))
    try db.save(TBDDictation(durationMs: 2_100, rawText: "Remind me to review the transcript later.", targetApp: "Notes"))
    try db.save(TBDCustomWord(word: "tealbrick", replacement: "Tealbrick"))
    try db.save(TBDCustomWord(word: "parakeet"))
    return meeting.id
}

/// Settings regrouped by aspect (the companion SettingsView sidebar) beside the real Listen > Capture page.
struct SettingsProof: View {
    let content: AnyView
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: TBDKit.s5) {
                // Same groups and order as the host's Settings (TBDSettingsRoute, TBD-UX-01); the kit ring stays on
                // here because this proof checks the kit component itself.
                TBDNavSection("App") {
                    TBDNavItem("Account", symbol: "person.crop.circle", current: false) {}
                    TBDNavItem("Models", symbol: "cpu", current: false) {}
                    TBDNavItem("Access", symbol: "lock.shield", current: false) {}
                    TBDNavItem("General", symbol: "slider.horizontal.3", current: false) {}
                    TBDNavItem("About", symbol: "info.circle", current: false) {}
                }
                TBDNavSection("Companion") {
                    TBDNavItem("Screen capture", symbol: "eye.slash", current: false) {}
                    TBDNavItem("Storage", symbol: "internaldrive", current: false) {}
                    TBDNavItem("Tools", symbol: "wrench.and.screwdriver", current: false) {}.environment(\.tbdForcedState, .hover)
                    TBDNavItem("Export", symbol: "square.and.arrow.up", current: false) {}
                }
                TBDNavSection("Listen") {
                    TBDNavItem("Capture", symbol: "mic", current: true) {}
                    TBDNavItem("System", symbol: "gearshape", current: false) {}
                }
                Spacer(minLength: 0)
            }
            .padding(.top, TBDKit.s5).padding(.horizontal, TBDKit.s3)
            .frame(width: 208)
            content
                .padding(.horizontal, TBDKit.s6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(TBDColor.tile, in: TBDBrickShape())
                .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
                .padding(.trailing, TBDKit.s4).padding(.vertical, TBDKit.s4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TBDColor.paper)
    }
}

MainActor.assumeIsolated {
    do {
        if shellMockups {
            try runShellMockups()
        } else {
        let meetingID = try seedListen()
        let listen = TBDListeningRuntime.shared
        let page = CGSize(width: 1180, height: 820)
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            try render(ModelsProof(registry: isolatedRegistry()), size: CGSize(width: 760, height: 860), dark: dark, to: "\(prefix)-settings-models-\(theme)")
            try render(ComponentSheet(), size: CGSize(width: 1560, height: 900), dark: dark, to: "\(prefix)-components-\(theme)")
            try render(SettingsProof(content: listen.previewSettings(section: "capture")), size: CGSize(width: 1180, height: 900), dark: dark, to: "\(prefix)-settings-listen-\(theme)")
            for tab in ["transcribe", "library", "dictations", "meetings", "prompts", "transforms", "vocabulary"] {
                try render(listen.previewContent(tab: tab).background(TBDColor.paper), size: page, dark: dark, to: "\(prefix)-listen-\(tab)-\(theme)")
            }
            try render(listen.previewContent(tab: "library", transcriptID: meetingID).background(TBDColor.paper), size: page, dark: dark, to: "\(prefix)-listen-transcript-\(theme)")
        }
        }
        let report = try JSONEncoder.pretty.encode(["screens": results.map { AnyEncodable($0) }, "failures": failures.map { AnyEncodable($0) }])
        try report.write(to: outDir.appendingPathComponent("\(prefix)-native-contrast.json"))
        print("tbd-design-shots: \(results.count) screens, \(results.reduce(0) { $0 + $1.textBoxes }) text boxes (\(results.reduce(0) { $0 + $1.unclassified }) unclassified), \(failures.count) contrast failures")
        for f in failures.prefix(30) { print("  FAIL \(f.screen) (\(f.x),\(f.y) \(f.w)x\(f.h)) \(f.ink) on \(f.ground) = \(f.ratio) < \(f.need)") }
        if !failures.isEmpty { exit(1) }
    } catch {
        FileHandle.standardError.write(Data("tbd-design-shots: \(error)\n".utf8)); exit(1)
    }
}

struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
extension JSONEncoder {
    static var pretty: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
}
