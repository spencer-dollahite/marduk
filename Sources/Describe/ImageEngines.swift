import Foundation
import AppKit
import CoreGraphics
#if MARDUK_APPLE_IMAGE && canImport(FoundationModels)
import FoundationModels
#endif

/// The description ENGINES, a table the `D` key walks in order. Every
/// engine turns a CGImage (plus Vision's OCR text as context) into a
/// few spoken sentences, or nil; `labels` never returns nil, so the key
/// always says something.
///
/// `auto` = the best thing this machine can run right now: Apple's
/// on-device model when it can see images (macOS 27 with Apple
/// Intelligence), else a local Ollama vision model when one is
/// installed, else Vision's facts. Re-evaluated per press — Apple
/// Intelligence can be switched on, Ollama can be installed.
enum ImageEngine: String, CaseIterable {
    case auto, apple, ollama, labels

    /// The engines to try, in order, for a setting given what is
    /// available. `labels` is always last; `auto` never appears.
    static func chain(setting: ImageEngine, appleReady: Bool,
                      ollamaAvailable: Bool) -> [ImageEngine] {
        switch setting {
        case .auto:
            var order: [ImageEngine] = []
            if appleReady { order.append(.apple) }
            if ollamaAvailable { order.append(.ollama) }
            order.append(.labels)
            return order
        case .apple:
            return appleReady ? [.apple, .labels] : [.labels]
        case .ollama:
            return ollamaAvailable ? [.ollama, .labels] : [.labels]
        case .labels:
            return [.labels]
        }
    }

    /// Why an EXPLICIT choice could not run — spoken before the labels
    /// fallback, so the user learns what to fix. nil when it can.
    static func unavailableReason(setting: ImageEngine, appleReady: Bool,
                                  ollamaAvailable: Bool) -> String? {
        switch setting {
        case .apple where !appleReady:
            return "Apple's on-device model can't describe images here. "
                + "It needs macOS 27 with Apple Intelligence on."
        case .ollama where !ollamaAvailable:
            return "Ollama isn't installed. Say brew install ollama."
        default:
            return nil
        }
    }
}

/// How much a description says — `:config detail brief|normal|full`
/// (`describe.detail`). A prompt variant plus a token cap for the model
/// engines (the cap also bounds latency: brief is the fast one), and a
/// label/text budget for the labels engine. The models have no
/// verbosity dial of their own; this IS the dial.
enum DescribeDetail: String, CaseIterable {
    case brief, normal, full

    /// The length instruction in the prompt.
    var lengthInstruction: String {
        switch self {
        case .brief: return "Use one plain sentence."
        case .normal: return "Use two or three plain sentences."
        case .full:
            return "Use a full paragraph of five to eight plain sentences."
        }
    }

    /// What to cover, beyond the kind and subject every level names.
    var coverage: String {
        switch self {
        case .brief:
            return "Give the main subject and, if there is text, what it says."
        case .normal:
            return "Then the main subject, the setting, and anything the person "
                + "would want to know. Quote any visible text exactly."
        case .full:
            return "Then the main subject and the setting in detail: the people "
                + "by count, expression, clothing and what they are doing, the "
                + "colors, the time of day, the mood, and for a screenshot the "
                + "layout and every control. Quote every piece of visible text exactly."
        }
    }

    /// Ollama's `num_predict` — enough for the level, never a runaway.
    var tokenCap: Int {
        switch self {
        case .brief: return 120
        case .normal: return 320
        case .full: return 800
        }
    }

    /// Labels-engine budgets: how many labels, how much OCR text.
    var labelLimit: Int {
        switch self {
        case .brief: return 2
        case .normal: return ImageFacts.labelLimit
        case .full: return 6
        }
    }

    var textLimit: Int {
        switch self {
        case .brief: return 120
        case .normal: return ImageFacts.textLimit
        case .full: return 900
        }
    }

    static func from(_ raw: String?) -> DescribeDetail {
        raw.flatMap { DescribeDetail(rawValue: $0.lowercased()) } ?? .normal
    }
}

/// One prompt for both language-model engines, pinned by a test: the
/// output shape, the things a blind user needs first, and the rule that
/// the model never guesses who someone is.
enum DescribePrompt {
    /// The normal-detail prompt (kept as a name for the tests and docs).
    static var base: String { base(.normal) }

    /// Jokes are the thing a caption never carries (user ruling
    /// 2026-09-04): the model must notice humor and explain it, at every
    /// detail level.
    static let humor = "If the image is meant to be funny — a meme, a joke, "
        + "a caption, a visual gag, something absurd or ironic — say so, "
        + "describe what is happening, and explain what the joke is."

    static func base(_ detail: DescribeDetail) -> String {
        "Describe this image for a person who cannot see it. "
            + detail.lengthInstruction
            + " Start with what kind of image it is: a photo, a screenshot, "
            + "a drawing, a meme, a diagram. "
            + detail.coverage
            + " " + humor
            + " Do not guess who people are and do not name anyone. "
            + "Do not use markdown or lists."
    }

    /// A follow-up about the same picture: short, grounded, no markdown.
    static func question(_ question: String) -> String {
        question.trimmingCharacters(in: .whitespacesAndNewlines)
            + " Answer in one or two plain sentences, from the image only. "
            + "If the image doesn't show it, say so. No markdown."
    }

    /// The OCR pass's text, when there is some, rides in as context.
    static func text(ocr: String, detail: DescribeDetail = .normal) -> String {
        let trimmed = ocr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base(detail) }
        return base(detail) + "\nA text-recognition pass found this text in the image, "
            + "which may help you read fine print: " + trimmed
    }
}

/// JPEG bytes for the network engine, downscaled first: a 4000px photo
/// is tokens and seconds for nothing, gemma3 tiles at 896px anyway.
enum ImageJPEG {
    static let maxSide = 1024
    static let quality: CGFloat = 0.85

    static func downscale(_ image: CGImage, maxSide: Int = maxSide) -> CGImage {
        let target = ImageRegion.downscaled(width: image.width, height: image.height,
                                            maxSide: maxSide)
        guard target.width != image.width || target.height != image.height,
              let context = CGContext(
                  data: nil, width: target.width, height: target.height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: target.width, height: target.height))
        return context.makeImage() ?? image
    }

    static func data(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: downscale(image))
        return rep.representation(using: .jpeg,
                                  properties: [.compressionFactor: quality])
    }
}

/// The Ollama engine's pure parts: which installed model can see, the
/// request body, and the cleanup of what comes back.
enum OllamaVision {
    static let generateTimeout = 120

    /// Model families known to take images, by tag prefix, best first.
    /// gemma3 is first because it is what the news triage already keeps
    /// on disk (4b and up see; the 1b is text-only and excluded below).
    static let visionFamilies: [String] = [
        "gemma3", "gemma4", "llama3.2-vision", "qwen3-vl", "qwen2.5vl",
        "minicpm-v", "llava", "bakllava", "moondream", "granite3.2-vision",
        "mistral-small3.1", "llama4",
    ]

    /// Tags whose family can see but whose SIZE cannot.
    static let textOnlyVariants: [String] = ["gemma3:1b"]

    static func canSee(tag: String) -> Bool {
        let lower = tag.lowercased()
        guard !textOnlyVariants.contains(where: { lower.hasPrefix($0) }) else {
            return false
        }
        return visionFamilies.contains { lower.hasPrefix($0) }
    }

    /// Installed tags that can see, in family preference order. A
    /// configured pin wins when installed (prefix match, so "gemma3"
    /// finds "gemma3:4b"), whether or not the table knows it — the
    /// user may have a vision model the table hasn't heard of.
    static func candidates(configured: String?, available: [String]) -> [String] {
        var ordered: [String] = []
        if let pin = configured?.trimmingCharacters(in: .whitespaces).lowercased(),
           !pin.isEmpty,
           let match = available.first(where: { $0.lowercased().hasPrefix(pin) }) {
            ordered.append(match)
        }
        for family in visionFamilies {
            for tag in available where tag.lowercased().hasPrefix(family)
                && canSee(tag: tag) && !ordered.contains(tag) {
                ordered.append(tag)
            }
        }
        return ordered
    }

    /// `/api/show`'s capabilities, when the server reports them (Ollama
    /// 0.6+). nil = the server didn't say; trust the table.
    static func showsVision(showJSON: Data) -> Bool? {
        guard let root = try? JSONSerialization.jsonObject(with: showJSON)
                as? [String: Any],
              let capabilities = root["capabilities"] as? [String] else {
            return nil
        }
        return capabilities.contains { $0.lowercased() == "vision" }
    }

    static func payload(model: String, prompt: String, jpegBase64: String,
                        detail: DescribeDetail = .normal) -> [String: Any] {
        [
            "model": model,
            "prompt": prompt,
            "images": [jpegBase64],
            "stream": false,
            "options": ["temperature": 0.2, "num_predict": detail.tokenCap] as [String: Any],
        ]
    }

    /// `/api/chat` messages for a follow-up: the ORIGINAL prompt with the
    /// image attached once, the description the model gave, every earlier
    /// exchange in order, then the new question — so "and the one on the
    /// left?" refers to something. Pure, tested.
    static func chatMessages(description: String, ocr: String, jpegBase64: String,
                             history: [(question: String, answer: String)],
                             question: String,
                             detail: DescribeDetail = .normal) -> [[String: Any]] {
        var messages: [[String: Any]] = [
            ["role": "user", "content": DescribePrompt.text(ocr: ocr, detail: detail),
             "images": [jpegBase64]],
            ["role": "assistant", "content": description],
        ]
        for exchange in history {
            messages.append(["role": "user", "content": exchange.question])
            messages.append(["role": "assistant", "content": exchange.answer])
        }
        messages.append(["role": "user", "content": DescribePrompt.question(question)])
        return messages
    }

    static func chatPayload(model: String, messages: [[String: Any]]) -> [String: Any] {
        [
            "model": model,
            "messages": messages,
            "stream": false,
            // Answers are short by prompt; the cap is a runaway guard
            "options": ["temperature": 0.2, "num_predict": 200] as [String: Any],
        ]
    }

    /// The answer text out of a `/api/chat` reply.
    static func chatAnswer(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        return clean(response: content)
    }

    /// A follow-up question about a retained picture, off-main. The
    /// server is already held by the describer while a picture is
    /// retained, so no acquire here — but a server that has since died
    /// still answers honestly.
    static func ask(question: String, retained: ImageDescriber.Retained)
        -> Result<String, Failure> {
        guard OllamaServer.isLocal(base: retained.base) else { return .failure(.notLocal) }
        let messages = chatMessages(description: retained.description, ocr: retained.ocr,
                                    jpegBase64: retained.jpegBase64,
                                    history: retained.history, question: question,
                                    detail: retained.detail)
        let payload = chatPayload(model: retained.model, messages: messages)
        let started = Date()
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let data = OllamaServer.curl(url: "\(retained.base)/api/chat", body: body,
                                           timeout: generateTimeout)
        else { return .failure(.timeout) }
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = root["error"] as? String, !error.isEmpty {
            fputs("[describe] ollama chat error (\(error.count) chars)\n", stderr)
            return .failure(.refused)
        }
        guard let answer = chatAnswer(data) else { return .failure(.empty) }
        fputs("[describe] ollama answered the question in "
            + String(format: "%.1f", Date().timeIntervalSince(started))
            + "s (\(answer.count) chars)\n", stderr)
        return .success(answer)
    }

    /// The response text, tidied for speech: markdown emphasis and list
    /// markers dropped, whitespace collapsed, capped. nil when empty.
    static let responseLimit = 1200

    static func clean(response: String) -> String? {
        var text = response
        for marker in ["**", "__", "`", "#"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        text = text.replacingOccurrences(of: "(?m)^\\s*[-*•]\\s+", with: "",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ",
                                         options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return ImageFacts.clamp(text, responseLimit)
    }

    struct Answer {
        let text: String
        let model: String
    }

    /// The whole round trip, off-main. Ownership per OllamaServer: a
    /// server we start is stopped when this finishes (the describer
    /// takes its own hold afterwards while the picture is retained).
    static func describe(image: CGImage, ocr: String, base: String,
                         configuredModel: String?,
                         detail: DescribeDetail = .normal) -> Result<Answer, Failure> {
        guard OllamaServer.isLocal(base: base) else { return .failure(.notLocal) }
        let server = OllamaServer.shared
        defer { server.release() }
        switch server.acquire(base: base) {
        case .alreadyRunning, .started: break
        case .notLocal: return .failure(.notLocal)
        case .notInstalled: return .failure(.notInstalled)
        case .failed: return .failure(.notAnswering)
        }
        guard let tags = OllamaServer.curl(url: "\(base)/api/tags", body: nil, timeout: 10),
              let root = try? JSONSerialization.jsonObject(with: tags) as? [String: Any]
        else { return .failure(.notAnswering) }
        let available = (root["models"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
        let candidates = candidates(configured: configuredModel, available: available)
        guard !candidates.isEmpty else { return .failure(.noVisionModel) }
        // Ask the server which candidate really sees; older servers
        // don't say, and the table stands.
        var model = candidates[0]
        for tag in candidates {
            guard let body = try? JSONSerialization.data(withJSONObject: ["model": tag]),
                  let show = OllamaServer.curl(url: "\(base)/api/show", body: body,
                                               timeout: 10) else { continue }
            switch showsVision(showJSON: show) {
            case .some(true): model = tag
            case .some(false): continue
            case .none: model = tag
            }
            break
        }
        guard let jpeg = ImageJPEG.data(image) else { return .failure(.encode) }
        fputs("[describe] ollama \(model): \(jpeg.count) bytes of JPEG\n", stderr)
        let payload = payload(model: model,
                              prompt: DescribePrompt.text(ocr: ocr, detail: detail),
                              jpegBase64: jpeg.base64EncodedString(), detail: detail)
        let started = Date()
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let data = OllamaServer.curl(url: "\(base)/api/generate", body: body,
                                           timeout: generateTimeout),
              let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .failure(.timeout) }
        if let error = answer["error"] as? String, !error.isEmpty {
            fputs("[describe] ollama error (\(error.count) chars)\n", stderr)
            return .failure(.refused)
        }
        guard let response = answer["response"] as? String,
              let text = clean(response: response) else { return .failure(.empty) }
        fputs("[describe] ollama answered in "
            + String(format: "%.1f", Date().timeIntervalSince(started))
            + "s (\(text.count) chars)\n", stderr)
        return .success(Answer(text: text, model: model))
    }

    enum Failure: Error {
        case notLocal, notInstalled, notAnswering, noVisionModel, encode
        case timeout, refused, empty

        var spoken: String {
            switch self {
            case .notLocal:
                return "Image description only uses a local Ollama."
            case .notInstalled:
                return "Ollama isn't installed. Say brew install ollama."
            case .notAnswering:
                return "Ollama isn't answering."
            case .noVisionModel:
                return "Ollama has no vision model. Say ollama pull gemma3."
            case .encode:
                return "Couldn't encode the image."
            case .timeout:
                return "The model didn't answer in time."
            case .refused:
                return "Ollama refused the image. Check the image model setting."
            case .empty:
                return "The model said nothing."
            }
        }
    }
}

/// Apple's on-device model with an image attachment — macOS 27's
/// Foundation Models. Compiled ONLY with `-DMARDUK_APPLE_IMAGE` until
/// the API shape is confirmed against the Xcode 27 SDK on the Mac (the
/// zero-warning update gate would otherwise hold every update hostage
/// to a symbol we have only read about). Once confirmed, the flag
/// becomes a compiler-version guard and `auto` prefers this engine on
/// macOS 27. Only `SystemLanguageModel.default` — the on-device model —
/// is ever used; a test forbids any other model reference in this file.
enum AppleImageModel {
    static let modelName = "apple"
    /// The session that described the last picture, kept so questions
    /// ride its transcript. Stored untyped so the property compiles
    /// without the flag; only flagged code touches it.
    private static var sessionBox: Any?

    static var isReady: Bool {
        #if MARDUK_APPLE_IMAGE && canImport(FoundationModels)
        if #available(macOS 27, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        #endif
        return false
    }

    static func describe(image: CGImage, ocr: String,
                         detail: DescribeDetail = .normal) async -> String? {
        #if MARDUK_APPLE_IMAGE && canImport(FoundationModels)
        guard #available(macOS 27, *), isReady else { return nil }
        let session = LanguageModelSession(model: SystemLanguageModel.default)
        sessionBox = session
        let small = ImageJPEG.downscale(image)
        let started = Date()
        do {
            let response = try await session.respond {
                DescribePrompt.text(ocr: ocr, detail: detail)
                Attachment(cgImage: small)
            }
            let text = OllamaVision.clean(response: response.content)
            fputs("[describe] apple answered in "
                + String(format: "%.1f", Date().timeIntervalSince(started))
                + "s (\(text?.count ?? 0) chars)\n", stderr)
            return text
        } catch {
            fputs("[describe] apple model failed: \(error.localizedDescription)\n",
                  stderr)
            return nil
        }
        #else
        return nil
        #endif
    }

    /// A follow-up on the retained session's transcript.
    static func ask(question: String) async -> String? {
        #if MARDUK_APPLE_IMAGE && canImport(FoundationModels)
        guard #available(macOS 27, *), isReady,
              let session = sessionBox as? LanguageModelSession else { return nil }
        do {
            let response = try await session.respond(to: DescribePrompt.question(question))
            return OllamaVision.clean(response: response.content)
        } catch {
            fputs("[describe] apple question failed: \(error.localizedDescription)\n",
                  stderr)
            return nil
        }
        #else
        return nil
        #endif
    }
}
