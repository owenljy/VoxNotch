import XCTest
@testable import VoxNotch

final class DictationDiagnosticTests: XCTestCase {
    func testPercentileUsesNearestRank() {
        let values = [4.0, 1.0, 3.0, 2.0]
        XCTAssertEqual(DiagnosticStatistics.percentile(values, fraction: 0.5), 2.0)
        XCTAssertEqual(DiagnosticStatistics.percentile(values, fraction: 0.95), 4.0)
    }

    func testPercentileIgnoresInvalidDurations() {
        XCTAssertNil(DiagnosticStatistics.percentile([], fraction: 0.5))
        XCTAssertEqual(DiagnosticStatistics.percentile([-1, .nan, .infinity, 1.5], fraction: 0.5), 1.5)
    }
}
