import Foundation

/// A semantic key inside STOCKS mode — the tap translates keycodes, the
/// StocksReader gives them meaning (the NewsCommand pattern).
enum StocksCommand: Equatable {
    case move(Int)      // j/k/arrows with counts
    case top, bottom    // gg / G
    case detail         // r / R — speak the full quote
    case add            // a — prefilled ":stock add " command line
    case remove         // x — remove the current ticker
    case buyTrigger     // b — prefilled ":stock buy SYM "
    case sellTrigger    // s — prefilled ":stock sell SYM "
    case help           // ?
    case exit           // Escape / S (the tap already stood down)
}

/// The spoken cursor over the watchlist. No mirror contract here (there
/// is no external app) — same move semantics as NewsSession so the modes
/// feel identical under the fingers.
struct StockSession: Equatable {
    var symbols: [String] = []
    var index = 0

    var current: String? {
        symbols.indices.contains(index) ? symbols[index] : nil
    }

    /// Clamped move; 0 = edge or empty (caller buzzes).
    mutating func move(_ delta: Int) -> Int {
        guard !symbols.isEmpty else { return 0 }
        let target = min(max(index + delta, 0), symbols.count - 1)
        let steps = target - index
        index = target
        return steps
    }

    /// Re-sync after add/remove, keeping the cursor on `keep` when it
    /// still exists, else clamped in place.
    mutating func sync(to newSymbols: [String], keep: String?) {
        symbols = newSymbols
        if let keep, let kept = newSymbols.firstIndex(of: keep) {
            index = kept
        } else {
            index = symbols.isEmpty ? 0 : min(index, symbols.count - 1)
        }
    }
}

/// The ":stock …" grammar, pure and testable. Subcommands prefix-expand
/// like everything else (":stock a aapl" adds).
enum StockColonCommand: Equatable {
    case list                                  // bare :stock
    case add(String)
    case remove(String)
    case trigger(String, TriggerSide, Double?) // nil level = cleared ("off")
    case unknown(String)

    static let subcommands = ["add", "remove", "buy", "sell"]

    static func parse(_ tokens: [String]) -> StockColonCommand {
        guard let first = tokens.first else { return .list }
        guard let sub = ColonCommand.expand(first.lowercased(), in: subcommands)
        else { return .unknown(tokens.joined(separator: " ")) }
        guard tokens.count >= 2,
              let symbol = StockWatchlist.normalize(tokens[1]) else {
            return .unknown(tokens.joined(separator: " "))
        }
        switch sub {
        case "add":
            return tokens.count == 2 ? .add(symbol)
                : .unknown(tokens.joined(separator: " "))
        case "remove":
            return tokens.count == 2 ? .remove(symbol)
                : .unknown(tokens.joined(separator: " "))
        case "buy", "sell":
            let side: TriggerSide = sub == "buy" ? .buy : .sell
            guard tokens.count == 3 else {
                return .unknown(tokens.joined(separator: " "))
            }
            let value = tokens[2].lowercased()
            if ColonCommand.expand(value, in: ["off"]) == "off" {
                return .trigger(symbol, side, nil)
            }
            guard let level = Double(value), level > 0 else {
                return .unknown(tokens.joined(separator: " "))
            }
            return .trigger(symbol, side, level)
        default:
            return .unknown(tokens.joined(separator: " "))
        }
    }
}
