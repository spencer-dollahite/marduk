import Foundation

/// Font-prominence heading detection for rich text areas — the rung that
/// gives Notes and TextEdit heading jumps (and any other app that answers
/// the AX attributed-string fetch; apps that don't simply yield zero
/// headings). Platform-generic by construction: it never names an app.
/// Size-only on purpose — bold body text must not be misread as a
/// heading. Pure and unit-testable; all ranges are UTF-16 offsets into
/// the fetched text.
enum HeadingDetector {
    struct FontRun: Equatable {
        let range: NSRange
        let pointSize: Double
    }

    /// Body size = the length-weighted modal point size (most of a
    /// document is body; ties break toward the smaller size so the
    /// larger becomes a heading). Runs LARGER than body are heading
    /// candidates; distinct candidate sizes rank descending → levels
    /// 1..6. Adjacent same-size candidate runs merge — a styled word
    /// inside one heading line arrives as separate runs — and each
    /// heading's offset is its first run's start. Degenerate inputs
    /// (empty, uniform size, body already the largest) yield [].
    static func headings(runs: [FontRun]) -> [(offset: Int, level: Int)] {
        guard !runs.isEmpty else { return [] }
        var weights: [Double: Int] = [:]
        for run in runs { weights[run.pointSize, default: 0] += run.range.length }
        guard let body = weights.max(by: {
            ($0.value, $1.key) < ($1.value, $0.key)
        })?.key else { return [] }
        // Half-point slack so float twins of the body size never rank.
        // `isFinite` guards AX handing back nan/inf: a nan key can never be
        // looked up again (nan != nan), so such a run would contribute
        // weight under a key nothing can rank — a heading that exists in
        // the table and is silently unreachable.
        let candidateSizes = Set(runs.map(\.pointSize)
            .filter { $0.isFinite && $0 > body + 0.5 })
        guard !candidateSizes.isEmpty else { return [] }
        // Sizes beyond the sixth CLAMP to level 6 rather than dropping out.
        // They used to fall through `guard let rank … else { continue }`,
        // so in a document with seven or more distinct heading sizes the
        // SMALLEST — which are also the most numerous — vanished from `]]`
        // navigation entirely, with no log line.
        let ranked = candidateSizes.sorted(by: >)
        let level = Dictionary(uniqueKeysWithValues:
            ranked.enumerated().map { ($0.element, min($0.offset + 1, 6)) })

        var result: [(offset: Int, level: Int)] = []
        var previous: FontRun?
        for run in runs.sorted(by: { $0.range.location < $1.range.location }) {
            defer { previous = run }
            guard let rank = level[run.pointSize] else { continue }
            if let prev = previous, prev.pointSize == run.pointSize,
               prev.range.location + prev.range.length >= run.range.location,
               result.last?.level == rank {
                continue  // continuation of the same heading
            }
            result.append((offset: run.range.location, level: rank))
        }
        return result
    }
}
