import AppKit
import TBDDesign
import SwiftUI
import UniformTypeIdentifiers

struct SettingsRecordingPrivacyTabView: View {
  @ObservedObject var viewModel: RecordingPrivacySettingsViewModel
  @State private var isBlockedTrayTargeted = false

  private let gridColumns = [
    GridItem(.adaptive(minimum: 82, maximum: 96), spacing: 12, alignment: .top)
  ]

  var body: some View {
    SettingsSection(
      title: "",   // the pane header "Screen capture" names it
      isFirst: true
    ) {
      VStack(alignment: .leading, spacing: 18) {
        searchField
        installedAppsGrid
          .frame(maxHeight: .infinity, alignment: .top)
        blockedAppsTray
      }
      .frame(maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .onAppear {
      viewModel.handleOnAppear()
    }
  }

  private var searchField: some View {
    TBDSearchButton(text: $viewModel.searchText, prompt: "Search installed apps")
  }

  private var installedAppsGrid: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text("Installed apps")
          .font(TBDTokens.Typography.control)
          .foregroundStyle(TBDColor.ink)

        Spacer()

        if viewModel.isLoadingApplications {
          SettingsMetadata(text: String(localized: "Loading apps..."))
        } else {
          SettingsMetadata(text: String(localized: "\(viewModel.filteredApplications.count) shown"))
        }
      }

      if viewModel.isLoadingApplications && viewModel.installedApplications.isEmpty {
        ProgressView()
          .controlSize(.small)
          .padding(.vertical, 20)
          .frame(maxWidth: .infinity, alignment: .center)
      } else if viewModel.filteredApplications.isEmpty {
        Text("No apps match your search.")
          .font(TBDTokens.Typography.hint)
          .foregroundStyle(TBDColor.muted)
          .padding(.vertical, 20)
          .frame(maxWidth: .infinity, alignment: .center)
      } else {
        ScrollView(.vertical, showsIndicators: true) {
          LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 14) {
            ForEach(viewModel.filteredApplications) { app in
              RecordingPrivacyGridAppButton(
                app: app,
                isBlocked: viewModel.isBlocked(app)
              ) {
                viewModel.toggleBlocked(app)
              }
              .onDrag {
                NSItemProvider(object: app.bundleIdentifier as NSString)
              }
            }
          }
          .padding(8)
        }
        .frame(maxHeight: .infinity)
        .background(TBDColor.tile, in: TBDBrickShape())
        .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
  }

  private var blockedAppsTray: some View {
    VStack(alignment: .leading, spacing: 10) {
      Rectangle()
        .fill(TBDColor.line)
        .frame(height: TBDKit.hair)

      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text("Blocked apps")
          .font(TBDTokens.Typography.control)
          .foregroundStyle(TBDColor.ink)

        SettingsMetadata(text: String(localized: "\(viewModel.blockedApplications.count) blocked"))

        Spacer()

        SettingsSecondaryButton(
          title: String(localized: "Clear"),
          isDisabled: viewModel.blockedApplications.isEmpty,
          action: viewModel.clearBlockedApplications
        )
      }

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
          if viewModel.blockedApplications.isEmpty {
            Text("Drag apps here to hide them from recording")
              .font(TBDTokens.Typography.hint)
              .foregroundStyle(TBDColor.muted)
              .frame(height: 58)
              .padding(.horizontal, 12)
          } else {
            ForEach(viewModel.blockedApplications) { app in
              RecordingPrivacyGridAppButton(
                app: app,
                isBlocked: true
              ) {
                viewModel.removeBlockedApplication(app)
              }
            }
          }
        }
        .frame(minHeight: 96, alignment: .leading)
      }
      .frame(maxWidth: .infinity)
      .padding(8)
      .background(isBlockedTrayTargeted ? TBDColor.tealWash : TBDColor.tile, in: TBDBrickShape())
      .overlay(
        TBDBrickShape().strokeBorder(
          isBlockedTrayTargeted ? TBDColor.tealInk : TBDColor.line,
          lineWidth: isBlockedTrayTargeted ? TBDTokens.Stroke.bar : TBDKit.hair
        )
      )
      .onDrop(
        of: [UTType.text],
        isTargeted: $isBlockedTrayTargeted,
        perform: viewModel.handleApplicationDrop
      )
    }
  }
}

private struct RecordingPrivacyGridAppButton: View {
  let app: RecordingPrivacyApplication
  let isBlocked: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 7) {
        ZStack(alignment: .bottomTrailing) {
          RecordingPrivacyAppIcon(app: app, size: 44)

          if isBlocked {
            Image(systemName: "lock.fill")
              .font(TBDFonts.symbol(9, .heavy))
              .foregroundStyle(TBDColor.primaryOn)
              .frame(width: 18, height: 18)
              .background(Circle().fill(TBDColor.tealInk))
              .overlay(Circle().stroke(TBDColor.paper, lineWidth: TBDKit.hair))
              .offset(x: 4, y: 4)
          }
        }

        Text(app.name)
          .font(TBDTokens.Typography.label)
          .foregroundStyle(isBlocked ? TBDColor.tealInk : TBDColor.ink)
          .lineLimit(2)
          .multilineTextAlignment(.center)
          .frame(width: 76, height: 36, alignment: .top)
      }
      .frame(width: 82, height: 94, alignment: .top)
      .contentShape(TBDBrickShape())
      .background(isBlocked ? TBDColor.tealWash : Color.clear, in: TBDBrickShape())
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }
}

private struct RecordingPrivacyAppIcon: View {
  let app: RecordingPrivacyApplication
  let size: CGFloat

  var body: some View {
    Image(nsImage: icon)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .frame(width: size, height: size)
  }

  private var icon: NSImage {
    if let appURL = app.appURL {
      return NSWorkspace.shared.icon(forFile: appURL.path)
    }
    return NSWorkspace.shared.icon(for: .applicationBundle)
  }
}

#Preview("Recording Privacy") {
  SettingsRecordingPrivacyTabView(viewModel: RecordingPrivacySettingsViewModel())
    .frame(width: 760, height: 820)
    .padding()
}
