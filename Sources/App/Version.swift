import Foundation

/// Single source of truth for the version string — the CLI's version output
/// and the bundle's Info.plist both read it.
enum Marduk {
    static let version = "0.3.6"
}
