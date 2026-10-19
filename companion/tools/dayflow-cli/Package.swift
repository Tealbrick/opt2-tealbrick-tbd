// swift-tools-version:5.9
import PackageDescription

// The Dayflow CLI: a standalone executable with no package dependencies. SQLite comes from the system SDK, and
// argument parsing is hand-rolled, so this builds with `swift build` alone and can later be folded into Dayflow.app
// as an Xcode target without dragging any package resolution along with it.
//
// dev.17 (U3): the two Flow plan tools (`flow_plan_today`, `flow_plan_add`) use the SAME Flow store and plan parser as
// the app, so they cannot drift. Those files live in native/Sources/TBDModels (Foundation, CryptoKit and system
// frameworks only). `Sources/TBDFlowShared` is a symlink to that folder; only the files listed here are compiled. This
// keeps the CLI free of package dependencies (native/Package.swift pulls GRDB, FluidAudio and more).
let package = Package(
  name: "dayflow-cli",
  platforms: [.macOS(.v13)],
  targets: [
    .target(
      name: "TBDFlowShared",
      path: "Sources/TBDFlowShared",
      sources: [
        "TBDAppIdentity.swift",
        "TBDRealDataGuard.swift",
        "TBDFlowModels.swift",
        "TBDFlowStore.swift",
        "TBDFlowPlanParser.swift",
        "TBDFlowMatcher.swift",
        "TBDFlowSession.swift",
      ]
    ),
    .target(
      name: "DayflowFlowTools",
      dependencies: ["TBDFlowShared"],
      path: "Sources/DayflowFlowTools"
    ),
    .executableTarget(
      name: "dayflow",
      dependencies: ["DayflowFlowTools", "TBDFlowShared"],
      path: "Sources/dayflow"
    ),
    .testTarget(
      name: "DayflowFlowToolsTests",
      dependencies: ["DayflowFlowTools", "TBDFlowShared"],
      path: "Tests/DayflowFlowToolsTests"
    ),
  ]
)
