import XCTest
@testable import marduk

/// The DAILY BRIEF (`d`), end to end at the level that can be tested off a
/// Mac: the segment table, the wording of every segment, the two data
/// parsers (open-meteo forecast and geocoding), the moon arithmetic, the
/// AppleScript escaping that guards the one injection boundary, and the
/// `:config` / `:segments` grammar.
///
/// Same shape as `StockLogicTests` and `NewsSessionTests`: everything the
/// user HEARS is pure and lives here; only curl, osascript, and SQLite
/// stay on the hardware side.
final class BriefTests: XCTestCase {

    // MARK: - The segment table

    func testDefaultsAreTheFourPrescribedSegmentsPlusTheNote() {
        XCTAssertEqual(BriefPlan.resolve(nil), BriefPlan.defaultSegments)
        // Moon and horoscope are the opt-in extras (user ruling 2026-08-04)
        XCTAssertFalse(BriefPlan.defaultSegments.contains(.moon))
        XCTAssertFalse(BriefPlan.defaultSegments.contains(.horoscope))
    }

    /// A hand-edited config.json with a typo must still produce a brief —
    /// the unknown id is dropped, not fatal.
    func testResolveDropsUnknownIdsAndDuplicates() {
        XCTAssertEqual(BriefPlan.resolve(["news", "wether", "news", "moon"]),
                       [.news, .moon])
        XCTAssertEqual(BriefPlan.resolve(["WEATHER"]), [.weather])
    }

    /// An EMPTY list is a real choice (everything turned off), never a
    /// silent fallback to the defaults.
    func testEmptyListStaysEmpty() {
        XCTAssertEqual(BriefPlan.resolve([]), [])
    }

    func testToggleInsertsInCanonicalOrderAndRemovesInPlace() {
        let base: [BriefSegment] = [.date, .news]
        // weather sorts between date and news, wherever it is turned on
        XCTAssertEqual(BriefPlan.toggle(base, .weather), [.date, .weather, .news])
        XCTAssertEqual(BriefPlan.toggle(base, .moon), [.date, .news, .moon])
        XCTAssertEqual(BriefPlan.toggle(base, .news), [.date])
        // A user's hand-ordered list keeps its shape apart from the insert
        XCTAssertEqual(BriefPlan.toggle([.news, .date], .moon),
                       [.news, .date, .moon])
    }

    func testPickerRowsSayWhetherEachPartIsIn() {
        let rows = BriefPlan.pickerRows([.date])
        XCTAssertEqual(rows.count, BriefSegment.allCases.count)
        XCTAssertEqual(rows.first?.identifier, "date")
        XCTAssertTrue(rows[0].name.contains("included"))
        XCTAssertTrue(rows[1].name.contains("not included"))
        // Rows are SPOKEN — never the raw case name
        XCTAssertTrue(rows.contains { $0.name.hasPrefix("stock watchlist") })
    }

    /// Every segment's row must round-trip through the picker's identifier,
    /// or Return would land on a segment the daemon can't resolve.
    func testEveryPickerIdentifierResolvesBackToItsSegment() {
        for row in BriefPlan.pickerRows([]) {
            XCTAssertNotNil(BriefSegment(rawValue: row.identifier),
                            "\(row.identifier) is not a segment")
        }
    }

    // MARK: - Composition

    /// Segments are PARAGRAPHS: blank-line separated is exactly what the
    /// reader's `{` and `}` step over, which is what makes a brief
    /// skimmable instead of a wall of speech.
    func testComposeSeparatesSegmentsByABlankLine() {
        XCTAssertEqual(BriefPlan.compose(["One.", "Two."]), "One.\n\nTwo.")
        XCTAssertEqual(BriefPlan.compose(["One.", "", "  ", "Two."]),
                       "One.\n\nTwo.")
        XCTAssertEqual(BriefPlan.compose([]), "")
    }

    func testClampCutsAtAWordAndSaysSo() {
        let short = "A short note."
        XCTAssertEqual(BriefPlan.clamp(body: short), short)
        let long = String(repeating: "word ", count: 100)
        let clamped = BriefPlan.clamp(body: long, limit: 20)
        XCTAssertTrue(clamped.hasSuffix("That note continues."))
        XCTAssertFalse(clamped.contains("word word word word word word"))
    }

    // MARK: - date

    func testSpokenClockMatchesTheTKey() {
        XCTAssertEqual(BriefPlan.spokenClock(hour: 8, minute: 7), "oh 8 oh 7")
        XCTAssertEqual(BriefPlan.spokenClock(hour: 14, minute: 30), "14 30")
        XCTAssertEqual(BriefPlan.spokenClock(hour: 9, minute: 0), "oh 9 hundred")
        XCTAssertEqual(BriefPlan.spokenClock(hour: 0, minute: 5), "oh 0 oh 5")
    }

    func testDateLineIsWeekdayDayMonthThenTheClock() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 2026-08-22 08:07 UTC — a Saturday
        let date = Date(timeIntervalSince1970: 1_787_386_020)
        XCTAssertEqual(BriefPlan.dateLine(date, calendar: calendar),
                       "Saturday, 22 August. The time is oh 8 oh 7.")
    }

    // MARK: - stocks

    private func quote(_ symbol: String, _ price: Double,
                       previous: Double? = nil) -> StockQuote {
        StockQuote(symbol: symbol, name: nil, price: price,
                   previousClose: previous, dayHigh: nil, dayLow: nil,
                   currency: "USD", instrumentType: "EQUITY")
    }

    func testStocksParagraphSpeaksEveryRow() {
        let entries = [StockEntry(symbol: "AAPL", buyBelow: nil, sellAbove: nil),
                       StockEntry(symbol: "MSFT", buyBelow: nil, sellAbove: nil)]
        let text = BriefPlan.stocksParagraph(
            entries: entries,
            quotes: ["AAPL": quote("AAPL", 309.86, previous: 306.2)])
        XCTAssertTrue(text.hasPrefix("Watchlist."))
        XCTAssertTrue(text.contains("309 dollars 86 cents"))
        // A quote that didn't arrive says so rather than vanishing
        XCTAssertTrue(text.contains("MSFT, no quote."))
    }

    func testEmptyWatchlistSaysSoInsteadOfGoingSilent() {
        let text = BriefPlan.stocksParagraph(entries: [], quotes: [:])
        XCTAssertTrue(text.contains("empty"))
    }

    /// The brief reports the STATE of a level, not a transition: a price
    /// that crossed overnight is still news at breakfast, which is exactly
    /// what `StockTriggers` (transition-only, and stateful) would miss.
    func testAlertLineReportsALevelAlreadyCrossed() {
        let below = StockEntry(symbol: "AAPL", buyBelow: 300, sellAbove: nil)
        XCTAssertEqual(BriefPlan.alertLine(below, quote("AAPL", 298)),
                       "AAPL is below your buy level of 300 dollars.")
        XCTAssertNil(BriefPlan.alertLine(below, quote("AAPL", 310)))
        let above = StockEntry(symbol: "AAPL", buyBelow: nil, sellAbove: 320)
        XCTAssertTrue(BriefPlan.alertLine(above, quote("AAPL", 321))!
            .contains("above your sell level"))
    }

    // MARK: - news

    func testNewsParagraphLeadsWithTheCount() {
        let text = BriefPlan.newsParagraph(
            unread: 42, headlines: ["Something happened", "And another"])
        XCTAssertTrue(text.hasPrefix("News. 42 unread."))
        // Headlines rarely end in punctuation; without one the voice runs
        // two of them together
        XCTAssertTrue(text.contains("Something happened. And another."))
    }

    func testNewsParagraphWithNothingUnread() {
        XCTAssertEqual(BriefPlan.newsParagraph(unread: 0, headlines: ["x"]),
                       "News. Nothing unread.")
    }

    func testTitleSentenceLeavesRealPunctuationAlone() {
        XCTAssertEqual(BriefPlan.titleSentence("Is it true?"), "Is it true?")
        XCTAssertEqual(BriefPlan.titleSentence(" Trailing "), "Trailing.")
        XCTAssertEqual(BriefPlan.titleSentence("   "), "")
    }

    // MARK: - note

    func testNoteParagraphNamesTheNoteItMatched() {
        let text = BriefPlan.noteParagraph(title: "Today", body: "Call Sam.")
        XCTAssertEqual(text, "Your note, Today. Call Sam.")
        XCTAssertTrue(BriefPlan.noteParagraph(title: "Today", body: "  ")
            .contains("is empty"))
    }

    /// Every segment with setup names the command that finishes it — a
    /// brief that just skipped the weather would leave no way to find out
    /// why.
    func testUnconfiguredSegmentsPointAtTheirCommand() {
        XCTAssertTrue(BriefPlan.unconfigured(.weather).contains("colon config place"))
        XCTAssertTrue(BriefPlan.unconfigured(.note).contains("colon config note"))
        XCTAssertTrue(BriefPlan.unconfigured(.horoscope).contains("colon config horoscope"))
        // These three have nothing to configure
        XCTAssertEqual(BriefPlan.unconfigured(.date), "")
        XCTAssertEqual(BriefPlan.unconfigured(.stocks), "")
        XCTAssertEqual(BriefPlan.unconfigured(.moon), "")
    }

    // MARK: - Weather: URLs

    /// A place name is user text in a URL QUERY. `.urlQueryAllowed` would
    /// let `&` and `=` through, which is a query the user did not write.
    func testGeocodeQueryIsFullyEncoded() {
        let url = Weather.geocodeURL(query: "salt lake city&count=99")
        XCTAssertTrue(url.contains("name=salt%20lake%20city%26count%3D99"))
        XCTAssertEqual(url.components(separatedBy: "&count=").count, 2)
    }

    func testForecastURLNamesImperialUnitsAndMetricAsksForNothing() {
        let imperial = Weather.forecastURL(latitude: 40.76, longitude: -111.89,
                                           metric: false)
        XCTAssertTrue(imperial.contains("temperature_unit=fahrenheit"))
        XCTAssertTrue(imperial.contains("latitude=40.76"))
        XCTAssertTrue(imperial.contains("longitude=-111.89"))
        let metric = Weather.forecastURL(latitude: 0, longitude: 0, metric: true)
        XCTAssertFalse(metric.contains("temperature_unit"))
    }

    // MARK: - Weather: parsing

    private let forecastJSON = """
        {"current":{"time":"2026-08-22T08:00","temperature_2m":72.4,
         "apparent_temperature":68.1,"weather_code":2},
         "daily":{"time":["2026-08-22"],"temperature_2m_max":[95.3],
         "temperature_2m_min":[67.8],"precipitation_probability_max":[35]}}
        """

    func testParsesTheForecast() throws {
        let report = try XCTUnwrap(
            Weather.parse(forecastJSON: Data(forecastJSON.utf8)))
        XCTAssertEqual(report.temperature, 72.4, accuracy: 0.001)
        XCTAssertEqual(report.code, 2)
        XCTAssertEqual(report.high ?? 0, 95.3, accuracy: 0.001)
        XCTAssertEqual(report.precipitationChance, 35)
    }

    /// A truncated or error response degrades to nil, and the caller says
    /// so out loud — it never invents a temperature.
    func testMalformedForecastIsNil() {
        XCTAssertNil(Weather.parse(forecastJSON: Data("{}".utf8)))
        XCTAssertNil(Weather.parse(forecastJSON: Data("not json".utf8)))
        XCTAssertNil(Weather.parse(
            forecastJSON: Data(#"{"current":{"weather_code":2}}"#.utf8)))
    }

    /// The daily block is optional — a forecast with only `current` still
    /// gives a usable line.
    func testForecastWithoutTheDailyBlock() throws {
        let json = #"{"current":{"temperature_2m":50.0}}"#
        let report = try XCTUnwrap(Weather.parse(forecastJSON: Data(json.utf8)))
        XCTAssertNil(report.high)
        XCTAssertEqual(Weather.spoken(report, place: nil), "Weather. 50 degrees.")
    }

    func testParsesGeocoding() throws {
        let json = """
            {"results":[{"name":"Salt Lake City","latitude":40.76078,
             "longitude":-111.89105,"country":"United States","admin1":"Utah"}]}
            """
        let place = try XCTUnwrap(Weather.parse(geocodingJSON: Data(json.utf8)))
        XCTAssertEqual(place.spokenName, "Salt Lake City, Utah")
        XCTAssertEqual(place.latitude, 40.76078, accuracy: 0.00001)
        // open-meteo omits "results" entirely when nothing matched
        XCTAssertNil(Weather.parse(
            geocodingJSON: Data(#"{"generationtime_ms":0.1}"#.utf8)))
    }

    func testSpokenNameFallsBackToCountryThenBareName() {
        XCTAssertEqual(Weather.Place(name: "Oslo", region: nil,
                                     country: "Norway", latitude: 0,
                                     longitude: 0).spokenName, "Oslo, Norway")
        XCTAssertEqual(Weather.Place(name: "Nowhere", region: "", country: "",
                                     latitude: 0, longitude: 0).spokenName,
                       "Nowhere")
    }

    // MARK: - Weather: wording

    func testSpokenWeatherReadsLikeSpeech() {
        let report = Weather.parse(forecastJSON: Data(forecastJSON.utf8))!
        let text = Weather.spoken(report, place: "Salt Lake City, Utah")
        XCTAssertEqual(text,
            "Weather in Salt Lake City, Utah. 72 degrees, partly cloudy. "
            + "Feels like 68 degrees. A high of 95 degrees and a low of "
            + "68 degrees, with a 35 percent chance of rain.")
    }

    /// A "feels like" a degree off the reading is filler, and a 5 percent
    /// chance of rain is not worth a clause.
    func testSpokenWeatherDropsNoiseClauses() {
        let report = Weather.Report(temperature: 70, apparent: 71, code: 0,
                                    high: 80, low: 60, precipitationChance: 5)
        let text = Weather.spoken(report, place: nil)
        XCTAssertFalse(text.contains("Feels like"))
        XCTAssertFalse(text.contains("chance of rain"))
        XCTAssertTrue(text.hasPrefix("Weather. 70 degrees, clear."))
    }

    /// An unknown WMO code drops the description rather than speaking a
    /// number the user can't act on.
    func testUnknownWeatherCodeSaysNothingAboutTheSky() {
        XCTAssertNil(Weather.description(code: 4321))
        XCTAssertNil(Weather.description(code: nil))
        let report = Weather.Report(temperature: 70, apparent: nil, code: 4321,
                                    high: nil, low: nil,
                                    precipitationChance: nil)
        XCTAssertEqual(Weather.spoken(report, place: nil), "Weather. 70 degrees.")
    }

    func testEveryWeatherCodeWordIsSpeakable() {
        for (code, word) in Weather.codeWords {
            XCTAssertFalse(word.isEmpty, "code \(code) has no word")
            XCTAssertEqual(word, word.lowercased(),
                           "code \(code) reads mid-sentence — keep it lowercase")
        }
    }

    // MARK: - Moon

    func testMoonAtTheReferenceNewMoon() {
        XCTAssertEqual(MoonPhase.cycleFraction(at: MoonPhase.referenceNewMoon),
                       0, accuracy: 0.0001)
        XCTAssertEqual(MoonPhase.spoken(at: MoonPhase.referenceNewMoon),
                       "Moon. New moon.")
    }

    func testMoonHalfwayThroughTheCycleIsFull() {
        let full = MoonPhase.referenceNewMoon
            .addingTimeInterval(MoonPhase.synodicDays / 2 * 86_400)
        XCTAssertEqual(MoonPhase.name(at: full), "full moon")
        XCTAssertEqual(MoonPhase.illumination(at: full), 1, accuracy: 0.0001)
        XCTAssertEqual(MoonPhase.spoken(at: full), "Moon. Full moon, 100 percent lit.")
    }

    /// Dates BEFORE the reference must not produce a negative fraction —
    /// truncatingRemainder keeps the sign, and a negative phase would name
    /// the wrong quarter for every date in the 20th century.
    func testDatesBeforeTheReferenceStillLandInTheCycle() {
        let old = Date(timeIntervalSince1970: 0)   // 1970
        let fraction = MoonPhase.cycleFraction(at: old)
        XCTAssertGreaterThanOrEqual(fraction, 0)
        XCTAssertLessThan(fraction, 1)
        XCTAssertFalse(MoonPhase.spoken(at: old).contains("-"))
    }

    func testMoonNamesAndIlluminationAgreeAcrossAWholeCycle() {
        for step in 0..<60 {
            let date = MoonPhase.referenceNewMoon
                .addingTimeInterval(Double(step) * MoonPhase.synodicDays
                                    / 60 * 86_400)
            let name = MoonPhase.name(at: date)
            let lit = MoonPhase.illumination(at: date)
            XCTAssertTrue((0...1).contains(lit))
            if name == "full moon" { XCTAssertGreaterThan(lit, 0.95) }
            if name == "new moon" { XCTAssertLessThan(lit, 0.05) }
            if name.hasPrefix("waxing") || name.hasPrefix("waning") {
                XCTAssertFalse(name.contains("quarter"))
            }
        }
    }

    // MARK: - Notes (the AppleScript boundary)

    /// A note title is user text interpolated into AppleScript SOURCE.
    /// Backslash must be escaped FIRST — doing it after the quotes would
    /// escape the escapes.
    func testNoteTitleEscapingClosesTheInjectionBoundary() {
        XCTAssertEqual(NotesNote.escape(#"say "hi""#), #"say \"hi\""#)
        XCTAssertEqual(NotesNote.escape(#"back\slash"#), #"back\\slash"#)
        XCTAssertEqual(NotesNote.escape("a\nb"), "a b")
        let script = NotesNote.script(matching: #"" & (do shell script "rm x") & ""#)
        // Nothing the user typed can close the literal
        XCTAssertFalse(script.contains(#""" & (do shell script"#))
        XCTAssertTrue(script.contains(#"\""#))
    }

    func testScriptTriesAnExactNameBeforeASearch() {
        let script = NotesNote.script(matching: "Today")
        XCTAssertTrue(script.contains(#"whose name is "Today""#))
        XCTAssertTrue(script.contains(#"whose name contains "Today""#))
        // Never `activate` — a brief must not pull Notes in front of the
        // user it is reading to
        XCTAssertFalse(script.contains("activate"))
    }

    func testSplitsTheReplyIntoNameAndBody() throws {
        let reply = "Today\n<div>Call Sam.</div>\n"
        let note = try XCTUnwrap(NotesNote.split(reply: reply))
        XCTAssertEqual(note.title, "Today")
        XCTAssertTrue(NotesNote.text(fromHTML: note.html).contains("Call Sam."))
        // An empty body comes back as just the name
        XCTAssertEqual(NotesNote.split(reply: "Today")?.html, "")
        // No match at all
        XCTAssertNil(NotesNote.split(reply: "  \n "))
    }

    func testAutomationDenialIsRecognizedFromStderr() {
        XCTAssertTrue(NotesNote.automationDenied(
            "execution error: Not authorized to send Apple events (-1743)"))
        XCTAssertFalse(NotesNote.automationDenied("execution error: -1728"))
    }

    // MARK: - The `:` surface

    func testBriefIsAnArglessCommandAndSegmentsIsAPicker() {
        XCTAssertEqual(ColonCommand.parse("brief"), .brief)
        XCTAssertEqual(ColonCommand.parse("br"), .brief)
        // Bare :brief RUNS — it must not expand and sit there waiting
        XCTAssertEqual(ColonCommand.autoResolve("brief"), .execute("brief"))
        XCTAssertEqual(ColonCommand.autoResolve("seg"), .expand("segments "))
        XCTAssertTrue(ColonCommand.staysOpenOnReturn("segments "))
        XCTAssertFalse(ColonCommand.staysOpenOnReturn("brief"))
    }

    /// The picker answers under `:config` too, the invertappslist
    /// precedent — one set of plumbing, both spellings.
    func testSegmentsPickerIsReachableUnderConfig() {
        XCTAssertEqual(ColonCommand.strippedPickerBuffer("config segments"),
                       "segments ")
        XCTAssertEqual(ColonCommand.strippedPickerBuffer("set seg news"),
                       "segments news")
        XCTAssertEqual(ColonCommand.autoResolve("config segments"),
                       .expand("segments "))
        // A settings key always wins the shared prefix: "s" could still
        // become smartinvert/speedkeys/stocks, so it is NOT the picker
        XCTAssertNil(ColonCommand.strippedPickerBuffer("config s"))
    }

    func testSegmentPickerRowsFuzzyFilter() {
        let rows = BriefPlan.pickerRows(BriefPlan.defaultSegments)
        // The trailing space is what opens the picker stage — without it
        // the buffer is still "choosing a command"
        let all = CommandCompleter.candidates(for: "segments ", values: [:],
                                              segments: rows)
        XCTAssertEqual(all.count, BriefSegment.allCases.count)
        let moon = CommandCompleter.candidates(for: "segments moon", values: [:],
                                               segments: rows)
        XCTAssertEqual(moon.first?.completion, "segments moon")
    }

    // MARK: - Free-text settings

    /// The whole reason `.text` exists: a note title is a PHRASE, and a
    /// blind user must be able to set it by voice and keyboard rather than
    /// by editing JSON.
    func testTextSettingsTakeTheWholeTailWithSpaces() {
        XCTAssertEqual(ColonCommand.parse("config note today's plan"),
                       .config(key: "note", value: "today's plan"))
        XCTAssertEqual(ColonCommand.parse("config pl salt lake city"),
                       .config(key: "place", value: "salt lake city"))
        XCTAssertEqual(ColonCommand.parse("config horoscope my sign"),
                       .config(key: "horoscope", value: "my sign"))
    }

    /// Grammar words are matched lowercased, but a note title is CONTENT —
    /// it keeps the case the user typed.
    func testTextSettingsKeepTheUsersCapitalization() {
        XCTAssertEqual(ColonCommand.parse("config note Today In Caps"),
                       .config(key: "note", value: "Today In Caps"))
    }

    /// Only text settings may run long — a number or a toggle with extra
    /// tokens is still a typo.
    func testNonTextSettingsStillRejectExtraTokens() {
        XCTAssertEqual(ColonCommand.parse("config rate 200 300"),
                       .unknown("config rate 200 300"))
    }

    /// A phrase can never auto-accept: nothing can know the user has
    /// finished typing one, so Return is always required.
    func testTextSettingsNeverAutoAccept() {
        XCTAssertEqual(ColonCommand.autoResolve("config note today"), .none)
        XCTAssertEqual(ColonCommand.autoResolve("config note today's plan"), .none)
        // …but the KEY still expands and advances
        XCTAssertEqual(ColonCommand.autoResolve("config no"),
                       .expand("config note "))
    }

    func testTextSettingsOfferASpokenPromptInThePalette() {
        let rows = CommandCompleter.candidates(for: "config note ",
                                               values: ["note": "Today"])
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].completion)     // informational row
        XCTAssertTrue(rows[0].display.contains("the title of a note in Notes"))
        XCTAssertTrue(rows[0].display.contains("now Today"))
    }

    func testBriefSettingsAreInTheTableAndCollisionFree() {
        let keys = ColonCommand.settings.map(\.key)
        for key in ["brief", "note", "place", "units", "headlines", "horoscope"] {
            XCTAssertTrue(keys.contains(key), "\(key) is missing")
            XCTAssertEqual(ColonCommand.expand(key, in: keys), key)
        }
        // The segment LIST is a picker command, never a settings key —
        // "brief" would prefix any "briefsegments" spelling, which
        // testNoSettingKeyIsPrefixOfAnother forbids.
        XCTAssertFalse(keys.contains("segments"))
        XCTAssertTrue(ColonCommand.pickerCommands.contains("segments"))
    }

    // MARK: - Drift guards

    /// A segment added to the enum without a gatherer would be offered by
    /// the picker, saved to config, and then silently contribute nothing.
    func testEverySegmentHasAGathererInBriefReader() throws {
        // Reading source is this codebase's established escape hatch for
        // logic behind a system boundary (CrossCoreInvariantTests,
        // HoverDwellTests). #filePath, never the working directory.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MardukTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/App/BriefReader.swift"),
            encoding: .utf8)
        for segment in BriefSegment.allCases {
            XCTAssertTrue(source.contains("case .\(segment.rawValue):"),
                          "BriefSegment.\(segment.rawValue) has no case in "
                          + "BriefReader — it would save to config and then "
                          + "say nothing")
        }
    }

    /// Every segment says its own name in the picker, and no two say the
    /// same thing — the rows are the only way to tell them apart by ear.
    func testSegmentNamesAreDistinctAndSpoken() {
        let names = BriefSegment.allCases.map(\.spokenName)
        XCTAssertEqual(Set(names).count, names.count)
        for name in names {
            XCTAssertFalse(name.contains("_"))
            XCTAssertEqual(name, name.lowercased())
        }
    }
}
