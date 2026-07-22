import Foundation

/// Single source of truth for the version string — the CLI's version output
/// and the bundle's Info.plist both read it.
enum Marduk {
    static let version = "0.4.11"
    /// Newest macOS major Marduk has been validated on — bump after each
    /// major's beta checklist passes (see memory: macos-27-readiness).
    static let testedMacOSMajor = 26
}
