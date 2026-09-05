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
/// QUESTIONS (user design 2026-09-04): a description is a guess at what
/// you wanted to know; a question is not. When a MODEL described the
/// picture, the description ends on "Do you have any questions? y for
/// yes, n for no." — the armed one-key question (the dialog-focus and
/// `dd` pattern) — and `y` opens the command line with "ask " already
/// typed. `:ask <question>` sends the SAME image back with the question
/// and every earlier exchange, so "and the one on the left?" works; each
/// answer ends on the same prompt. The picture is RETAINED in memory
/// only (never disk), about the LAST DESCRIBED image rather than
/// whatever is under the pointer now, and forgotten on the next D, on
/// Ctrl+Option+M, when the extension is switched off, or after
/// `retainFor` idle. While it is retained an Ollama server Marduk
/// started is HELD warm (one extra acquire on the refcount), so answers
/// take seconds instead of a cold start. The labels engine cannot
/// answer questions, so it asks none.
///
/// Privacy: the image, the description, the questions and the answers
/// are user content and never reach the log — `[describe]` lines carry
/// the rung, the engine, pixel sizes, byte counts, seconds, error codes
/// and lengths. Captures are of the window under the pointer only
/// (never the display), live in memory, and go nowhere but the chosen
/// local engine.
final class ImageDescriber {

    // Wired by the daemon
    var announce: (String) -> Void = { _ in }
    /// Announce, then run the completion (fires on cancel too — the
    /// question window is EXTENDED there, never armed there).
    var announceThen: (String, @escaping () -> Void) -> Void = { _, done in done() }
    var armQuestion: (Set<Character>, @escaping (Character) -> Void) -> Void = { _, _ in }
    var extendQuestionWindow: () -> Void = {}
    /// Enter COMMAND mode with a prefilled buffer — `y` lands in "ask ".
    var openCommandLine: (String) -> Void = { _ in }
    /// True from the D press until the description has been spoken —
    /// the window in which v / vv / vvv re-describe (KeyboardMonitor
    /// reads it in the burst flush).
    var onActiveChange: (Bool) -> Void = { _ in }
    var settings: () -> MardukConfig = { MardukConfig() }
    var isEngaged: () -> Bool = { true }
    /// A read the user started AFTER pressing D wins — the description
    /// is dropped rather than spoken over it (the triage rule).
    var isReadActive: () -> Bool = { false }

    static let helpLine = "Press r r to hear it again."
    static let defaultOllamaBase = "http://127.0.0.1:11434"
    static let questionPrompt = "Do you have any questions? y for yes, n for no."
    static let morePrompt = "Any more questions? y for yes, n for no."
    static let askPrefill = "ask "
    /// How long a described picture stays answerable with nothing asked.
    static let retainFor: TimeInterval = 10 * 60

    /// The last described picture, answerable by `:ask`.
    struct Retained {
        let jpegBase64: String
        let ocr: String
        let description: String
        let engine: ImageEngine
        let model: String
        let base: String
        let detail: DescribeDetail
        let customPrompt: String?
        var history: [(question: String, answer: String)] = []
        var holdsServer: Bool
    }

    /// What a re-describe at another detail needs; kept only while
    /// `active` (one image plus its facts — dropped when the description
    /// has been spoken, so memory never holds a picture nobody can act on).
    struct LastRun {
        let image: CGImage
        let facts: ImageFacts
        let label: String?
        let source: ImageSource
        let setting: ImageEngine
        let base: String
        let configuredModel: String?
        let customPrompt: String?
        /// DD: the screen prompt is used, at whatever detail the
        /// re-describe asks for — the user's own prompt is for pictures.
        var screen = false

        func prompt(for detail: DescribeDetail) -> String? {
            screen ? DescribePrompt.screen(detail) : customPrompt
        }
    }

    /// Browsers keep their web AX tree minimal until an assistive client
    /// announces itself, so the element under the pointer over a web image
    /// can come back as the whole web area. When the first look finds no
    /// picture and no file, Marduk announces itself (the read rung's
    /// AXNudge, ledgered and restored right after the capture), waits for
    /// the tree, and looks once more.
    static let nudgeSettle: TimeInterval = 0.4

    private(set) var running = false
    private var runGeneration = 0
    private(set) var retained: Retained?
    private var idleTimer: DispatchWorkItem?
    private var lastRun: LastRun?
    /// v-taps that arrived while the model was still thinking — applied
    /// the moment the picture is ready, so nothing typed is lost.
    private var pendingDetail: DescribeDetail?
    /// Set by the daemon's central stop (Escape, the read button): a
    /// description the user cut short must not re-arm its question.
    private var stoppedByUser = false
    private var active = false {
        didSet {
            guard active != oldValue else { return }
            if !active { lastRun = nil }
            onActiveChange(active)
        }
    }

    // MARK: - Entry (main thread)

    func describe() {
        runGeneration += 1
        let generation = runGeneration
        running = true
        pendingDetail = nil
        // The last picture (and its warm server) is replaced only once
        // the new one is ready — see describeAndSpeak
        let config = settings()
        let pointer = NSEvent.mouseLocation
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let base = config.describe?.ollamaURL ?? config.news?.ollamaURL
            ?? Self.defaultOllamaBase
        // The environment line — what the engines and the capture rung
        // need — so a pasted log answers "why labels and not a model"
        fputs("[describe] D: macOS \(os.majorVersion).\(os.minorVersion)"
            + ", screen recording " + (CGPreflightScreenCaptureAccess() ? "granted" : "NOT granted")
            + ", apple image model " + (AppleImageModel.isReady ? "ready" : "unavailable")
            + ", ollama " + (Self.ollamaAvailable(base: base) ? "available" : "absent")
            + ", setting \(config.describe?.imageModel ?? "auto")\n", stderr)
        let located = ImageAcquire.locate(pointer: pointer)
        fputs("[describe] D: app \(located.bundleID ?? "?")"
            + (located.axFailed ? ", AX failed" : "")
            + ", rungs: file \(located.fileURL != nil ? "yes" : "no")"
            + ", window document \(located.documentURL != nil ? "yes" : "no")"
            + ", capture " + (located.imageShaped ? "element" : "whole window") + "\n",
            stderr)

        var opening = "Describing."
        if OnceMarker.firstTime("describe-hinted") {
            opening += " " + Self.helpLine
        }
        announce(opening)
        active = true

        let setting = ImageEngine(rawValue: config.describe?.imageModel ?? "auto") ?? .auto
        let configuredModel = config.describe?.ollamaModel ?? config.news?.ollamaModel
        let detail = DescribeDetail.from(config.describe?.detail)
        let customPrompt = DescribePrompt.custom(config.describe?.prompt)
        if customPrompt != nil {
            fputs("[describe] using the user's own prompt\n", stderr)
        }

        if let pid = located.pid, Self.wantsNudge(located) {
            AXNudge.shared.enhance(pid: pid, flags: [.enhanced, .manual])
            fputs("[describe] no picture on first look — nudged the app, looking again\n",
                  stderr)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.nudgeSettle) { [weak self] in
                guard let self, generation == self.runGeneration else { return }
                let again = ImageAcquire.locate(pointer: pointer)
                fputs("[describe] after the nudge: capture "
                    + (again.imageShaped ? "element" : "whole window") + "\n", stderr)
                self.acquireAndSpeak(
                    { await ImageAcquire.acquire(again, pointer: pointer) },
                    label: again.label, screen: false, generation: generation,
                    setting: setting, base: base, configuredModel: configuredModel,
                    detail: detail, customPrompt: customPrompt, nudged: true)
            }
            return
        }
        acquireAndSpeak(
            { await ImageAcquire.acquire(located, pointer: pointer) },
            label: located.label, screen: false, generation: generation,
            setting: setting, base: base, configuredModel: configuredModel,
            detail: detail, customPrompt: customPrompt, nudged: false)
    }

    /// DD: the whole display under the pointer, every window front to
    /// back, composited un-zoomed. Same engines, questions and v-taps as
    /// a picture; a screen-specific prompt.
    func describeScreen() {
        runGeneration += 1
        let generation = runGeneration
        running = true
        pendingDetail = nil
        let config = settings()
        let pointer = NSEvent.mouseLocation
        let base = config.describe?.ollamaURL ?? config.news?.ollamaURL
            ?? Self.defaultOllamaBase
        fputs("[describe] DD: screen recording "
            + (CGPreflightScreenCaptureAccess() ? "granted" : "NOT granted")
            + ", ollama " + (Self.ollamaAvailable(base: base) ? "available" : "absent")
            + ", setting \(config.describe?.imageModel ?? "auto")\n", stderr)
        announce("Describing the screen.")
        active = true
        let setting = ImageEngine(rawValue: config.describe?.imageModel ?? "auto") ?? .auto
        let configuredModel = config.describe?.ollamaModel ?? config.news?.ollamaModel
        let detail = DescribeDetail.from(config.describe?.detail)
        acquireAndSpeak(
            { await ImageAcquire.captureScreen(pointer: pointer) },
            label: nil, screen: true, generation: generation, setting: setting,
            base: base, configuredModel: configuredModel, detail: detail,
            customPrompt: nil, nudged: false)
    }

    /// The first look found neither a picture nor a file, and AX did
    /// answer — the shape of a browser that hasn't published its tree.
    static func wantsNudge(_ located: LocatedElement) -> Bool {
        !located.axFailed && located.pid != nil && !located.imageShaped
            && located.fileURL == nil && located.documentURL == nil
    }

    private func acquireAndSpeak(_ acquire: @escaping () async -> ImageAcquire.Outcome,
                                 label: String?, screen: Bool,
                                 generation: Int, setting: ImageEngine, base: String,
                                 configuredModel: String?, detail: DescribeDetail,
                                 customPrompt: String?, nudged: Bool) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = await acquire()
            // The flags were for the look and the capture; the app gets
            // them back now, whatever happened
            if nudged { AXNudge.shared.restoreAll(reason: "describe captured") }
            guard let self else { return }
            guard case .image(let acquired) = outcome else {
                await self.finish(generation) {
                    self.active = false
                    self.speakAcquireFailure(outcome)
                }
                return
            }
            fputs("[describe] \(acquired.source.rawValue): "
                + "\(acquired.image.width)x\(acquired.image.height)\n", stderr)
            let facts = await ImageFacts.gather(acquired.image)
            let run = LastRun(image: acquired.image, facts: facts, label: label,
                              source: acquired.source, setting: setting, base: base,
                              configuredModel: configuredModel, customPrompt: customPrompt,
                              screen: screen)
            await self.describeAndSpeak(run, detail: detail, generation: generation)
        }
    }

    /// v / vv / vvv while a description is in flight or speaking: the
    /// same picture again at brief / normal / full, the setting untouched.
    func redescribe(taps: Int) {
        let detail: DescribeDetail = taps <= 1 ? .brief : (taps == 2 ? .normal : .full)
        guard active else {
            Earcon.error()
            return
        }
        guard let run = lastRun else {
            // Still capturing or still thinking: remember the wish and
            // say so, and the first description comes out at that level
            pendingDetail = detail
            fputs("[describe] \(detail.rawValue) requested before the picture was ready — queued\n",
                  stderr)
            announce(detail.rawValue.prefix(1).uppercased() + detail.rawValue.dropFirst()
                + ", when it's ready.")
            return
        }
        runGeneration += 1
        let generation = runGeneration
        running = true
        fputs("[describe] re-describing at \(detail.rawValue)\n", stderr)
        announce(detail.rawValue.prefix(1).uppercased() + detail.rawValue.dropFirst() + ".")
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.describeAndSpeak(run, detail: detail, generation: generation)
        }
    }

    /// Off-main: the engine chain, then back to main to speak. Shared by
    /// D and by the v-taps.
    private func describeAndSpeak(_ run: LastRun, detail requested: DescribeDetail,
                                  generation: Int) async {
        // v-taps that landed while the picture was being captured win
        let detail = await MainActor.run { () -> DescribeDetail in
            defer { self.pendingDetail = nil }
            return self.pendingDetail ?? requested
        }
        let prompt = run.prompt(for: detail)
        // Take the server hold BEFORE describing: the describe's own
        // acquire/release pair would otherwise drop the refcount to zero
        // in between and STOP a server Marduk started, so the hold that
        // followed cold-started a second one (field 2026-09-05: "ollama
        // stopped… ollama started" around every description, and the
        // first question paid the whole start-up again).
        var holds = false
        if Self.ollamaAvailable(base: run.base) && run.setting != .labels
            && run.setting != .apple {
            switch OllamaServer.shared.acquire(base: run.base) {
            case .alreadyRunning, .started: holds = true
            default: OllamaServer.shared.release()
            }
        }
        let described = await self.run(setting: run.setting, image: run.image,
                                       facts: run.facts, base: run.base,
                                       configuredModel: run.configuredModel,
                                       detail: detail, custom: prompt)
        let spoken = Self.compose(kind: run.facts.kindWord, label: run.label,
                                  source: run.source, body: described.text)
        // A model answered: keep the picture answerable (and the server
        // warm for the questions); otherwise hand the hold straight back
        var keep: Retained?
        if described.engine != .labels, let model = described.model,
           let jpeg = ImageJPEG.data(run.image) {
            keep = Retained(jpegBase64: jpeg.base64EncodedString(), ocr: run.facts.text,
                            description: described.text, engine: described.engine,
                            model: model, base: run.base, detail: detail,
                            customPrompt: prompt,
                            holdsServer: holds && described.engine == .ollama)
        }
        if holds, keep?.holdsServer != true { OllamaServer.shared.release() }
        await finish(generation) {
            // The previous picture (and its hold) goes only now that the
            // new one exists — a warm server stays warm across pictures
            self.forget(reason: "replaced")
            self.lastRun = run
            self.retained = keep
            // v-taps that landed while the model was thinking: say this
            // one at that level instead, right away
            if let wanted = self.pendingDetail, wanted != detail {
                self.pendingDetail = nil
                self.redescribe(taps: wanted == .brief ? 1 : (wanted == .normal ? 2 : 3))
                return
            }
            self.pendingDetail = nil
            if let keep {
                fputs("[describe] retained for questions (\(keep.engine.rawValue)"
                    + (keep.holdsServer ? ", server held" : "") + ")\n", stderr)
                self.speakWithQuestion(spoken, prompt: Self.questionPrompt)
            } else {
                self.announceThen(spoken) { [weak self] in self?.active = false }
            }
        }
    }

    /// Any stop that isn't ours — Escape, Ctrl+Option+M — orphans a
    /// description still being made. The work finishes and is dropped.
    /// The retained picture SURVIVES this: Escape stops speech, it does
    /// not end the conversation.
    func abort() {
        guard running else { return }
        running = false
        runGeneration += 1
        active = false
        fputs("[describe] abandoned\n", stderr)
    }

    /// The daemon's central stop (Escape, the read button). A description
    /// cut short keeps its picture — Escape is not the end of the
    /// conversation — but must not re-arm its y/n when the cut-off
    /// utterance's completion fires.
    func noteStop() {
        stoppedByUser = true
    }

    /// Drop the retained picture and hand back the server hold. Main
    /// thread. Silent — the user asked nothing, nothing is lost.
    func forget(reason: String = "forgotten") {
        idleTimer?.cancel()
        idleTimer = nil
        guard let old = retained else { return }
        retained = nil
        if old.holdsServer { OllamaServer.shared.release() }
        fputs("[describe] picture \(reason) after \(old.history.count) questions\n", stderr)
    }

    // MARK: - Questions (main thread)

    func ask(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let kept = retained else {
            Earcon.error()
            announce("Nothing described yet. Point at a picture and press capital D first.")
            return
        }
        guard !trimmed.isEmpty else {
            Earcon.error()
            announce("Ask what? Say colon ask, then your question.")
            return
        }
        runGeneration += 1
        let generation = runGeneration
        running = true
        armIdleTimer()
        fputs("[describe] ask #\(kept.history.count + 1) (\(trimmed.count) chars)"
            + " via \(kept.engine.rawValue)\n", stderr)
        announce("Asking.")
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let result: Result<String, OllamaVision.Failure>
            switch kept.engine {
            case .apple:
                if let text = await AppleImageModel.ask(question: trimmed) {
                    result = .success(text)
                } else {
                    result = .failure(.empty)
                }
            default:
                result = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: OllamaVision.ask(
                            question: trimmed, retained: kept))
                    }
                }
            }
            await self.finish(generation) {
                switch result {
                case .success(let answer):
                    self.retained?.history.append((trimmed, answer))
                    self.speakWithQuestion(answer, prompt: Self.morePrompt)
                case .failure(let failure):
                    fputs("[describe] ask failed: \(failure)\n", stderr)
                    Earcon.error()
                    self.announce(failure.spoken)
                }
            }
        }
    }

    /// Speak, ending on the y/n prompt. The window is armed now, so an
    /// early answer counts, and ARMED AGAIN when the speech ends: the
    /// armed window is ~20s from arming, and a description plus the
    /// prompt routinely runs longer (23s and 61s in the field log
    /// 2026-09-05), so by the time the question was asked the window had
    /// already lapsed and `y` fell through to NORMAL and buzzed. A
    /// description the user cut short re-arms nothing.
    private func speakWithQuestion(_ text: String, prompt: String) {
        armIdleTimer()
        stoppedByUser = false
        let arm: () -> Void = { [weak self] in
            self?.armQuestion(["y", "n"]) { [weak self] answer in
                guard let self else { return }
                if answer == "y" {
                    fputs("[describe] y — opening the ask line\n", stderr)
                    self.openCommandLine(Self.askPrefill)
                }
                // n: nothing to say — the description was the answer
            }
        }
        arm()
        announceThen(text + " " + prompt) { [weak self] in
            guard let self else { return }
            // The description has been heard: v is VISUAL again
            self.active = false
            guard !self.stoppedByUser else {
                fputs("[describe] cut short — no question\n", stderr)
                return
            }
            arm()
            self.extendQuestionWindow()
        }
    }

    private func armIdleTimer() {
        idleTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.forget(reason: "idle")
        }
        idleTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retainFor, execute: work)
    }

    // MARK: - Engines (off-main)

    struct Described {
        let text: String
        let engine: ImageEngine
        let model: String?
    }

    /// Walks the engine chain; the labels engine is the floor and always
    /// answers. An explicit engine that can't run says why first.
    private func run(setting: ImageEngine, image: CGImage, facts: ImageFacts,
                     base: String, configuredModel: String?,
                     detail: DescribeDetail, custom: String?) async -> Described {
        let appleReady = AppleImageModel.isReady
        let ollamaAvailable = Self.ollamaAvailable(base: base)
        var preface = ImageEngine.unavailableReason(
            setting: setting, appleReady: appleReady, ollamaAvailable: ollamaAvailable)
        let chain = ImageEngine.chain(setting: setting, appleReady: appleReady,
                                      ollamaAvailable: ollamaAvailable)
        fputs("[describe] engines: \(chain.map(\.rawValue).joined(separator: " → "))"
            + ", detail \(detail.rawValue)\n", stderr)
        func prefaced(_ text: String) -> String {
            (preface.map { $0 + " " } ?? "") + text
        }
        for engine in chain {
            switch engine {
            case .apple:
                if let text = await AppleImageModel.describe(image: image, ocr: facts.text,
                                                             detail: detail, custom: custom) {
                    return Described(text: prefaced(text), engine: .apple,
                                     model: AppleImageModel.modelName)
                }
            case .ollama:
                // curl blocks for up to two minutes — on a GCD thread,
                // never one of the cooperative pool's few
                let result: Result<OllamaVision.Answer, OllamaVision.Failure>
                    = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: OllamaVision.describe(
                            image: image, ocr: facts.text, base: base,
                            configuredModel: configuredModel, detail: detail,
                            custom: custom))
                    }
                }
                switch result {
                case .success(let answer):
                    return Described(text: prefaced(answer.text), engine: .ollama,
                                     model: answer.model)
                case .failure(let failure):
                    fputs("[describe] ollama: \(failure)\n", stderr)
                    // Only an explicit choice explains itself; under auto
                    // the next rung just answers.
                    if setting == .ollama { preface = failure.spoken }
                }
            case .labels:
                return Described(text: prefaced(facts.spoken(detail: detail)),
                                 engine: .labels, model: nil)
            case .auto:
                break
            }
        }
        return Described(text: facts.spoken(detail: detail), engine: .labels, model: nil)
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
        if source == .screen { return "Your screen. " + body }
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
