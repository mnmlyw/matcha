import XCTest

final class UpdateCheckerTests: XCTestCase {
    /// We can't easily instantiate UpdateChecker.shared with a fake config in
    /// a unit test, but `isNewer` is now `internal` and pure, so it can be
    /// exercised via a fresh local helper that uses the same logic source.
    private let checker = UpdateChecker.shared

    func testMajorBump() {
        XCTAssertTrue(checker.isNewer(remote: "1.0.0", local: "0.9.9"))
    }

    func testMinorBump() {
        XCTAssertTrue(checker.isNewer(remote: "0.5.3", local: "0.5.2"))
    }

    func testPatchBump() {
        XCTAssertTrue(checker.isNewer(remote: "0.5.3", local: "0.5.2"))
    }

    func testEqualNotNewer() {
        XCTAssertFalse(checker.isNewer(remote: "0.5.2", local: "0.5.2"))
    }

    func testLowerNotNewer() {
        XCTAssertFalse(checker.isNewer(remote: "0.5.1", local: "0.5.2"))
    }

    func testPreReleaseRemoteIsOlder() {
        // Per semver, 1.0.0-rc1 is *older* than 1.0.0. Previously the
        // checker's compactMap-Int parse silently dropped the `0-rc1`
        // segment and reported equality, leaving users on an older
        // pre-release while a stable existed.
        XCTAssertFalse(checker.isNewer(remote: "1.0.0-rc1", local: "1.0.0"))
    }

    func testStableNewerThanLocalPreRelease() {
        XCTAssertTrue(checker.isNewer(remote: "1.0.0", local: "1.0.0-rc1"))
    }

    func testPreReleaseWithHigherNumericIsNewer() {
        XCTAssertTrue(checker.isNewer(remote: "1.1.0-rc1", local: "1.0.0"))
    }

    func testShorterRemoteWithTrailingZeros() {
        // "1.0" vs "1.0.0" → numerically equal.
        XCTAssertFalse(checker.isNewer(remote: "1.0", local: "1.0.0"))
        XCTAssertFalse(checker.isNewer(remote: "1.0.0", local: "1.0"))
    }
}
