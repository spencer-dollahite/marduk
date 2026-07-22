import Foundation

/// Consent and decision logic for FOCUSING announced dialogs. Focusing a
/// dialog is input-invasive (keystrokes land in it), so it never happens
/// without consent: the first announced dialog carries a spoken question
/// and a one-key answer chooses. macOS has no "auto-focus dialogs"
/// preference to inherit consent from; the nearest kin — Zoom's "Follow
/// keyboard focus" (Settings > Accessibility > Zoom > Advanced) — pans
/// zoom to whatever TAKES focus, and dialogs often don't take it, which
/// is exactly the gap Marduk's focus action fills. That setting is read
/// as a SIGNAL for wording and a pointer, never as a gate.
///
/// Pure decision table (unit-tested); the daemon supplies state, the
/// keyboard monitor supplies the answer key.
enum DialogFocus {
    enum Setting: String {
        case ask, always, off
    }

    /// The question tail appended to a dialog announcement — nil when no
    /// question should ride it (always/off). The full pitch speaks once
    /// ever (the `explained` marker); after that, undecided users get the
    /// terse form so every dialog isn't a lecture. `inInsert`: announced
    /// into INSERT, the keys would type into the app (often the dialog's
    /// own password field — INSERT never inspects letters, by design), so
    /// the wording routes through the held Escape first (field incident
    /// 2026-07-22: o/n landed in a username box).
    static func promptTail(setting: Setting, explained: Bool,
                           zoomFollowsFocus: Bool?, inInsert: Bool) -> String? {
        guard setting == .ask else { return nil }
        if explained {
            return inInsert ? "Focus? Hold Escape, then a, o, n, or s."
                            : "Focus? a, o, n, or s."
        }
        var pitch = "Marduk can focus these dialogs for you. "
            + (inInsert ? "Hold Escape, then press a" : "Press a")
            + " to always focus, o to focus just this one, n for not now, "
            + "or s to stop asking."
        if zoomFollowsFocus == true {
            pitch += " Your zoom follows keyboard focus, so a focused "
                + "dialog zooms into view."
        }
        return pitch
    }

    struct Resolution: Equatable {
        let newSetting: Setting?   // nil = stay undecided (keep asking)
        let focusNow: Bool
        let ack: String
    }

    /// a/o/n/s → what happens. Nil for any other character (defensive —
    /// the monitor only forwards the four answer keys).
    static func resolve(answer: Character) -> Resolution? {
        switch answer {
        case "a": return Resolution(newSetting: .always, focusNow: true,
                                    ack: "Always.")
        case "o": return Resolution(newSetting: nil, focusNow: true,
                                    ack: "Okay.")
        case "n": return Resolution(newSetting: nil, focusNow: false,
                                    ack: "Not now.")
        case "s": return Resolution(newSetting: .off, focusNow: false,
                                    ack: "Okay, never. Colon config dialog focus to change.")
        default:  return nil
        }
    }

    /// One-time pointer to the system option, spoken right after the
    /// user's first focus (the moment it's relevant): a focused dialog
    /// only zooms into view if zoom follows focus. Non-nil ONLY when the
    /// setting is known off/unset — a user who set it deliberately hears
    /// the synergy line in the pitch instead.
    static func zoomHint(zoomFollowsFocus: Bool?) -> String? {
        guard zoomFollowsFocus != true else { return nil }
        return "Tip: macOS can pan your zoom to whatever has focus. "
            + "Settings, Accessibility, Zoom, Advanced — follow keyboard focus."
    }

    /// Zoom's Follow keyboard focus state from com.apple.universalaccess
    /// (the domain Marduk already reads for whiteOnBlack and the
    /// pronunciation store). CANDIDATE KEYS as data — the classic Bool
    /// first; macOS 26's actual key is hardware-confirmed and this list
    /// adjusted if it differs. Missing/unreadable → nil (fail-soft; the
    /// wording treats unknown as "not known on"). Read fresh per question
    /// so Settings edits apply at the next dialog.
    static let zoomFollowKeys = ["closeViewZoomFollowsFocus"]

    static func zoomFollowsFocus() -> Bool? {
        let domain = "com.apple.universalaccess" as CFString
        CFPreferencesAppSynchronize(domain)
        for key in zoomFollowKeys {
            if let value = CFPreferencesCopyAppValue(key as CFString, domain) {
                if let number = value as? NSNumber { return number.boolValue }
            }
        }
        return nil
    }
}
