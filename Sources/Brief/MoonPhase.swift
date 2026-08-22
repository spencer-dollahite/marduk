import Foundation

/// The daily brief's moon segment. PURE ASTRONOMY, computed locally —
/// no network, no key, no permission. That is the whole reason it is
/// here: everything else in the brief depends on a service being up,
/// and this one is arithmetic.
///
/// The model is the mean synodic month counted from a known new moon.
/// It ignores the moon's real (elliptical) motion, so the phase age can
/// be off by up to about half a day near the quarters — which moves the
/// spoken illumination by a few percent and, rarely, names a boundary
/// phase a day early or late. That is the right trade for a spoken
/// one-liner; anyone wanting an ephemeris has better tools than a
/// screen reader.
enum MoonPhase {

    /// 2000-01-06 18:14 UTC — the new moon everyone counts from.
    static let referenceNewMoon = Date(timeIntervalSince1970: 947_182_440)

    /// Mean synodic month, in days.
    static let synodicDays = 29.530588853

    /// Where in the cycle we are, 0 (new) to 1 (the next new).
    static func cycleFraction(at date: Date) -> Double {
        let days = date.timeIntervalSince(referenceNewMoon) / 86_400
        let fraction = (days / synodicDays).truncatingRemainder(dividingBy: 1)
        return fraction < 0 ? fraction + 1 : fraction   // dates before 2000
    }

    /// Lit fraction of the disc, 0 to 1. Exact for a circular orbit and a
    /// distant sun, which is what the mean-synodic model already assumes.
    static func illumination(at date: Date) -> Double {
        (1 - cos(2 * .pi * cycleFraction(at: date))) / 2
    }

    /// Phase boundaries as sixteenths of the cycle — the conventional
    /// split, where "first quarter" names a window around the instant
    /// rather than the instant itself (nobody says "waxing crescent" on
    /// the evening of the quarter).
    static func name(at date: Date) -> String {
        let f = cycleFraction(at: date)
        switch f {
        case ..<0.0333: return "new moon"
        case ..<0.2167: return "waxing crescent"
        case ..<0.2833: return "first quarter"
        case ..<0.4667: return "waxing gibbous"
        case ..<0.5333: return "full moon"
        case ..<0.7167: return "waning gibbous"
        case ..<0.7833: return "last quarter"
        case ..<0.9667: return "waning crescent"
        default: return "new moon"
        }
    }

    /// "Moon. Waxing gibbous, 82 percent lit." A new moon skips the
    /// percentage — "0 percent lit" is a fact nobody needs said.
    static func spoken(at date: Date) -> String {
        let phase = name(at: date)
        let percent = Int((illumination(at: date) * 100).rounded())
        guard phase != "new moon" else { return "Moon. New moon." }
        return "Moon. \(phase.prefix(1).uppercased())\(phase.dropFirst()), "
            + "\(percent) percent lit."
    }
}
