import XCTest
@testable import marduk

/// STOCKS mode's pure core: quote parsing (Yahoo v8 chart shape), spoken
/// formatting, alert-crossing transitions, watchlist persistence rules,
/// the session cursor, and the ":stock" grammar.
final class StockLogicTests: XCTestCase {

    // MARK: - Quote parsing

    private let chartFixture = """
        {"chart":{"result":[{"meta":{"currency":"USD","symbol":"AAPL",
        "shortName":"Apple Inc.","instrumentType":"EQUITY",
        "regularMarketPrice":309.86,
        "previousClose":306.2,"chartPreviousClose":306.2,
        "regularMarketDayHigh":311.0,"regularMarketDayLow":305.1}}],
        "error":null}}
        """.data(using: .utf8)!

    func testParsesYahooChartMeta() {
        guard let quote = StockQuote.parse(chartJSON: chartFixture) else {
            return XCTFail("fixture failed to parse")
        }
        XCTAssertEqual(quote.symbol, "AAPL")
        XCTAssertEqual(quote.name, "Apple Inc.")
        XCTAssertEqual(quote.price, 309.86, accuracy: 0.001)
        XCTAssertEqual(quote.previousClose ?? 0, 306.2, accuracy: 0.001)
        XCTAssertEqual(quote.changePercent ?? 0, 1.195, accuracy: 0.01)
        XCTAssertEqual(quote.currency, "USD")
        XCTAssertEqual(quote.instrumentType, "EQUITY")
    }

    func testGarbageAndErrorPayloadsParseToNil() {
        XCTAssertNil(StockQuote.parse(chartJSON: Data("not json".utf8)))
        XCTAssertNil(StockQuote.parse(chartJSON: Data("{}".utf8)))
        let noPrice = """
            {"chart":{"result":[{"meta":{"symbol":"AAPL"}}]}}
            """.data(using: .utf8)!
        XCTAssertNil(StockQuote.parse(chartJSON: noPrice))
    }

    // MARK: - Spoken formatting

    func testSpokenPriceAndChange() {
        XCTAssertEqual(StockQuote.spokenPrice(309.86), "309.86")
        XCTAssertEqual(StockQuote.spokenPrice(180.0), "180")
        XCTAssertEqual(StockQuote.spokenChange(1.23), "up 1.2 percent")
        XCTAssertEqual(StockQuote.spokenChange(-0.84), "down 0.8 percent")
        XCTAssertEqual(StockQuote.spokenChange(0.01), "flat")
        XCTAssertEqual(StockQuote.spokenChange(nil), "")
    }

    func testRowLineSpeaksDollars() {
        let quote = StockQuote(symbol: "AAPL", name: "Apple Inc.",
                               price: 309.86, previousClose: 306.2,
                               dayHigh: 311, dayLow: 305.1)
        XCTAssertEqual(quote.line,
                       "AAPL, 309 dollars 86 cents, up 1.2 percent")
        XCTAssertTrue(quote.detail.hasPrefix("Apple Inc.. 309 dollars 86 cents"))
        XCTAssertTrue(quote.detail.contains(
            "day range 305 dollars 10 cents to 311 dollars"))
    }

    func testSpokenAmountsByCurrencyAndInstrument() {
        // USD is the default; whole prices drop the cents clause
        XCTAssertEqual(StockQuote.spokenAmount(309.86, currency: "USD",
                                               instrumentType: "EQUITY"),
                       "309 dollars 86 cents")
        XCTAssertEqual(StockQuote.spokenAmount(180, currency: nil,
                                               instrumentType: nil),
                       "180 dollars")
        // Rounding never speaks "100 cents"
        XCTAssertEqual(StockQuote.spokenAmount(179.999, currency: "USD",
                                               instrumentType: nil),
                       "180 dollars")
        // Indexes are points, never money
        XCTAssertEqual(StockQuote.spokenAmount(6300.12, currency: "USD",
                                               instrumentType: "INDEX"),
                       "6300.12")
        // Other currencies speak their own words; yen has no minor unit
        XCTAssertEqual(StockQuote.spokenAmount(10.05, currency: "GBP",
                                               instrumentType: "EQUITY"),
                       "10 pounds 5 pence")
        XCTAssertEqual(StockQuote.spokenAmount(15000, currency: "JPY",
                                               instrumentType: "EQUITY"),
                       "15000 yen")
        // Unknown codes ride along rather than lying about dollars
        XCTAssertEqual(StockQuote.spokenAmount(24.5, currency: "CHF",
                                               instrumentType: "EQUITY"),
                       "24.50 CHF")
    }

    // MARK: - Trigger crossings

    func testTriggersFireOnTransitionOnly() {
        let entry = StockEntry(symbol: "AAPL", buyBelow: 180, sellAbove: 220)
        // Above both levels — sell fires, buy doesn't
        var result = StockTriggers.check(entry: entry, price: 225,
                                         wasBeyond: .init())
        XCTAssertEqual(result.events.map(\.side), [.sell])
        // Same price next refresh: already beyond — silence
        result = StockTriggers.check(entry: entry, price: 226,
                                     wasBeyond: result.beyond)
        XCTAssertTrue(result.events.isEmpty)
        // Falls back between the levels, then through the buy level
        result = StockTriggers.check(entry: entry, price: 200,
                                     wasBeyond: result.beyond)
        XCTAssertTrue(result.events.isEmpty)
        result = StockTriggers.check(entry: entry, price: 179.5,
                                     wasBeyond: result.beyond)
        XCTAssertEqual(result.events.map(\.side), [.buy])
        XCTAssertEqual(result.events.first?.spoken,
                       "AAPL is below your buy level 180 dollars: "
                       + "179 dollars 50 cents.")
    }

    func testNoLevelsMeansNoEvents() {
        let entry = StockEntry(symbol: "AAPL")
        let result = StockTriggers.check(entry: entry, price: 1,
                                         wasBeyond: .init())
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.beyond, StockTriggers.Beyond())
    }

    // MARK: - Watchlist

    func testWatchlistAddRemoveTrigger() {
        var list = StockWatchlist()
        XCTAssertTrue(list.add("AAPL"))
        XCTAssertFalse(list.add("AAPL"))          // duplicate
        XCTAssertTrue(list.setTrigger("AAPL", side: .buy, level: 180))
        XCTAssertEqual(list.entry("AAPL")?.buyBelow ?? 0, 180, accuracy: 0.001)
        XCTAssertTrue(list.setTrigger("AAPL", side: .buy, level: nil))
        XCTAssertNil(list.entry("AAPL")?.buyBelow)
        XCTAssertFalse(list.setTrigger("MSFT", side: .sell, level: 100))
        XCTAssertTrue(list.remove("AAPL"))
        XCTAssertFalse(list.remove("AAPL"))
    }

    func testNormalizeRejectsNonTickers() {
        XCTAssertEqual(StockWatchlist.normalize(" aapl "), "AAPL")
        XCTAssertEqual(StockWatchlist.normalize("brk-b"), "BRK-B")
        XCTAssertEqual(StockWatchlist.normalize("^gspc"), "^GSPC")
        XCTAssertNil(StockWatchlist.normalize(""))
        XCTAssertNil(StockWatchlist.normalize("has space"))
        XCTAssertNil(StockWatchlist.normalize("way/too?weird"))
        XCTAssertNil(StockWatchlist.normalize("waaaaaaaytoolong"))
    }

    func testWatchlistRoundTripsThroughDisk() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("marduk-stocks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var list = StockWatchlist()
        _ = list.add("AAPL")
        _ = list.setTrigger("AAPL", side: .sell, level: 220)
        list.save(to: url)
        XCTAssertEqual(StockWatchlist.load(from: url), list)
        // Missing file = empty list, never a crash
        XCTAssertEqual(StockWatchlist.load(
            from: URL(fileURLWithPath: "/nonexistent/x.json")), StockWatchlist())
    }

    // MARK: - Session cursor

    func testSessionMoveAndSync() {
        var session = StockSession()
        XCTAssertEqual(session.move(1), 0)  // empty — buzz
        session.sync(to: ["AAPL", "MSFT", "NVDA"], keep: nil)
        XCTAssertEqual(session.move(5), 2)
        XCTAssertEqual(session.current, "NVDA")
        // Removal keeps the cursor sane; keep pins it when possible
        session.sync(to: ["AAPL", "MSFT"], keep: "MSFT")
        XCTAssertEqual(session.current, "MSFT")
        session.sync(to: [], keep: nil)
        XCTAssertNil(session.current)
    }

    // MARK: - :stock grammar

    func testStockColonCommandParses() {
        XCTAssertEqual(StockColonCommand.parse([]), .list)
        XCTAssertEqual(StockColonCommand.parse(["add", "aapl"]), .add("AAPL"))
        XCTAssertEqual(StockColonCommand.parse(["a", "aapl"]), .add("AAPL"))
        XCTAssertEqual(StockColonCommand.parse(["remove", "msft"]),
                       .remove("MSFT"))
        XCTAssertEqual(StockColonCommand.parse(["buy", "aapl", "180"]),
                       .trigger("AAPL", .buy, 180))
        XCTAssertEqual(StockColonCommand.parse(["sell", "aapl", "220.5"]),
                       .trigger("AAPL", .sell, 220.5))
        XCTAssertEqual(StockColonCommand.parse(["buy", "aapl", "off"]),
                       .trigger("AAPL", .buy, nil))
        XCTAssertEqual(StockColonCommand.parse(["buy", "aapl", "cheap"]),
                       .unknown("buy aapl cheap"))
        XCTAssertEqual(StockColonCommand.parse(["add", "not a ticker"]),
                       .unknown("add not a ticker"))
        XCTAssertEqual(StockColonCommand.parse(["bogus"]), .unknown("bogus"))
    }

    func testColonPlumbingForStock() {
        // ":stock" expands instead of executing — a pause mid-"stock add"
        // must never close the command line under the typist
        XCTAssertEqual(ColonCommand.autoResolve("stock"), .expand("stock "))
        XCTAssertEqual(ColonCommand.autoResolve("stock a"),
                       .expand("stock add "))
        XCTAssertEqual(ColonCommand.autoResolve("stock add aapl"), .none)
        XCTAssertEqual(ColonCommand.parse("stock add aapl"),
                       .stock(args: ["add", "aapl"]))
        XCTAssertEqual(ColonCommand.parse("stock"), .stock(args: []))
    }
}
