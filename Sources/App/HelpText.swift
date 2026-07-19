import Foundation

/// Spoken help, command reference, and first-run welcome. Short sentences,
/// audio-first phrasing — these are read aloud, never displayed.
enum HelpText {

    static let help = """
        Marduk help. You are usually in NORMAL mode, where letters are commands, \
        not typing. Press i to type. That is INSERT mode. To get back to NORMAL, \
        hold Escape for half a second. In NORMAL mode: r selects the paragraph \
        under the cursor, like a triple click, and reads it. \
        v starts a visual selection. t speaks the time. Escape stops speech. \
        Space pauses and resumes a read. When you press colon, a panel lists \
        everything you can type. Type colon commands for the full list. \
        Type colon tutorial for a guided tour.
        """

    static let commands = """
        Marduk commands. NORMAL mode: i, enter INSERT mode. r, select the \
        paragraph under the cursor, like a triple click, and read it. \
        v, visual selection. Capital V, select whole lines. t, speak the \
        time. t t, time and date. s, toggle speak under pointer. u, check \
        for updates and hear what's new. u u, install the update. \
        Escape, stop speech. Space, pause or resume a read. \
        VISUAL mode: h j k l extend the selection. Numbers repeat a motion, \
        like 3 j. r reads the selection. Escape cancels. \
        INSERT mode: hold Escape half a second to return to NORMAL. \
        Anywhere: Option Escape speaks the selection, or stops speech. \
        Control Option M turns Marduk on or off. \
        Colon commands: help. commands. tutorial. tip, one random feature \
        tip. config, change a setting. quit. restart. update, install \
        updates now. uninstall, remove the launch agent. log, open the log \
        file. log copy, copy recent log lines to the clipboard. \
        feedback, open GitHub issues. bug, report a bug. \
        Commands complete themselves: \
        type until yours is the only match, then just stop. \
        Slash starts a fuzzy search over every command and setting; \
        Return accepts the highlighted match. \
        Config takes a setting and a value, like colon config rate 200. \
        Settings: rate, 50 to 360 words per minute. level, none, some, most, \
        or all. hashes, on or off. rescue, on or off. burst, in milliseconds. \
        escape hold, one word, in milliseconds. echo, on or off, speaks keys \
        as you type. command echo, one word, on or off. palette, on or off. \
        auto update, one word, on or off. check hours, one word, hours \
        between update checks, zero for never.
        """

    /// ":tip" — one is picked at random (never the same twice in a row).
    /// Each explains a feature that isn't obvious from the key list alone.
    static let tips = [
        "Press t twice quickly for the time and the date. A single t is just the time.",
        "Space pauses a read mid-sentence and resumes it exactly where it stopped. Escape abandons it instead.",
        "In INSERT mode, a quick tap of Escape goes to the app, so vim keeps working. Only holding Escape returns to NORMAL.",
        "In visual mode, numbers repeat motions: v 3 j selects three lines down before you press r to read them.",
        "Capital V selects whole lines at a time. Lowercase v selects character by character.",
        "If you start typing a word in NORMAL mode by mistake, Marduk notices, switches to INSERT, and types it for you. That is the falling sound.",
        "Words that start with the letter i lose that i if typed in NORMAL mode, because i switches to INSERT instantly. The rescue catches the rest.",
        "The buzzer means you pressed a letter in NORMAL mode that is not a command. Press i first if you meant to type.",
        "Option Escape works everywhere, even in INSERT mode: it speaks the current selection, or stops speech that is already playing.",
        "Change the voice speed any time with colon config rate, for example colon config rate 230. It applies instantly and is saved.",
        "In the colon command line, stop typing for a moment and Marduk speaks your options. Question mark does the same on demand.",
        "You can shorten colon commands like vim: colon conf ra 230 is colon config rate 230.",
        "Long hex strings are shortened when read: an m d 5 hash becomes m d 5 ending in its last three characters. Turn that off with colon config hashes off.",
        "The s command speaks whatever is under your mouse pointer. It needs a one-time shortcut assignment in System Settings, Keyboard, Accessibility.",
        "Press u in NORMAL mode to hear what updates are available. Press u twice, or u again within a minute, to install them.",
        "The r command selects the whole paragraph under the mouse cursor, like a triple click, then reads the selection.",
        "Media pauses during reads and resumes after, only if it was actually playing. Music apps get volume-ducked instead of paused.",
    ]

    static let welcome = """
        Welcome to Marduk. You are in NORMAL mode. Letters are commands, not \
        typing. Press i to type. Hold Escape for half a second to come back to \
        NORMAL. Press r to hear the paragraph under the cursor. Press Escape \
        to stop speech. \
        For spoken help, press shift semicolon for colon, then type help, then \
        Return. For a guided tour, type colon tutorial. This message plays \
        only once.
        """
}
