import XCTest
import CoreGraphics
@testable import marduk

/// IMAGE DESCRIPTION (`D`): the pure parts — capture geometry, the
/// facts composer, the engine table, the Ollama model pick and cleanup,
/// the prompt's rules — plus source-level drift guards. Vision, AX and
/// ScreenCaptureKit need a screen and stay a hardware concern.
final class DescribeTests: XCTestCase {

    // MARK: - Geometry

    func testElementInsideWindowIsImageShaped() {
        let window = CGRect(x: 100, y: 50, width: 800, height: 600)
        XCTAssertTrue(ImageRegion.isImageShaped(
            element: CGRect(x: 200, y: 200, width: 300, height: 200), window: window))
    }

    func testContainerCoveringTheWindowIsNotImageShaped() {
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertFalse(ImageRegion.isImageShaped(
            element: CGRect(x: 0, y: 40, width: 800, height: 560), window: window))
    }

    func testGlyphSizedElementIsNotImageShaped() {
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertFalse(ImageRegion.isImageShaped(
            element: CGRect(x: 10, y: 10, width: 12, height: 12), window: window))
    }

    func testWindowRelativeSubtractsTheWindowOrigin() {
        let window = CGRect(x: 100, y: 50, width: 800, height: 600)
        let element = CGRect(x: 250, y: 150, width: 300, height: 200)
        XCTAssertEqual(ImageRegion.windowRelative(element: element, window: window),
                       CGRect(x: 150, y: 100, width: 300, height: 200))
    }

    func testWindowRelativeClipsToTheWindow() {
        let window = CGRect(x: 100, y: 50, width: 800, height: 600)
        let element = CGRect(x: 50, y: 0, width: 200, height: 200)  // hangs off top-left
        XCTAssertEqual(ImageRegion.windowRelative(element: element, window: window),
                       CGRect(x: 0, y: 0, width: 150, height: 150))
    }

    func testWindowRelativeIsNilOutsideTheWindow() {
        let window = CGRect(x: 100, y: 50, width: 800, height: 600)
        XCTAssertNil(ImageRegion.windowRelative(
            element: CGRect(x: 2000, y: 2000, width: 10, height: 10), window: window))
    }

    func testPixelSizeAppliesTheBackingScale() {
        let size = ImageRegion.pixelSize(points: CGSize(width: 300.4, height: 200), scale: 2)
        XCTAssertEqual(size.width, 601)
        XCTAssertEqual(size.height, 400)
    }

    func testDownscaleKeepsAspectAndNeverUpscales() {
        let down = ImageRegion.downscaled(width: 4000, height: 3000, maxSide: 1000)
        XCTAssertEqual(down.width, 1000)
        XCTAssertEqual(down.height, 750)
        let same = ImageRegion.downscaled(width: 640, height: 480, maxSide: 1000)
        XCTAssertEqual(same.width, 640)
        XCTAssertEqual(same.height, 480)
    }

    func testOnlyFileImageURLsCount() {
        XCTAssertTrue(ImageRegion.looksLikeImageFile(URL(fileURLWithPath: "/tmp/a.HEIC")))
        XCTAssertFalse(ImageRegion.looksLikeImageFile(URL(fileURLWithPath: "/tmp/a.pdf")))
        XCTAssertFalse(ImageRegion.looksLikeImageFile(URL(string: "https://x.test/a.jpg")!))
    }

    func testGenericLabelsAreNotSpoken() {
        XCTAssertTrue(ImageRegion.isGenericLabel("Image"))
        XCTAssertTrue(ImageRegion.isGenericLabel("  attachment "))
        XCTAssertTrue(ImageRegion.isGenericLabel(""))
        XCTAssertFalse(ImageRegion.isGenericLabel("IMG_4021.jpeg"))
        XCTAssertFalse(ImageRegion.isGenericLabel("Sunset over the bay"))
    }

    // MARK: - Facts composer

    func testFactsSpeakLabelsAnimalsFacesAndText() {
        var facts = ImageFacts()
        facts.kind = .photo
        facts.labels = ["golden_retriever", "grass", "outdoor", "sky", "cloud"]
        facts.animals = ["dog", "dog"]
        facts.faces = 1
        facts.text = "  Happy   birthday  "
        XCTAssertEqual(facts.kindWord, "Photo.")
        XCTAssertEqual(facts.spoken,
                       "Looks like: golden retriever, grass, outdoor, sky. "
                       + "Two dogs. One face. Text reads: Happy   birthday")
    }

    func testHumansSpeakOnlyWithoutFaces() {
        var facts = ImageFacts()
        facts.humans = 3
        XCTAssertEqual(facts.spoken, "3 people.")
        facts.faces = 2
        XCTAssertEqual(facts.spoken, "2 faces.")
    }

    func testEmptyFactsSayNothingRecognizable() {
        XCTAssertEqual(ImageFacts().spoken, "Nothing recognizable.")
        XCTAssertEqual(ImageFacts().kindWord, "Image.")
    }

    func testScreenshotKindAndCodes() {
        var facts = ImageFacts()
        facts.kind = .screenshot
        facts.codes = ["QR code"]
        XCTAssertEqual(facts.kindWord, "Screenshot.")
        XCTAssertEqual(facts.spoken, "Contains one QR code.")
    }

    func testCountedPluralisesAndJoins() {
        XCTAssertEqual(ImageFacts.counted(["cat"]), "One cat")
        XCTAssertEqual(ImageFacts.counted(["dog", "cat", "dog"]), "Two dogs and one cat")
        XCTAssertEqual(ImageFacts.counted([]), "")
        XCTAssertEqual(ImageFacts.counted(["QR code"], capitalized: false), "one QR code")
    }

    func testLongTextIsClampedAtAWordAndSaysSo() {
        let text = String(repeating: "word ", count: 200)
        let clamped = ImageFacts.clamp(text, 50)
        XCTAssertLessThanOrEqual(clamped.count, 50 + ", and more.".count)
        XCTAssertTrue(clamped.hasSuffix(", and more."))
        XCTAssertFalse(clamped.contains("wor,"))
        XCTAssertEqual(ImageFacts.clamp("short", 50), "short")
    }

    func testJoinedTextCollapsesWhitespaceAndDropsEmptyLines() {
        XCTAssertEqual(ImageFacts.joinedText([" Total ", "", "  $12.50\n"]),
                       "Total $12.50")
    }

    func testCodeSymbologiesSpeakAsNouns() {
        XCTAssertEqual(ImageFacts.spokenCode("VNBarcodeSymbologyQR"), "QR code")
        XCTAssertEqual(ImageFacts.spokenCode("VNBarcodeSymbologyAztec"), "2D code")
        XCTAssertEqual(ImageFacts.spokenCode("VNBarcodeSymbologyEAN13"), "barcode")
    }

    // MARK: - Engine table

    func testAutoPrefersAppleThenOllamaThenLabels() {
        XCTAssertEqual(ImageEngine.chain(setting: .auto, appleReady: true,
                                         ollamaAvailable: true),
                       [.apple, .ollama, .labels])
        XCTAssertEqual(ImageEngine.chain(setting: .auto, appleReady: false,
                                         ollamaAvailable: true),
                       [.ollama, .labels])
        XCTAssertEqual(ImageEngine.chain(setting: .auto, appleReady: false,
                                         ollamaAvailable: false),
                       [.labels])
    }

    func testExplicitEngineFallsToLabelsAndExplainsItself() {
        XCTAssertEqual(ImageEngine.chain(setting: .ollama, appleReady: true,
                                         ollamaAvailable: false), [.labels])
        XCTAssertEqual(ImageEngine.chain(setting: .apple, appleReady: false,
                                         ollamaAvailable: true), [.labels])
        XCTAssertEqual(ImageEngine.chain(setting: .labels, appleReady: true,
                                         ollamaAvailable: true), [.labels])
        XCTAssertNotNil(ImageEngine.unavailableReason(
            setting: .ollama, appleReady: true, ollamaAvailable: false))
        XCTAssertNotNil(ImageEngine.unavailableReason(
            setting: .apple, appleReady: false, ollamaAvailable: true))
        XCTAssertNil(ImageEngine.unavailableReason(
            setting: .auto, appleReady: false, ollamaAvailable: false))
        XCTAssertNil(ImageEngine.unavailableReason(
            setting: .ollama, appleReady: false, ollamaAvailable: true))
    }

    func testEveryChainEndsInLabelsAndNeverContainsAuto() {
        for setting in ImageEngine.allCases {
            for apple in [true, false] {
                for ollama in [true, false] {
                    let chain = ImageEngine.chain(setting: setting, appleReady: apple,
                                                  ollamaAvailable: ollama)
                    XCTAssertEqual(chain.last, .labels, "\(setting) \(apple) \(ollama)")
                    XCTAssertFalse(chain.contains(.auto))
                }
            }
        }
    }

    func testImageModelSettingListsEveryEngine() {
        let setting = ColonCommand.settings.first { $0.key == "imagemodel" }
        guard case .choice(let values)? = setting?.kind else {
            return XCTFail("imagemodel is not a choice setting")
        }
        XCTAssertEqual(Set(values), Set(ImageEngine.allCases.map(\.rawValue)))
        XCTAssertTrue(ColonCommand.commandNames.contains("describe"))
        XCTAssertTrue(ColonCommand.settings.contains { $0.key == "describe" })
    }

    // MARK: - Prompt

    func testPromptForbidsIdentifyingPeopleAndAsksForPlainProse() {
        XCTAssertTrue(DescribePrompt.base.contains("Do not guess who people are"))
        XCTAssertTrue(DescribePrompt.base.contains("cannot see it"))
        XCTAssertTrue(DescribePrompt.base.contains("Quote any visible text"))
        XCTAssertTrue(DescribePrompt.base.contains("Do not use markdown"))
    }

    func testPromptCarriesTheOCRTextOnlyWhenThereIsSome() {
        XCTAssertEqual(DescribePrompt.text(ocr: "  "), DescribePrompt.base)
        let withText = DescribePrompt.text(ocr: "SALE 50% OFF")
        XCTAssertTrue(withText.hasPrefix(DescribePrompt.base))
        XCTAssertTrue(withText.hasSuffix("SALE 50% OFF"))
    }

    // MARK: - Ollama vision

    func testVisionModelPickPrefersGemma3AndSkipsTheTextOnly1B() {
        let available = ["llama3.1:8b", "gemma3:1b", "llava:7b", "gemma3:4b"]
        XCTAssertEqual(OllamaVision.candidates(configured: nil, available: available),
                       ["gemma3:4b", "llava:7b"])
        XCTAssertFalse(OllamaVision.canSee(tag: "gemma3:1b"))
        XCTAssertTrue(OllamaVision.canSee(tag: "gemma3:latest"))
        XCTAssertFalse(OllamaVision.canSee(tag: "llama3.1:8b"))
    }

    func testConfiguredPinWinsByPrefixEvenIfUnknownToTheTable() {
        let available = ["gemma3:4b", "mystery-vision:2b"]
        XCTAssertEqual(OllamaVision.candidates(configured: "mystery", available: available),
                       ["mystery-vision:2b", "gemma3:4b"])
        XCTAssertEqual(OllamaVision.candidates(configured: "nope", available: available),
                       ["gemma3:4b"])
    }

    func testNoVisionModelMeansNoCandidates() {
        XCTAssertEqual(OllamaVision.candidates(configured: nil,
                                               available: ["llama3.1:8b", "gemma3:1b"]),
                       [])
    }

    func testShowCapabilitiesAreReadWhenPresent() {
        let sees = #"{"capabilities":["completion","vision"]}"#.data(using: .utf8)!
        let blind = #"{"capabilities":["completion"]}"#.data(using: .utf8)!
        let old = #"{"modelfile":"FROM x"}"#.data(using: .utf8)!
        XCTAssertEqual(OllamaVision.showsVision(showJSON: sees), true)
        XCTAssertEqual(OllamaVision.showsVision(showJSON: blind), false)
        XCTAssertNil(OllamaVision.showsVision(showJSON: old))
    }

    func testPayloadCarriesTheImageAndNoStreaming() {
        let payload = OllamaVision.payload(model: "gemma3:4b", prompt: "p",
                                           jpegBase64: "AAAA")
        XCTAssertEqual(payload["model"] as? String, "gemma3:4b")
        XCTAssertEqual(payload["images"] as? [String], ["AAAA"])
        XCTAssertEqual(payload["stream"] as? Bool, false)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))
    }

    func testResponseCleanupDropsMarkdownAndCollapsesWhitespace() {
        let raw = "**A photo** of a dog.\n\n- It is  brown.\n* Text says `hi`."
        XCTAssertEqual(OllamaVision.clean(response: raw),
                       "A photo of a dog. It is brown. Text says hi.")
        XCTAssertNil(OllamaVision.clean(response: "  \n "))
    }

    func testResponseCleanupCapsRunaways() {
        let long = String(repeating: "blah ", count: 1000)
        let cleaned = OllamaVision.clean(response: long)!
        XCTAssertLessThan(cleaned.count, OllamaVision.responseLimit + 20)
        XCTAssertTrue(cleaned.hasSuffix(", and more."))
    }

    func testEveryOllamaFailureSpeaks() {
        let failures: [OllamaVision.Failure] = [
            .notLocal, .notInstalled, .notAnswering, .noVisionModel, .encode,
            .timeout, .refused, .empty,
        ]
        for failure in failures {
            XCTAssertFalse(failure.spoken.isEmpty, "\(failure)")
        }
    }

    // MARK: - Composition

    func testComposeOpensWithKindThenLabelThenBody() {
        XCTAssertEqual(
            ImageDescriber.compose(kind: "Photo.", label: "IMG_1.jpeg",
                                   source: .elementCapture, body: "A dog."),
            "Photo. Labeled IMG_1.jpeg. A dog.")
        XCTAssertEqual(
            ImageDescriber.compose(kind: "Image.", label: "Image",
                                   source: .windowCapture, body: "A chat."),
            "Image. No single image under the pointer, so this is the whole window. A chat.")
    }

    // MARK: - Drift guards

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath),
                          encoding: .utf8)
    }

    /// The D case must sit ABOVE the d case in the NORMAL switch — a
    /// Swift switch takes the first matching case, and the brief's has
    /// no shift check.
    func testDescribeCasePrecedesTheBriefCase() throws {
        let monitor = try source("Sources/Input/KeyboardMonitor.swift")
        let describe = monitor.range(of: "case 2 where flags.contains(.maskShift) && describeExtensionEnabled")
        let brief = monitor.range(of: "case 2 where briefExtensionEnabled")
        XCTAssertNotNil(describe)
        XCTAssertNotNil(brief)
        if let describe, let brief {
            XCTAssertLessThan(describe.lowerBound, brief.lowerBound)
        }
    }

    /// Only the on-device model, ever — the WWDC26 API can route the
    /// same session to a server, and a family photo must not.
    func testAppleEngineUsesOnlyTheOnDeviceModel() throws {
        let engines = try source("Sources/Describe/ImageEngines.swift")
        XCTAssertTrue(engines.contains("SystemLanguageModel.default"))
        for forbidden in ["SystemLanguageModel(", "PrivateCloudCompute", ".cloud",
                          "useCase:", "serverModel", "RemoteModel"] {
            XCTAssertFalse(engines.contains(forbidden), forbidden)
        }
    }

    /// Captures are of a WINDOW, never a display.
    func testCaptureNeverTargetsTheDisplay() throws {
        let acquire = try source("Sources/Describe/ImageAcquire.swift")
        XCTAssertTrue(acquire.contains("SCContentFilter(desktopIndependentWindow:"))
        XCTAssertFalse(acquire.contains("SCContentFilter(display:"))
        XCTAssertFalse(acquire.contains("CGDisplayCreateImage"))
        XCTAssertFalse(acquire.contains("CGWindowListCreateImage"))
    }
}
