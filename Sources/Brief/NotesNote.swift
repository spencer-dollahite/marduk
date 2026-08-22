import Foundation

/// The daily brief's `note` segment: one note out of Notes.app, found by
/// TITLE. Notes has no readable store on disk (the database is a private
/// CoreData/protobuf format that Apple changes freely), so the only
/// supported way in is its AppleScript dictionary — the same
/// Process + osascript route the ducker and the display inverter use, and
/// it needs the Automation grant for Notes the first time.
///
/// The title is a SEARCH, not an exact key (the user asked for it that
/// way): an exact name wins when one exists, and otherwise the first note
/// whose name contains the text. AppleScript's default text comparison
/// ignores case, so "groceries" finds "Groceries".
///
/// Pure here — script text, escaping, and the reply split — so the
/// injection-sensitive part is unit-tested. The Process call is in
/// `BriefReader`.
enum NotesNote {

    /// A title is user text INTERPOLATED INTO APPLESCRIPT SOURCE, so it is
    /// escaped like any other injection boundary in this codebase (the
    /// news reader's `raiseScript` rule). Backslash first — escaping it
    /// after the quotes would double-escape the escapes — and newlines are
    /// dropped outright, since a literal cannot hold one and a note name
    /// cannot contain one either.
    static func escape(_ title: String) -> String {
        title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
    }

    /// The lookup. `tell application "Notes"` starts Notes if it isn't
    /// running, deliberately WITHOUT `activate` — the brief must never
    /// pull a window in front of the user it is reading to.
    ///
    /// The reply is the note's own name, a newline, then its body as HTML.
    /// A name cannot contain a newline, so the first line is an
    /// unambiguous delimiter without inventing a marker string that a note
    /// could itself contain.
    static func script(matching title: String) -> String {
        let quoted = escape(title)
        return """
            tell application "Notes"
                set matches to (every note whose name is "\(quoted)")
                if (count of matches) is 0 then
                    set matches to (every note whose name contains "\(quoted)")
                end if
                if (count of matches) is 0 then return ""
                set theNote to item 1 of matches
                return (name of theNote) & linefeed & (body of theNote)
            end tell
            """
    }

    /// Reply → (name, HTML body). Nil = no note matched.
    static func split(reply: String) -> (title: String, html: String)? {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let newline = trimmed.firstIndex(of: "\n") else {
            // A note with an empty body comes back as just its name
            return (trimmed, "")
        }
        return (String(trimmed[trimmed.startIndex..<newline]),
                String(trimmed[trimmed.index(after: newline)...]))
    }

    /// Notes' `body` is HTML. The news reader already owns a tag stripper
    /// that turns block elements into blank-line paragraphs — which is
    /// exactly what the brief wants, because paragraphs are what `{` and
    /// `}` step over during the read.
    static func text(fromHTML html: String) -> String {
        NewsHTML.text(from: html)
    }

    /// osascript's stderr for a refused Automation grant. Speaking the
    /// real reason beats "no note found" — the user can fix a permission,
    /// but not a lie.
    static func automationDenied(_ stderr: String) -> Bool {
        stderr.contains("-1743")
    }
}
