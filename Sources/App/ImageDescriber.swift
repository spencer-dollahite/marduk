import Foundation
import AppKit
import CoreGraphics

/// IMAGE DESCRIPTION (`D`): hover the pointer over a picture, press
/// capital D, hear what it shows. Two ladders and a table — where the
/// pixels come from (`ImageAcquire`: a file the element names, the
/// window's document, else a screenshot of the element or its window)
/// and what turns them into words (`ImageEngine`: Apple's on-device
/// model when it can see, a local Ollama vision model when installed,
/// else Vision's own facts) — with Vision's OCR riding every engine.
///
/// The result is an ANNOUNCEMENT, not a read: a few sentences, `rr`
/// replays it (SpeechLog records announcements), Escape stops it, and
/// it never engages the reading capture over a status line. "Describing."
/// speaks the instant the key lands, because a local model can take
/// ten seconds cold and a silent key reads as a dead one.
///
/// Privacy: the image and the description are user content and never
/// reach the log — `[describe]` lines carry the rung, the engine, pixel
/// sizes, byte counts, seconds and error codes. Captures are of the
/// window under the pointer only (never the display), live in memory,
/// and go nowhere but the chosen local engine.
final class ImageDescriber {

    // Wired by the daemon
    var announce: (String) -> Void = { _ in }
    var settings: () -> MardukConfig = { MardukConfig() }
    var isEngaged: () -> Bool = { true }
    /// A read the user started AFTER pressing D wins — the description
    /// is dropped rather than spoken over it (the triage rule).
    var isReadActive: () -> Bool = { false }

    static let helpLine = "Press r r to hear it again."
    static let defaultOllamaBase = "http://127.0.0.1:11434"

    private(set) var running = false
    private var runGeneration = 0

    // MARK: - Entry (main thread)

    func describe() {
        runGeneration += 1
        let generation = runGeneration
        running = true
        let config = settings()
        let pointer = NSEvent.mouseLocation
        let located = ImageAcquire.locate(pointer: pointer)
        fputs("[describe] D: app \(located.bundleID ?? "?"), "
            + (located.axFailed ? "AX failed, " : "")
            + "image-shaped \(located.imageShaped), "
            + "file \(located.fileURL != nil), document \(located.documentURL != nil)\n",
            stderr)

        var opening = "Describing."
        if OnceMarker.firstTime("describe-hinted") {
            opening += " " + Self.helpLine
        }
        announce(opening)

        let setting = ImageEngine(rawValue: config.describe?.imageModel ?? "auto") ?? .auto
        let base = config.describe?.ollamaURL ?? config.news?.ollamaURL
            ?? Self.defaultOllamaBase
        let configuredModel = config.describe?.ollamaModel ?? config.news?.ollamaModel

        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = await ImageAcquire.acquire(located, pointer: pointer)
            guard let self else { return }
            guard case .image(let acquired) = outcome else {
                await self.finish(generation) { self.speakAcquireFailure(outcome) }
                return
            }
            fputs("[describe] \(acquired.source.rawValue): "
                + "\(acquired.image.width)x\(acquired.image.height)\n", stderr)
            let facts = await ImageFacts.gather(acquired.image)
            let text = await self.run(setting: setting, image: acquired.image,
                                      facts: facts, base: base,
                                      configuredModel: configuredModel)
            let spoken = Self.compose(kind: facts.kindWord, label: located.label,
                                      source: acquired.source, body: text)
            await self.finish(generation) { self.announce(spoken) }
        }
    }

    /// Any stop that isn't ours — Escape, Ctrl+Option+M — orphans a
    /// description still being made. The work finishes and is dropped.
    func abort() {
        guard running else { return }
        running = false
        runGeneration += 1
        fputs("[describe] abandoned\n", stderr)
    }

    // MARK: - Engines (off-main)

    /// Walks the engine chain; the labels engine is the floor and always
    /// answers. An explicit engine that can't run says why first.
    private func run(setting: ImageEngine, image: CGImage, facts: ImageFacts,
                     base: String, configuredModel: String?) async -> String {
        let appleReady = AppleImageModel.isReady
        let ollamaAvailable = Self.ollamaAvailable(base: base)
        var preface = ImageEngine.unavailableReason(
            setting: setting, appleReady: appleReady, ollamaAvailable: ollamaAvailable)
        let chain = ImageEngine.chain(setting: setting, appleReady: appleReady,
                                      ollamaAvailable: ollamaAvailable)
        fputs("[describe] engines: \(chain.map(\.rawValue).joined(separator: " → "))\n",
              stderr)
        for engine in chain {
            switch engine {
            case .apple:
                if let text = await AppleImageModel.describe(image: image, ocr: facts.text) {
                    return (preface.map { $0 + " " } ?? "") + text
                }
            case .ollama:
                // curl blocks for up to two minutes — on a GCD thread,
                // never one of the cooperative pool's few
                let result: Result<String, OllamaVision.Failure>
                    = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: OllamaVision.describe(
                            image: image, ocr: facts.text, base: base,
                            configuredModel: configuredModel))
                    }
                }
                switch result {
                case .success(let text):
                    return (preface.map { $0 + " " } ?? "") + text
                case .failure(let failure):
                    fputs("[describe] ollama: \(failure)\n", stderr)
                    // Only an explicit choice explains itself; under auto
                    // the next rung just answers.
                    if setting == .ollama { preface = failure.spoken }
                }
            case .labels:
                return (preface.map { $0 + " " } ?? "") + facts.spoken
            case .auto:
                break
            }
        }
        return facts.spoken
    }

    /// Installed binary or an answering local server — either can serve.
    static func ollamaAvailable(base: String) -> Bool {
        guard OllamaServer.isLocal(base: base) else { return false }
        if OllamaServer.binaryPaths.contains(where: {
            FileManager.default.isExecutableFile(atPath: $0) }) { return true }
        return OllamaServer.shared.answering(base)
    }

    // MARK: - Speech

    /// Kind first, the element's own label when it says more than
    /// "image", the whole-window caveat, then the engine's sentences.
    static func compose(kind: String, label: String?, source: ImageSource,
                        body: String) -> String {
        var parts = [kind]
        if let label, !ImageRegion.isGenericLabel(label) {
            parts.append("Labeled \(label).")
        }
        if source == .windowCapture {
            parts.append("No single image under the pointer, so this is the whole window.")
        }
        parts.append(body)
        return parts.joined(separator: " ")
    }

    private func speakAcquireFailure(_ outcome: ImageAcquire.Outcome) {
        Earcon.error()
        switch outcome {
        case .needsScreenRecording:
            Self.primeScreenRecording()
            announce("Describe needs the Screen Recording permission to see "
                + "the image. I opened that Settings pane: find Marduk in "
                + "the list, turn it on, and choose quit and reopen when "
                + "macOS offers — Marduk restarts itself.")
        case .noWindow:
            announce("No window under the pointer.")
        case .failed:
            announce("Couldn't capture the image.")
        case .image:
            break
        }
    }

    /// Screen Recording is requested at the first D that needs it, never
    /// at install (the smartinvert flow: modern macOS registers the app
    /// in the pane silently, so prime, open the pane, and narrate).
    static func primeScreenRecording() {
        CGRequestScreenCaptureAccess()
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["x-apple.systempreferences:"
            + "com.apple.preference.security?Privacy_ScreenCapture"]
        try? opener.run()
    }

    /// Back on main: speak only if this press is still the live one,
    /// Marduk is engaged, and no read has started meanwhile.
    @MainActor
    private func finish(_ generation: Int, _ speak: @escaping () -> Void) {
        guard generation == runGeneration else {
            fputs("[describe] superseded — dropped\n", stderr)
            return
        }
        running = false
        guard isEngaged() else {
            fputs("[describe] Marduk was switched off — not speaking\n", stderr)
            return
        }
        guard !isReadActive() else {
            fputs("[describe] a read started meanwhile — dropped\n", stderr)
            return
        }
        speak()
    }
}
