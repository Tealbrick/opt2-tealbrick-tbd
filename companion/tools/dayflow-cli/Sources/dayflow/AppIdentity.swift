// TBD v2's own identity (C280 C10, C284). This CLI has no package dependencies, so it carries the two names itself;
// they must equal TBDIdentity.liveBundleID / liveDataFolder in native/Sources/TBDModels/TBDAppIdentity.swift
// (checked by native/Tests/TBDListeningTests/AppIdentityTests.swift). The CLI always reads the live (release) app.

/// The app's UserDefaults domain.
let tbdAppDefaultsDomain = "com.tealbrick.desktop"
/// `~/Library/Application Support/<this>/Companion` holds the Companion database, socket and logs.
let tbdAppDataFolder = "com.tealbrick.desktop"

// S8 (dev.17 review): TBD's agent starts this CLI as its Companion MCP server and sets TBD_APP_SUPPORT_DIR to the data folder of the
// RUNNING app (live or TBD Dev). The names above are only the default. The mapping is TBDIdentity.dataDirectory (shared with the
// app, tested in TBDFlowShared's tests).
import Foundation
import TBDFlowShared

/// The app's data folder: `TBD_APP_SUPPORT_DIR` when set to an absolute path, else `~/Library/Application Support/<tbdAppDataFolder>`.
func tbdDataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
  if environment[TBDIdentity.appSupportEnvironmentKey]?.hasPrefix("/") == true {
    return TBDIdentity.dataDirectory(environment: environment)
  }
  return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent(tbdAppDataFolder, isDirectory: true)
}

/// The UserDefaults domain of the app that owns the data folder (dev folders belong to the dev bundle id).
func tbdDefaultsDomain(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
  environment[TBDIdentity.appSupportEnvironmentKey]?.hasPrefix("/") == true
    ? TBDIdentity.defaultsDomain(forDataDirectory: tbdDataDirectory(environment: environment))
    : tbdAppDefaultsDomain
}
