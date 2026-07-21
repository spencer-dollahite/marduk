import Foundation

/// Spoken help, command reference, and first-run welcome. Short sentences,
/// audio-first phrasing — these are read aloud, never displayed.
enum HelpText {

    static let help = """
        Marduk help. You are usually in NORMAL mode, where letters are commands, \
        not typing. Press i to type. That is INSERT mode. To get back to NORMAL, \
        hold Escape for half a second. In NORMAL mode: lowercase r selects the \
        paragraph under the cursor, like a triple click, and reads it. \
        Uppercase R is Marduk's signature: it reads the whole document from \
        the mouse pointer to the end, like an audiobook, and while anything \
        reads, vim keys move through the text — b back a word, open paren \
        back a sentence, slash to search. It is all vim on purpose: if you \
        know vim, everything carries over. \
        v starts a visual selection. t speaks the time. Escape stops speech. \
        Space pauses and resumes a read. When you press colon, a panel lists \
        everything you can type. Type colon commands for the full list. \
        Type colon tutorial for a guided tour, and colon tip any time to \
        learn one feature you might not know.
        """

    static let commands = """
        Marduk commands. NORMAL mode: i, enter INSERT mode. lowercase r, select \
        the paragraph under the cursor, like a triple click, and read it. \
        Uppercase R, read the whole document to the end, starting from the \
        mouse pointer when it is over text, or from the text cursor \
        otherwise, in apps that share their text, like Notes and Terminal. On \
        a PDF, uppercase R reads the file itself, page aware: control F \
        and control B turn pages, a number then capital G jumps to that \
        page, g g goes to page one, capital G to the last page. \
        v, visual selection. Capital V, select whole lines. t, speak the \
        time. t t, time and date. s, speak what is under the mouse pointer as it moves, in your reading voice. u, check \
        for updates and hear what's new; u again within a minute installs. \
        u u skips the notes and just installs. \
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
        capital Z spells the whole sentence. Lowercase r drops the \
        current read and reads the paragraph under the pointer instead. \
        A tap of Escape pauses and resumes, like Space. Holding Escape stops \
        the read and returns to NORMAL. i drops to INSERT and the read \
        keeps talking — type notes while you listen; hold Escape to hand \
        the keyboard back to the read, or Option Escape to stop the audio \
        without leaving your typing. Other letters buzz. \
        VISUAL mode: h j k l extend the selection. Numbers repeat a motion, \
        like 3 j. Lowercase r reads the selection. Escape cancels. \
        INSERT mode: a quick tap of Escape goes to the app, so vim keeps its \
        Escape. Hold Escape half a second to return to NORMAL. \
        Anywhere: Option Escape speaks the selection, or stops speech. \
        Control Option M turns Marduk on or off. \
        Colon commands: help. commands. tutorial. tip, one random feature \
        tip. config, change a setting. voices, choose the reading voice — \
        arrows preview each voice in its own sound, Return picks it. \
        pronunciation, open the system pronunciation editor — Marduk \
        speaks every entry you add there the way you taught it. \
        typing, open the system typing feedback settings — macOS can \
        speak every key and word as you type, in every app. \
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
        or all. hashes, on or off. identifiers, on or \
        off, reads camel case and snake case names as natural words. \
        rescue, on or off. burst, in milliseconds. \
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
        navigation keys inside a read. dialogs, all, system, or off: \
        all announces app sheets and system prompts, system announces \
        only the central password and permission prompts. follow, on or \
        off: the app's view tracks the read — Preview turns to the page \
        you jump to, and reader articles scroll with the voice. \
        invert, on or off, off by \
        default: flip the display for bright apps — Packet Tracer and \
        Pages are built in, add more in the config file — and restore \
        it when you leave them. p d f dark, \
        one word, auto, on, or off: Preview documents switch to dark view \
        by themselves — auto follows your system theme. auto invert, one word, on or off: measure each app's \
        real brightness with a tiny screenshot and invert only when it is \
        actually bright — needs the Screen Recording permission. dock, on \
        or off: show Marduk in the Dock, the app switcher, and the Force \
        Quit window.
        """

    /// ":tip" — one is picked at random (never the same twice in a row).
    /// Each explains a feature that isn't obvious from the key list alone.
    static let tips = [
        "Press t twice quickly for the time and the date. A single t is just the time.",
        "Space pauses a read mid-sentence and resumes it exactly where it stopped, and so does a quick tap of Escape. Holding Escape abandons the read instead.",
        "In INSERT mode, a quick tap of Escape goes to the app, so vim keeps working. Only holding Escape returns to NORMAL.",
        "In visual mode, numbers repeat motions: v 3 j selects three lines down before you press lowercase r to read them.",
        "Capital V selects whole lines at a time. Lowercase v selects character by character.",
        "If you start typing a word in NORMAL mode by mistake, Marduk notices, switches to INSERT, and types it for you. That is the falling sound.",
        "Words that start with the letter i lose that i if typed in NORMAL mode, because i switches to INSERT instantly. The rescue catches the rest.",
        "The buzzer means you pressed a letter in NORMAL mode that is not a command. Press i first if you meant to type.",
        "Option Escape works everywhere, even in INSERT mode: it speaks the current selection, or stops speech that is already playing.",
        "Change the voice speed any time with colon config rate, for example colon config rate 230. It applies instantly and is saved.",
        "In the colon command line, stop typing for a moment and Marduk speaks your options. Question mark does the same on demand. Arrows move through them, or control N and control P, vim style.",
        "You can shorten colon commands like vim: colon conf ra 230 is colon config rate 230.",
        "Long hex strings are shortened when read: an m d 5 hash becomes m d 5 ending in its last three characters. Turn that off with colon config hashes off.",
        "The s command speaks whatever is under your mouse pointer as it moves, in your own reading voice at your rate and pitch. No setup, and it never interrupts a read. Press s again to stop.",
        "Press u to hear what updates are available, then u again within a minute to install. A quick double u skips the notes entirely and just installs whatever is new — on an up to date system it simply says so.",
        "The lowercase r command selects the whole paragraph under the mouse cursor, like a triple click, then reads the selection.",
        "Media pauses during reads and resumes after, only if it was actually playing. Music apps get volume-ducked instead of paused.",
        "If you can see some of the screen, colon config border on frames it in the mode color: red for NORMAL, green for INSERT, blue for VISUAL. Colon config pointer on adds a dot at the mouse that stays visible while zoomed in.",
        "Colon voices opens a voice picker. Arrow through the list and each voice introduces itself in its own sound; Return keeps the one you are hearing.",
        "With colon config speed keys on, Option up arrow and Option down arrow change the speech rate on the spot, ten words per minute at a time. Hold the key to glide.",
        "In Firefox reader mode, n hands the reading to Firefox's own narrator: your music pauses, Marduk goes quiet, and Firefox reads the page. Press n again or Escape to bring the music back.",
        "On any article in Firefox, 8 does the whole ritual at once: opens reader mode, pauses your music, and starts Firefox narrating. 8 again closes it all back down.",
        "Marduk's reading keys are vim's keys on purpose: b and w for words, parens for sentences, slash to search, dot to repeat. If you already know vim, everything carries over. If you don't, the choices may feel odd for a few days — then the muscle memory kicks in, and it pays off for good.",
        "Vim keys work inside a read: open paren replays the sentence you just missed, b and w step by word, j and k by line, braces by paragraph, and slash searches the text. Wait, what did it just say? Open paren.",
        "Uppercase R turns a Notes page or a Terminal window into an audiobook: point the mouse where you want to start and it reads from there to the end, with every reading motion live. Press it mid-read to switch documents.",
        "Uppercase R reads web pages in Safari and Firefox with every reading motion live. Open the Reader view first — shift command R in Safari, the reader icon in Firefox — and the read is just the title and article, no site clutter.",
        "Was that m or n? During a read, z spells the current word letter by letter, and a second z spells it phonetically: Mike versus November. Capital Z spells the whole sentence.",
        "During a read, f plus any character hops forward to it, like vim: f q jumps to the next q. Capital F hunts backward, and period repeats the hop.",
        "Open a PDF in Preview and press uppercase R: Marduk reads the file itself, starting at the page you are looking at. Control F turns the page, twelve then capital G jumps to page twelve.",
        "With Karabiner installed, Marduk runs its own Karabiner profile while active and hands yours back the moment it stops, even on a crash. Your read button reaches Marduk while it is up, and falls back to macOS Speak Selection whenever it is down. Nothing to switch by hand.",
        "When a password prompt, permission dialog, or sheet appears — even outside your zoomed view — Marduk announces it, with the dialog's title when it has one. Colon config dialogs system limits this to the central OS prompts; off silences it.",
        "Apple's premium voices sound more natural and run entirely on your Mac, free, no account. Download one like Ava in System Settings, Accessibility, Read and Speak Content, System Voice, Manage Voices — then audition it with colon voices. Fair warning: at fast speaking rates, the classic enhanced voices often stay clearer.",
        "Cisco Packet Tracer and Pages stay blinding white even in dark mode. Say colon config invert on and Marduk flips the whole display dark while they are in front, flipping back the moment you leave. It needs the Invert Colors shortcut enabled in Keyboard Settings, under Accessibility.",
        "Working dark? Marduk notices: with your Mac in dark mode, every PDF you open in Preview switches to dark view by itself. Colon config p d f dark off if you want your PDFs paper-white. Colon config auto invert on goes further: it measures each app's real brightness and inverts the display only when the content is actually blinding — a black slide deck in Keynote stays exactly as you styled it.",
        "The view follows the voice: jump a PDF read to page three and Preview turns to page three, read a Reader article and it scrolls along like a teleprompter. Colon config follow off keeps the view still.",
        "Code names read as natural words: read Document From Caret, not one long mumble, and user id count without hearing underscore twice. Colon config identifiers off brings back the raw forms.",
        "Press i during a read and the reading keeps going while you type — notes while you listen. Hold Escape to give the keyboard back to the read; hold it again to stop. Option Escape kills the audio without leaving your typing.",
        "If Marduk ever misbehaves, Control Option Delete is the panic chord: Karabiner itself force-kills Marduk, so it works even when Marduk is stuck — and the launch agent brings back a fresh one in seconds. Control Option M turns Marduk off gently; colon quit or marduk stop in Terminal keep it stopped. Colon config dock on adds Marduk to the Dock and the Force Quit window.",
        "Want every key you type spoken, in every app? macOS already does that: colon typing opens the typing feedback settings. Marduk is happy to be your front desk for the accessibility features Apple already built.",
        "Marduk mispronouncing a name? Colon pronunciation opens the system pronunciation editor. Add the word there, typed or spoken, and Marduk says it your way from the very next read — including entries you scope to a single app.",
    ]

    static let welcome = """
        Welcome to Marduk. You are in NORMAL mode. Letters are commands, not \
        typing. Press i to type. Hold Escape for half a second to come back to \
        NORMAL. Press lowercase r to hear the paragraph under the cursor. Press Escape \
        to stop speech. \
        Marduk's signature is uppercase R: point the mouse at any document \
        and it reads to the end like an audiobook, with vim keys to move \
        through the text as it speaks. \
        The most important key is colon, that is shift semicolon: it opens \
        the command panel, which shows and speaks everything Marduk can do. \
        From there, type h for help, or t u for the guided tour. To try a \
        different voice any time, type colon voices, and type colon tip \
        any time to learn one feature. \
        This message plays only once.
        """
}
