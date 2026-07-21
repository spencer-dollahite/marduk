import XCTest
@testable import marduk

final class VisualFollowTests: XCTestCase {

    func testDigitKeycodesTypeThePageNumber() {
        XCTAssertEqual(KeyboardMonitor.digitKeycodes(2), [19])
        XCTAssertEqual(KeyboardMonitor.digitKeycodes(12), [18, 19])
        XCTAssertEqual(KeyboardMonitor.digitKeycodes(305), [20, 29, 23])
        XCTAssertEqual(KeyboardMonitor.digitKeycodes(1234567890),
                       [18, 19, 20, 21, 23, 22, 26, 28, 25, 29])
        XCTAssertEqual(KeyboardMonitor.digitKeycodes(-3), [29])  // clamped to 0
    }

    func testPreviewHasAGoToPageChord() {
        let chord = KeyboardMonitor.pageChords["com.apple.Preview"]
        XCTAssertEqual(chord?.keycode, 5)  // G
        XCTAssertEqual(chord?.command, true)
        XCTAssertEqual(chord?.option, true)
        XCTAssertEqual(chord?.shift, false)
    }

    func testLineIndexCountsNewlinesBeforeOffset() {
        let text = "line one\nline two\nline three"
        XCTAssertEqual(KeyboardMonitor.lineIndex(of: 0, in: text), 0)
        XCTAssertEqual(KeyboardMonitor.lineIndex(of: 8, in: text), 0)   // end of line one
        XCTAssertEqual(KeyboardMonitor.lineIndex(of: 9, in: text), 1)   // first char of line two
        XCTAssertEqual(KeyboardMonitor.lineIndex(of: 18, in: text), 2)
        XCTAssertEqual(KeyboardMonitor.lineIndex(of: 999, in: text), 2) // clamped
        XCTAssertEqual(KeyboardMonitor.lineIndex(of: -1, in: text), 0)
    }
}

final class DisplayInverterTests: XCTestCase {

    private func solidImage(r: UInt8, g: UInt8, b: UInt8) -> CGImage {
        let width = 8, height = 8
        var pixels = [UInt8]()
        for _ in 0..<(width * height) { pixels.append(contentsOf: [r, g, b, 255]) }
        let data = CFDataCreate(nil, pixels, pixels.count)!
        let provider = CGDataProvider(data: data)!
        return CGImage(width: width, height: height, bitsPerComponent: 8,
                       bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    func testMeanBrightnessExtremes() {
        let white = DisplayInverter.meanBrightness(solidImage(r: 255, g: 255, b: 255))
        XCTAssertNotNil(white)
        XCTAssertGreaterThan(white ?? 0, 0.95)

        let black = DisplayInverter.meanBrightness(solidImage(r: 0, g: 0, b: 0))
        XCTAssertNotNil(black)
        XCTAssertLessThan(black ?? 1, 0.05)
    }

    func testMeanBrightnessMidGrayCrossesNoThreshold() {
        let gray = DisplayInverter.meanBrightness(solidImage(r: 128, g: 128, b: 128))
        XCTAssertEqual(gray ?? 0, 0.5, accuracy: 0.05)
    }
}
