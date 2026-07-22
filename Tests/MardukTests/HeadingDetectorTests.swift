import XCTest
@testable import marduk

final class HeadingDetectorTests: XCTestCase {

    private func run(_ location: Int, _ length: Int, _ size: Double)
        -> HeadingDetector.FontRun {
        HeadingDetector.FontRun(range: NSRange(location: location, length: length),
                                pointSize: size)
    }

    func testBodyIsLengthWeightedMode() {
        // Short big title over a long small body: the body is the size
        // covering the most characters, so 24 ranks as the heading
        let found = HeadingDetector.headings(runs: [run(0, 10, 24), run(10, 200, 12)])
        XCTAssertEqual(found.map(\.offset), [0])
        XCTAssertEqual(found.map(\.level), [1])
    }

    func testTwoHeadingSizesRankIntoLevels() {
        // Title 24 → level 1, section heading 18 → level 2, body 12
        let found = HeadingDetector.headings(runs: [run(0, 8, 24), run(8, 100, 12),
                                                    run(108, 6, 18), run(114, 100, 12)])
        XCTAssertEqual(found.map(\.offset), [0, 108])
        XCTAssertEqual(found.map(\.level), [1, 2])
    }

    func testUniformDocumentHasNoHeadings() {
        XCTAssertTrue(HeadingDetector.headings(runs: [run(0, 50, 12),
                                                      run(50, 50, 12)]).isEmpty)
        XCTAssertTrue(HeadingDetector.headings(runs: []).isEmpty)
    }

    func testLargestSizeAsBodyYieldsNothing() {
        // Big-print document with small footnotes: nothing is LARGER
        // than the body, so nothing is a heading
        XCTAssertTrue(HeadingDetector.headings(runs: [run(0, 300, 18),
                                                      run(300, 20, 10)]).isEmpty)
    }

    func testAdjacentSameSizeRunsMergeIntoOneHeading() {
        // A styled word inside one heading line arrives as separate
        // same-size runs — one heading, at the first run's start
        let found = HeadingDetector.headings(runs: [run(0, 4, 18), run(4, 5, 18),
                                                    run(9, 3, 18), run(12, 200, 12)])
        XCTAssertEqual(found.map(\.offset), [0])
    }

    func testSeparatedSameSizeHeadingsStayDistinct() {
        let found = HeadingDetector.headings(runs: [run(0, 6, 18), run(6, 80, 12),
                                                    run(86, 6, 18), run(92, 80, 12)])
        XCTAssertEqual(found.map(\.offset), [0, 86])
        XCTAssertEqual(found.map(\.level), [1, 1])
    }

    func testNearBodySizeIsNotAHeading() {
        // Half-point slack: 12.4 against a 12-point body is float noise
        XCTAssertTrue(HeadingDetector.headings(runs: [run(0, 10, 12.4),
                                                      run(10, 200, 12)]).isEmpty)
    }

    func testWeightTieBreaksTowardSmallerBody() {
        let found = HeadingDetector.headings(runs: [run(0, 50, 12), run(50, 50, 18)])
        XCTAssertEqual(found.map(\.offset), [50])
        XCTAssertEqual(found.map(\.level), [1])
    }
}
