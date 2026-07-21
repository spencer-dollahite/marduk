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
        Capital R, read the whole document from the text cursor to the \
        end, in apps that share their text, like Notes and Terminal. On \
        a PDF, capital R reads the file itself, page aware: control F \
        and control B turn pages, a number then capital G jumps to that \
        page, g g goes to page one, capital G to the last page. \
        v, visual selection. Capital V, select whole lines. t, speak the \
        time. t t, time and date. s, toggle speak under pointer. u, check \
        for updates and hear what's new. u u, install the update. \
        n, in Firefox reader mode: pause your media and start Firefox's \
        own narration. n again, or Escape, brings the media back. n works \
        from INSERT mode too when the reader page has focus. \
        8, in Firefox: open reader mode and start narrating, one key. \
        8 again stops narrating and closes the reader. \
        Escape, stop speech. Space, pause or resume a read. \
        With read motions on, a read takes the whole keyboard, from any \
        mode: b and w step back and forward a word, h and l do the same. \
        Parentheses step a sentence. j and k step lines, zero restarts \
        the current line, and braces step paragraphs — blocks separated \
        by blank lines. Numbers repeat, like 3 then open paren. g g \
        restarts from the top, capital G jumps to the last paragraph. Slash searches forward, question mark searches \
        back: the read pauses while you type, Return jumps to the match, \
        Escape resumes where you were. Period repeats the last motion or \
        search, so period after a search hops match to match. f then any \
        character jumps forward to it, capital F searches backward, and \
        period repeats the hop. z spells \
        the current word letter by letter, z again spells it phonetically, \
        capital Z spells the whole sentence. r drops the \
        current read and reads the paragraph under the pointer instead. \
        A tap of Escape pauses and resumes, like Space. Only two keys leave a \
        read: holding Escape stops it and returns to NORMAL, i stops it \
        and drops to INSERT for typing. Other letters buzz. \
        VISUAL mode: h j k l extend the selection. Numbers repeat a motion, \
        like 3 j. r reads the selection. Escape cancels. \
        INSERT mode: hold Escape half a second to return to NORMAL. \
        Anywhere: Option Escape speaks the selection, or stops speech. \
        Control Option M turns Marduk on or off. \
        Colon commands: help. commands. tutorial. tip, one random feature \
        tip. config, change a setting. voices, choose the reading voice — \
        arrows preview each voice in its own sound, Return picks it. \
        quit. restart. update, install \
        updates now. uninstall, remove the launch agent. log, open the log \
        file. log copy, copy recent log lines to the clipboard. \
        feedback, open GitHub issues. bug, report a bug. security, report \
        a security issue privately by email. \
        Commands complete themselves: \
        type until yours is the only match, then just stop. \
        Slash starts a fuzzy search over every command and setting; \
        Return accepts the highlighted match. \
        Config takes a setting and a value, like colon config rate 200. \
        Settings: rate, 50 to 360 words per minute. pitch, 50 to 200 \
        percent, for the reading voice. level, none, some, most, \
        or all. hashes, on or off. rescue, on or off. burst, in milliseconds. \
        escape hold, one word, in milliseconds. echo, on or off, speaks keys \
        as you type. command echo, one word, on or off. palette, on or off. \
        auto update, one word, on or off. check hours, one word, hours \
        between update checks, zero for never. position, center or pointer, \
        where the panel opens. Pointer keeps it inside a zoomed view. \
        border, on or off, a screen edge color showing the current mode: \
        red NORMAL, green INSERT, blue VISUAL, purple while reading. pointer, on or off, the same \
        color as a dot following the mouse. thickness, border width in points. \
        speed keys, one word, on or off: Option up and down arrows change \
        the speech rate. toggle sound, one word, speech or earcon, what \
        Control Option M plays. read motions, one word, on or off: vim \
        navigation keys inside a read.
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
        "In the colon command line, stop typing for a moment and Marduk speaks your options. Question mark does the same on demand. Arrows move through them, or control N and control P, vim style.",
        "You can shorten colon commands like vim: colon conf ra 230 is colon config rate 230.",
        "Long hex strings are shortened when read: an m d 5 hash becomes m d 5 ending in its last three characters. Turn that off with colon config hashes off.",
        "The s command speaks whatever is under your mouse pointer. It needs a one-time shortcut assignment in System Settings, Keyboard, Accessibility.",
        "Press u in NORMAL mode to hear what updates are available. Press u twice, or u again within a minute, to install them.",
        "The r command selects the whole paragraph under the mouse cursor, like a triple click, then reads the selection.",
        "Media pauses during reads and resumes after, only if it was actually playing. Music apps get volume-ducked instead of paused.",
        "If you can see some of the screen, colon config border on frames it in the mode color: red for NORMAL, green for INSERT, blue for VISUAL. Colon config pointer on adds a dot at the mouse that stays visible while zoomed in.",
        "Colon voices opens a voice picker. Arrow through the list and each voice introduces itself in its own sound; Return keeps the one you are hearing.",
        "With colon config speed keys on, Option up arrow and Option down arrow change the speech rate on the spot, ten words per minute at a time. Hold the key to glide.",
        "In Firefox reader mode, n hands the reading to Firefox's own narrator: your music pauses, Marduk goes quiet, and Firefox reads the page. Press n again or Escape to bring the music back.",
        "On any article in Firefox, 8 does the whole ritual at once: opens reader mode, pauses your music, and starts Firefox narrating. 8 again closes it all back down.",
        "Vim keys work inside a read: open paren replays the sentence you just missed, b and w step by word, j and k by line, braces by paragraph, and slash searches the text. Wait, what did it just say? Open paren.",
        "Capital R turns a Notes page or a Terminal window into an audiobook: it reads from your text cursor to the end, with every reading motion live. Press it mid-read to switch documents.",
        "Was that m or n? During a read, z spells the current word letter by letter, and a second z spells it phonetically: Mike versus November. Capital Z spells the whole sentence.",
        "During a read, f plus any character hops forward to it, like vim: f q jumps to the next q. Capital F hunts backward, and period repeats the hop.",
        "Open a PDF in Preview and press capital R: Marduk reads the file itself, starting at the page you are looking at. Control F turns the page, twelve then capital G jumps to page twelve.",
        "Apple's premium voices are a big upgrade and run entirely on your Mac, free, no account. Download one like Ava in System Settings, Accessibility, Read and Speak Content, System Voice, Manage Voices — then pick it with colon voices. Marduk will even prefer it automatically.",
    ]

    static let welcome = """
        Welcome to Marduk. You are in NORMAL mode. Letters are commands, not \
        typing. Press i to type. Hold Escape for half a second to come back to \
        NORMAL. Press r to hear the paragraph under the cursor. Press Escape \
        to stop speech. \
        The most important key is colon, that is shift semicolon: it opens \
        the command panel, which shows and speaks everything Marduk can do. \
        From there, type h for help, or t u for the guided tour. \
        This message plays only once.
        """
}
