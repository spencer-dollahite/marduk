import Foundation

/// Interactive vimtutor-style tour. Instructions are spoken; the user
/// performs real actions and the engine watches for their events — wrong
/// keys just do what they normally do and never advance a lesson.
/// Main-thread-only (all events arrive via main-queue dispatch).
final class Tutorial {

    enum Event: Equatable {
        case mode(KeyboardMonitor.Mode)
        case readFinished          // a keyboard-originated read completed
        case pauseToggled          // Space pause/resume fired
        case announced(String)     // a monitor-originated announcement
        case readJumped            // a reading-mode motion fired (b w ( ) gg …)
        case spelled               // z/Z spelled a word or sentence
    }

    private struct Step {
        let instruction: String
        let isComplete: (Event) -> Bool
        let success: String
    }

    private(set) var isActive = false
    private var index = 0
    private var steps: [Step] = []

    /// Injected by DaemonServer → speech.announce. The tutorial narrates in
    /// the announcement voice so it stays audibly distinct from the content
    /// reads its lessons trigger — and never observes its own speech.
    var announce: ((String) -> Void)?

    func start() {
        guard !isActive else { return }
        steps = Self.makeSteps()   // fresh step-local state every run
        index = 0
        isActive = true
        fputs("[tutorial] started\n", stderr)
        announce?(Self.intro + " " + steps[0].instruction)
    }

    func abort(silent: Bool) {
        guard isActive else { return }
        isActive = false
        steps = []
        fputs("[tutorial] aborted\n", stderr)
        if !silent { announce?("Tutorial ended.") }
    }

    func handle(_ event: Event) {
        guard isActive, steps.indices.contains(index) else { return }
        guard steps[index].isComplete(event) else { return }
        let finished = steps[index]
        // Advance BEFORE speaking: events arriving during the success
        // announcement evaluate against the next step, never re-fire this one.
        index += 1
        fputs("[tutorial] step \(index) complete\n", stderr)
        if steps.indices.contains(index) {
            announce?(finished.success + " " + steps[index].instruction)
        } else {
            isActive = false
            fputs("[tutorial] finished\n", stderr)
            announce?(finished.success + " " + Self.wrapUp)
        }
    }

    // MARK: - Script

    private static let intro = """
        Welcome to the Marduk tutorial. Eleven short lessons. The keys you \
        press act for real, so open a text editor with a few lines of text \
        first. To leave at any time, type colon tutorial again.
        """

    private static let wrapUp = """
        That's the tour. Type colon help for the basics, colon commands for \
        the full list. Tutorial complete.
        """

    private static func makeSteps() -> [Step] {
        var sawVisual = false
        var pauseCount = 0
        return [
            Step(instruction: "Lesson one. Press the letter i. That enters "
                    + "INSERT mode, where typing goes to the app.",
                 isComplete: { $0 == .mode(.insert) },
                 success: "That's it. The falling tones mean typing is live."),

            Step(instruction: "Lesson two. Hold Escape down for about half a "
                    + "second. A quick tap stays with the app. Only a hold "
                    + "returns to NORMAL mode.",
                 isComplete: { $0 == .mode(.normal) },
                 success: "Good. The rising tones always mean NORMAL mode."),

            Step(instruction: "Lesson three. Click on some text, then press "
                    + "lowercase r. It selects the paragraph under the cursor, like a "
                    + "triple click, and reads it.",
                 isComplete: { $0 == .readFinished },
                 success: "That is the read command."),

            Step(instruction: "Lesson four. Press v for visual mode, then j "
                    + "to extend the selection down, then lowercase r to read the "
                    + "selection.",
                 isComplete: { event in
                     if event == .mode(.visual) || event == .mode(.visualLine) {
                         sawVisual = true
                     }
                     return event == .readFinished && sawVisual
                 },
                 success: "Nice. Select, then read."),

            Step(instruction: "Lesson five. Press lowercase r to start a read. While it "
                    + "is speaking, tap Space to pause. Tap Space again to "
                    + "resume, and let it finish.",
                 isComplete: { event in
                     if event == .pauseToggled { pauseCount += 1 }
                     return event == .readFinished && pauseCount >= 2
                 },
                 success: "Space pauses and resumes any read."),

            Step(instruction: "Lesson six. Press t to hear the time.",
                 isComplete: { event in
                     // Heuristic: spoken time starts with a digit or "oh"
                     // ("14 32", "oh 9 oh 5"). Length guard keeps single-digit
                     // command-echo announcements from matching.
                     guard case .announced(let text) = event, text.count >= 4
                     else { return false }
                     return text.first?.isNumber == true || text.hasPrefix("oh ")
                 },
                 success: "That is the time. Press t twice quickly for time "
                    + "and date."),

            Step(instruction: "Lesson seven. Press colon, that is shift "
                    + "semicolon. The command panel opens, listing everything "
                    + "Marduk can do, and speaks your options when you pause. "
                    + "Have a listen, then press Escape to close it.",
                 isComplete: { $0 == .mode(.command) },
                 success: "That panel is how you find everything else: "
                    + "commands, settings, and their current values."),

            Step(instruction: "Lesson eight. Reading mode. Press lowercase r to start "
                    + "a read, then press open paren, that is shift nine, "
                    + "to hear the sentence again. b steps back a word, "
                    + "braces step paragraphs.",
                 isComplete: { $0 == .readJumped },
                 success: "That is a reading motion. They all work while "
                    + "anything is being read."),

            Step(instruction: "Lesson nine. While the read is going, press "
                    + "z to spell the word being spoken. Press z again to "
                    + "hear it phonetically.",
                 isComplete: { $0 == .spelled },
                 success: "z spells, capital Z spells the whole sentence."),

            Step(instruction: "Lesson ten. Hold Escape for half a second "
                    + "to end the read. A quick tap only pauses it.",
                 isComplete: { $0 == .readFinished },
                 success: "And that is reading mode."),

            Step(instruction: "Lesson eleven. Point the mouse anywhere in "
                    + "your document and press uppercase R. It reads from the "
                    + "pointer to the very end, with every reading motion "
                    + "live. Listen for a moment, then hold Escape to stop.",
                 isComplete: { $0 == .readFinished },
                 success: "Uppercase R works on documents, terminals, "
                    + "P D Fs, and web pages."),
        ]
    }
}
