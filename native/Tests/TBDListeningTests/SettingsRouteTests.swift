import XCTest
@testable import TBDListening

/// TBD-UX-01: one Settings item per pane, and every section a link or older build sends still opens its pane.
final class SettingsRouteTests: XCTestCase {
    func testEverySectionOpensAPane() {
        XCTAssertEqual(TBDSettingsRoute.sections.count, 13)
        for section in TBDSettingsRoute.sections {
            XCTAssertNotNil(TBDSettingsRoute.item(for: section), section)
        }
    }

    func testTheThreeOldModelsEntriesOpenTheMergedItemOnTheirOwnPage() {
        XCTAssertEqual(TBDSettingsRoute.item(for: "engine"), .models)
        XCTAssertEqual(TBDSettingsRoute.item(for: "providers"), .models)
        XCTAssertEqual(TBDSettingsRoute.item(for: "audioAI"), .models)
        XCTAssertEqual(TBDSettingsRoute.modelsPage(for: "engine"), "Tasks")
        XCTAssertEqual(TBDSettingsRoute.modelsPage(for: "providers"), "Advanced")
        XCTAssertEqual(TBDSettingsRoute.modelsPage(for: "audioAI"), "Transcription")
        for page in ["Tasks", "Advanced", "Transcription"] {
            XCTAssertTrue(TBDSettingsRoute.modelsPages.contains(page), page)
        }
        XCTAssertEqual(TBDSettingsRoute.Item.models.section, "engine")
    }

    func testOtherPanesHaveNoModelsPage() {
        for section in TBDSettingsRoute.sections where !["engine", "providers", "audioAI"].contains(section) {
            XCTAssertNil(TBDSettingsRoute.modelsPage(for: section), section)
        }
    }

    func testEveryItemIsShownOnceAndOpensItsOwnSection() {
        let shown = TBDSettingsRoute.groups.flatMap(\.items)
        XCTAssertEqual(shown.count, Set(shown).count)
        XCTAssertEqual(Set(shown), Set(TBDSettingsRoute.Item.allCases))
        for item in TBDSettingsRoute.Item.allCases {
            XCTAssertTrue(TBDSettingsRoute.sections.contains(item.section), item.rawValue)
            XCTAssertEqual(TBDSettingsRoute.item(for: item.section), item)
        }
    }

    func testAnUnknownSectionIsNotAPane() {
        XCTAssertNil(TBDSettingsRoute.item(for: "updates"))
        XCTAssertNil(TBDSettingsRoute.item(for: ""))
    }
}
