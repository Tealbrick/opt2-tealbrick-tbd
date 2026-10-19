// TBD v2's own identity (C280 C10, C284). This CLI has no package dependencies, so it carries the two names itself;
// they must equal TBDIdentity.liveBundleID / liveDataFolder in native/Sources/TBDModels/TBDAppIdentity.swift
// (checked by native/Tests/TBDListeningTests/AppIdentityTests.swift). The CLI always reads the live (release) app.

/// The app's UserDefaults domain.
let tbdAppDefaultsDomain = "com.tealbrick.desktop"
/// `~/Library/Application Support/<this>/Companion` holds the Companion database, socket and logs.
let tbdAppDataFolder = "com.tealbrick.desktop"
