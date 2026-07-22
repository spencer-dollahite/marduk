import Foundation

/// The `dd` release gesture's decisions, pure.
///
/// A release reaches strangers' machines, so this gesture is the most
/// consequential thing on the keyboard: it tags, pushes, notarizes, and
/// publishes. Every guard around it — source-install only, one at a time,
/// ask before acting — lived inside a method that spawns a `Process`, so
/// none of it could be tested.
///
/// Same shape as `InversionPolicy` and `BurstPolicy`: the judgment is a
/// function, the spawning stays in the daemon.
enum ReleaseFlow {

    /// What a `dd` press means right now.
    enum Gesture: Equatable {
        /// Not a source checkout — releases are impossible here. The
        /// keyboard gesture is already source-gated (`releaseAvailable`),
        /// so this is defense in depth for the socket path.
        case refuseNotSource
        /// A release is already running: `dd` is the STATUS POKE, quiet by
        /// default and answering with the current stage on demand.
        case statusPoke(stage: String)
        /// Go work out the next version and ask.
        case askToCut
    }

    static func onCutReleaseKey(hasProjectDir: Bool, inFlight: Bool,
                                stage: String) -> Gesture {
        guard hasProjectDir else { return .refuseNotSource }
        guard !inFlight else { return .statusPoke(stage: stage) }
        return .askToCut
    }

    /// The armed one-key answer. ONLY `y` releases — anything else
    /// declines, because the whole point of the question is that a
    /// release never happens by accident. (Escape and unarmed keys never
    /// reach here; the question simply evaporates.)
    enum Answer: Equatable { case start, decline }

    static func onAnswer(_ key: Character) -> Answer {
        key == "y" ? .start : .decline
    }

    /// How the spawned script ended.
    enum Outcome: Equatable {
        case live(version: String)
        case timedOut(stage: String)
        case failed(stage: String)
    }

    /// Success is exit 0 and nothing else. A timeout is reported as a
    /// timeout — not a failure — because the two need different responses
    /// (a wedged notarization or a locked keychain is still in flight
    /// upstream; a real failure is not).
    static func outcome(status: Int32, timedOut: Bool, version: String,
                        stage: String) -> Outcome {
        if status == 0 { return .live(version: version) }
        return timedOut ? .timedOut(stage: stage) : .failed(stage: stage)
    }

    /// The spoken line for an outcome. Stages are tracked but never
    /// announced mid-run (the run is usable time — a stage announce would
    /// stop an active read), so these three lines plus the start are the
    /// entire voice surface of a release.
    static func spoken(_ outcome: Outcome) -> String {
        switch outcome {
        case .live(let version):
            return "Release \(version) is live."
        case .timedOut(let stage):
            return "Release timed out during \(stage). Check the log."
        case .failed(let stage):
            return "Release failed during \(stage). Check the log."
        }
    }
}
