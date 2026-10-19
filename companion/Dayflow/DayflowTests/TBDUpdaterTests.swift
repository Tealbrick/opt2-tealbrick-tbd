import TBDModels
import XCTest

@testable import TBD

final class TBDUpdaterTests: XCTestCase {
  private let os14 = OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)

  // MARK: helper answer

  private func answer(
    version: String = "0.3.0", url: String = "https://example.com/TBD.zip",
    sha: String = String(repeating: "a", count: 64), minOs: String? = nil
  ) -> [String: Any] {
    var d: [String: Any] = ["version": version, "url": url, "sha256": sha, "notarized": true]
    if let minOs { d["minOs"] = minOs }
    return d
  }

  func testNullMeansUpToDate() throws {
    XCTAssertNil(try TBDUpdateOffer.parse(NSNull(), currentVersion: "0.1.0", os: os14))
  }

  func testValidAnswerBecomesOffer() throws {
    let offer = try XCTUnwrap(
      try TBDUpdateOffer.parse(answer(minOs: "14.0"), currentVersion: "0.1.0", os: os14))
    XCTAssertEqual(offer.version, "0.3.0")
    XCTAssertEqual(offer.notarized, true)
  }

  func testAnswerIgnoredWhenNotNewerOrOSTooOld() throws {
    XCTAssertNil(try TBDUpdateOffer.parse(answer(version: "0.3.0"), currentVersion: "0.3.0", os: os14))
    XCTAssertNil(try TBDUpdateOffer.parse(answer(version: "0.2.0"), currentVersion: "0.3.0", os: os14))
    XCTAssertNil(try TBDUpdateOffer.parse(answer(minOs: "15.0"), currentVersion: "0.1.0", os: os14))
  }

  func testAnswerRefusedWhenUnsafeOrMalformed() {
    let bad: [Any] = [
      answer(url: "http://example.com/TBD.zip"),
      answer(sha: "xyz"),
      answer(version: "garbage"),
      answer(minOs: "fourteen"),
      ["version": "1.0.0"],
      "text",
    ]
    for value in bad {
      XCTAssertThrowsError(try TBDUpdateOffer.parse(value, currentVersion: "0.1.0", os: os14)) {
        XCTAssertEqual($0 as? TBDUpdateError, .malformedAnswer)
      }
    }
  }

  func testShaPrefixIsNormalised() throws {
    let hex = String(repeating: "B", count: 64)
    let offer = try XCTUnwrap(
      try TBDUpdateOffer.parse(answer(sha: "sha256:" + hex), currentVersion: "0.1.0", os: os14))
    XCTAssertEqual(offer.sha256, hex.lowercased())
  }

  // MARK: semver

  func testSemverOrdering() throws {
    func v(_ s: String) throws -> TBDSemver { try XCTUnwrap(TBDSemver(s)) }
    XCTAssertTrue(try v("1.2.3") < v("1.10.0"))
    XCTAssertTrue(try v("1.0.0-alpha") < v("1.0.0"))
    XCTAssertTrue(try v("1.0.0-alpha") < v("1.0.0-alpha.1"))
    XCTAssertTrue(try v("1.0.0-alpha.1") < v("1.0.0-alpha.beta"))
    XCTAssertTrue(try v("1.0.0-alpha.beta") < v("1.0.0-beta"))
    XCTAssertTrue(try v("1.0.0-beta.2") < v("1.0.0-beta.11"))
    XCTAssertTrue(try v("1.0.0-rc.1") < v("1.0.0"))
    XCTAssertEqual(try v("1.0.0+build5"), try v("1.0.0"))
    XCTAssertEqual(try v("v2.1"), try v("2.1.0"))
    XCTAssertNil(TBDSemver("1.x.0"))
    XCTAssertNil(TBDSemver("1.0.0-"))
    XCTAssertNil(TBDSemver(""))
  }

  // MARK: sha256 and requirement

  func testSHA256MismatchRefused() throws {
    let data = Data("hello".utf8)
    let good = TBDUpdateVerifier.sha256Hex(data)
    XCTAssertEqual(good, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    XCTAssertNoThrow(try TBDUpdateVerifier.verifySHA256(data: data, expected: good))
    XCTAssertNoThrow(try TBDUpdateVerifier.verifySHA256(data: data, expected: "sha256:" + good.uppercased()))
    XCTAssertThrowsError(try TBDUpdateVerifier.verifySHA256(data: Data("hellp".utf8), expected: good)) {
      XCTAssertEqual($0 as? TBDUpdateError, .digestMismatch)
    }
    XCTAssertThrowsError(try TBDUpdateVerifier.verifySHA256(data: data, expected: ""))
    XCTAssertThrowsError(try TBDUpdateVerifier.verifySHA256(data: data, expected: "abc"))
  }

  func testRequirementOnlyForWellFormedTeamID() {
    XCTAssertNotNil(TBDUpdateVerifier.requirement(teamID: "ABCDE12345"))
    XCTAssertNil(TBDUpdateVerifier.requirement(teamID: "ABC\" or true"))
    XCTAssertNil(TBDUpdateVerifier.requirement(teamID: ""))
  }

  /// C284: updates are for TBD v2's own bundle id only.
  func testRequirementNamesTheV2BundleID() {
    let req = TBDUpdateVerifier.requirement(teamID: "ABCDE12345") ?? ""
    XCTAssertTrue(req.contains("identifier \"com.tealbrick.desktop\""), req)
    XCTAssertFalse(req.contains(TBDIdentity.archivedV1BundleID + "\""), req)
  }

  // MARK: dev to dev updates (C68a)

  /// Info.plist of a build. `release` nil = a bundle from before TBDReleaseVersion existed.
  private func info(short: String = "0.1.0", release: String?, id: String = TBDIdentity.liveBundleID)
    -> [String: Any]
  {
    var d: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": short]
    if let release { d["TBDReleaseVersion"] = release }
    return d
  }

  func testDevThreeIsOfferedToDevTwo() throws {
    let offer = try XCTUnwrap(
      try TBDUpdateOffer.parse(answer(version: "0.1.0-dev.3"), currentVersion: "0.1.0-dev.2", os: os14))
    XCTAssertEqual(offer.version, "0.1.0-dev.3")
  }

  func testSameDevVersionIsNotOffered() throws {
    XCTAssertNil(
      try TBDUpdateOffer.parse(answer(version: "0.1.0-dev.3"), currentVersion: "0.1.0-dev.3", os: os14))
  }

  func testReleaseIsOfferedToItsLastPrerelease() throws {
    XCTAssertNotNil(
      try TBDUpdateOffer.parse(answer(version: "0.1.0"), currentVersion: "0.1.0-dev.9", os: os14))
    // Numeric, not textual, order inside the pre-release.
    XCTAssertNotNil(
      try TBDUpdateOffer.parse(answer(version: "0.1.0-dev.10"), currentVersion: "0.1.0-dev.9", os: os14))
  }

  func testDowngradeIsNotOffered() throws {
    XCTAssertNil(
      try TBDUpdateOffer.parse(answer(version: "0.1.0-dev.2"), currentVersion: "0.1.0-dev.3", os: os14))
    XCTAssertNil(
      try TBDUpdateOffer.parse(answer(version: "0.1.0-dev.9"), currentVersion: "0.1.0", os: os14))
  }

  func testReleaseVersionPrefersTBDReleaseVersion() {
    XCTAssertEqual(
      TBDUpdateVerifier.releaseVersion(from: info(release: "0.1.0-dev.4")), "0.1.0-dev.4")
  }

  func testReleaseVersionFallsBackToShortVersion() {
    XCTAssertEqual(TBDUpdateVerifier.releaseVersion(from: info(release: nil)), "0.1.0")
    XCTAssertEqual(TBDUpdateVerifier.releaseVersion(from: info(release: "not a version")), "0.1.0")
    XCTAssertEqual(TBDUpdateVerifier.releaseVersion(from: info(release: "")), "0.1.0")
    XCTAssertNil(TBDUpdateVerifier.releaseVersion(from: ["CFBundleShortVersionString": "x"]))
    XCTAssertNil(TBDUpdateVerifier.releaseVersion(from: nil))
  }

  func testDownloadedBundleMustBeStrictlyNewer() throws {
    let dev3 = info(release: "0.1.0-dev.3")
    XCTAssertNoThrow(
      try TBDUpdateVerifier.checkBundleIsNewer(newInfo: info(release: "0.1.0-dev.4"), currentInfo: dev3))
    XCTAssertNoThrow(
      try TBDUpdateVerifier.checkBundleIsNewer(
        newInfo: info(release: "0.1.0"), currentInfo: info(release: "0.1.0-dev.9")))
    for old in ["0.1.0-dev.3", "0.1.0-dev.2", "0.0.9"] {
      XCTAssertThrowsError(
        try TBDUpdateVerifier.checkBundleIsNewer(newInfo: info(release: old), currentInfo: dev3)
      ) { XCTAssertEqual($0 as? TBDUpdateError, .versionNotNewer) }
    }
  }

  func testBundleCheckFallsBackWhenKeyIsMissing() throws {
    // An installed build from before the key existed (short version only) updates to a dev build
    // that carries the key only if the dev build outranks 0.1.0; a prerelease of 0.1.0 does not.
    XCTAssertThrowsError(
      try TBDUpdateVerifier.checkBundleIsNewer(
        newInfo: info(release: "0.1.0-dev.4"), currentInfo: info(release: nil)))
    XCTAssertNoThrow(
      try TBDUpdateVerifier.checkBundleIsNewer(
        newInfo: info(release: "0.2.0"), currentInfo: info(release: nil)))
    // New bundle without the key: its short version is used.
    XCTAssertNoThrow(
      try TBDUpdateVerifier.checkBundleIsNewer(
        newInfo: info(short: "0.2.0", release: nil), currentInfo: info(release: "0.1.0-dev.3")))
    XCTAssertThrowsError(
      try TBDUpdateVerifier.checkBundleIsNewer(
        newInfo: info(release: nil), currentInfo: info(release: nil)))
  }

  func testBundleCheckRefusesWrongIdentifierOrMissingInfo() {
    XCTAssertThrowsError(
      try TBDUpdateVerifier.checkBundleIsNewer(
        newInfo: info(release: "0.9.0", id: "com.example.other"), currentInfo: info(release: "0.1.0")))
    // The archived v1 app is not an update for TBD v2 (C284).
    XCTAssertThrowsError(
      try TBDUpdateVerifier.checkBundleIsNewer(
        newInfo: info(release: "0.9.0", id: TBDIdentity.archivedV1BundleID), currentInfo: info(release: "0.1.0")))
    XCTAssertThrowsError(
      try TBDUpdateVerifier.checkBundleIsNewer(newInfo: nil, currentInfo: info(release: "0.1.0")))
    XCTAssertThrowsError(
      try TBDUpdateVerifier.checkBundleIsNewer(newInfo: info(release: "0.9.0"), currentInfo: nil))
  }
}
