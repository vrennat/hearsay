import XCTest
@testable import HearsayCore

/// The version shown in Settings and `hearsay --version` must match the VERSION file the release
/// script reads; a release once shipped with the two out of step.
final class VersionTests: XCTestCase {
    func testConstantMatchesVersionFile() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(HearsayCore.version, file)
    }
}
