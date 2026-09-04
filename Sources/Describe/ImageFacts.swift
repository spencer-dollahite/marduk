import Foundation
import CoreGraphics
import Vision

/// What Apple's built-in Vision framework can say about an image without
/// a language model: the KIND of image, what it classifies as, how many
/// faces and people, which animals, the text in it, and any codes. This
/// is the `labels` engine — always available, no permission, no
/// network, a fraction of a second — and it also rides every other
/// engine: the OCR text is handed to the language models as context,
/// because captioners skip fine print and Vision's text pass does not.
///
/// The composition (`spoken`) is pure and tested; the Vision calls are
/// a hardware concern like every other framework round trip here.
/// Privacy: the facts are user content and never logged — only counts.
struct ImageFacts: Equatable {
    enum Kind: Equatable { case photo, screenshot, unknown }

    var kind: Kind = .unknown
    var labels: [String] = []
    var faces = 0
    var humans = 0
    var animals: [String] = []
    var text = ""
    var codes: [String] = []

    /// How many labels are worth hearing. Vision returns hundreds.
    static let labelLimit = 4
    /// Spoken OCR is capped — a screenshot of a page is not a read.
    static let textLimit = 400
    /// Vision's own precision/recall filter for the classifier: keep a
    /// label only if the classifier is right about it 9 times in 10.
    static let minPrecision: Float = 0.9
    static let minRecall: Float = 0.01

    /// The kind as a one-word opener.
    var kindWord: String {
        switch kind {
        case .photo: return "Photo."
        case .screenshot: return "Screenshot."
        case .unknown: return "Image."
        }
    }

    /// Everything but the kind, as sentences — the caller opens with
    /// `kindWord` (it prefixes the LLM engines' output too, so it lives
    /// apart).
    var spoken: String {
        var parts: [String] = []
        if !labels.isEmpty {
            parts.append("Looks like: " + labels.prefix(Self.labelLimit)
                .map(Self.spokenLabel).joined(separator: ", ") + ".")
        }
        if !animals.isEmpty {
            parts.append(Self.counted(animals) + ".")
        }
        if faces > 0 {
            parts.append(faces == 1 ? "One face." : "\(faces) faces.")
        } else if humans > 0 {
            parts.append(humans == 1 ? "One person." : "\(humans) people.")
        }
        if !codes.isEmpty {
            parts.append("Contains " + Self.counted(codes, capitalized: false) + ".")
        }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            parts.append("Text reads: " + Self.clamp(trimmedText, Self.textLimit))
        }
        if parts.isEmpty { parts.append("Nothing recognizable.") }
        return parts.joined(separator: " ")
    }

    /// "golden_retriever" → "golden retriever".
    static func spokenLabel(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ")
    }

    /// ["dog", "dog", "cat"] → "Two dogs and one cat" (pluralised the
    /// simple way; Vision's animal and code vocabularies are regular).
    static func counted(_ items: [String], capitalized: Bool = true) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for item in items {
            if counts[item] == nil { order.append(item) }
            counts[item, default: 0] += 1
        }
        let phrases = order.map { item -> String in
            let n = counts[item] ?? 1
            return n == 1 ? "one \(item)" : "\(spokenNumber(n)) \(item)s"
        }
        let joined: String
        switch phrases.count {
        case 0: return ""
        case 1: joined = phrases[0]
        default:
            joined = phrases.dropLast().joined(separator: ", ")
                + " and " + phrases[phrases.count - 1]
        }
        guard capitalized else { return joined }
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    static func spokenNumber(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six",
                     "seven", "eight", "nine", "ten"]
        return n < words.count ? words[n] : "\(n)"
    }

    /// Cut at a word boundary and say so.
    static func clamp(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        let cut = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
        return cut + ", and more."
    }

    /// OCR lines → one string: whitespace collapsed, order preserved.
    static func joinedText(_ lines: [String]) -> String {
        lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// Vision's barcode symbology → a spoken noun.
    static func spokenCode(_ symbology: String) -> String {
        let lower = symbology.lowercased()
        if lower.contains("qr") { return "QR code" }
        if lower.contains("aztec") || lower.contains("datamatrix")
            || lower.contains("pdf417") { return "2D code" }
        return "barcode"
    }

    // MARK: - Vision (hardware)

    /// Runs every request on one handler. Each failure costs its own
    /// fact and nothing else — a missing classifier model must not eat
    /// the OCR. Off-main; a Vision pass on a 1600px image is ~0.3-1s.
    static func gather(_ image: CGImage) async -> ImageFacts {
        var facts = ImageFacts()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        let classify = VNClassifyImageRequest()
        let ocr = VNRecognizeTextRequest()
        ocr.recognitionLevel = .accurate
        ocr.usesLanguageCorrection = true
        let faces = VNDetectFaceRectanglesRequest()
        let humans = VNDetectHumanRectanglesRequest()
        let animals = VNRecognizeAnimalsRequest()
        let barcodes = VNDetectBarcodesRequest()
        let requests: [VNRequest] = [classify, ocr, faces, humans, animals, barcodes]
        for request in requests {
            do { try handler.perform([request]) } catch {
                fputs("[describe] vision \(type(of: request)) failed: "
                    + "\(error.localizedDescription)\n", stderr)
            }
        }

        facts.labels = (classify.results ?? [])
            .filter { $0.hasMinimumRecall(minRecall, forPrecision: minPrecision) }
            .sorted { $0.confidence > $1.confidence }
            .prefix(labelLimit)
            .map(\.identifier)
        facts.text = joinedText((ocr.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string })
        facts.faces = faces.results?.count ?? 0
        facts.humans = humans.results?.count ?? 0
        facts.animals = (animals.results ?? []).compactMap { observation in
            observation.labels.first?.identifier.lowercased()
        }
        facts.codes = (barcodes.results ?? []).map {
            spokenCode($0.symbology.rawValue)
        }
        facts.kind = await kind(of: image)

        fputs("[describe] facts: \(facts.labels.count) labels, "
            + "\(facts.faces) faces, \(facts.humans) humans, "
            + "\(facts.animals.count) animals, \(facts.codes.count) codes, "
            + "\(facts.text.count) chars of text, kind \(facts.kind)\n", stderr)
        return facts
    }

    /// Photo vs screenshot from Vision's aesthetics request (macOS 15+):
    /// `isUtility` is Apple's own "this is a screenshot, receipt, or
    /// document, not a photograph" verdict. Older systems say unknown.
    static func kind(of image: CGImage) async -> Kind {
        if #available(macOS 15, *) {
            let request = CalculateImageAestheticsScoresRequest()
            guard let observation = try? await request.perform(on: image) else {
                return .unknown
            }
            return observation.isUtility ? .screenshot : .photo
        }
        return .unknown
    }
}
