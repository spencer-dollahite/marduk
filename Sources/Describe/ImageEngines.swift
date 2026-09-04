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

/// One prompt for both language-model engines, pinned by a test: the
/// output shape, the things a blind user needs first, and the rule that
/// the model never guesses who someone is.
enum DescribePrompt {
    static let base = """
        Describe this image for a person who cannot see it. \
        Use two or three plain sentences. Start with what kind of image \
        it is: a photo, a screenshot, a drawing, a meme, a diagram. \
        Then the main subject, the setting, and anything the person \
        would want to know. Quote any visible text exactly. \
        Do not guess who people are and do not name anyone. \
        Do not use markdown or lists.
        """

    /// The OCR pass's text, when there is some, rides in as context.
    static func text(ocr: String) -> String {
        let trimmed = ocr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        return base + "\nA text-recognition pass found this text in the image, "
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

    static func payload(model: String, prompt: String,
                        jpegBase64: String) -> [String: Any] {
        [
            "model": model,
            "prompt": prompt,
            "images": [jpegBase64],
            "stream": false,
            "options": ["temperature": 0.2],
        ]
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

    /// The whole round trip, off-main. Ownership per OllamaServer: a
    /// server we start is stopped when this finishes.
    static func describe(image: CGImage, ocr: String, base: String,
                         configuredModel: String?) -> Result<String, Failure> {
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
        let payload = payload(model: model, prompt: DescribePrompt.text(ocr: ocr),
                              jpegBase64: jpeg.base64EncodedString())
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
        return .success(text)
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

    static func describe(image: CGImage, ocr: String) async -> String? {
        #if MARDUK_APPLE_IMAGE && canImport(FoundationModels)
        guard #available(macOS 27, *), isReady else { return nil }
        let session = LanguageModelSession(model: SystemLanguageModel.default)
        let small = ImageJPEG.downscale(image)
        let started = Date()
        do {
            let response = try await session.respond {
                DescribePrompt.text(ocr: ocr)
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
}
