import XCTest
@testable import marduk

/// `Bundler.projectDir(fromExecutable:)` decides whether an install is a
/// real repo install or a bare binary. A wrong nil silently downgrades a
/// bundle install to the TCC-fragile bare-binary path (main.swift) or
/// aborts `bundle`/`update` outright, so the walk-up deserves coverage of
/// both real layouts and its bounds.
final class BundlerTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundler-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// Build a directory chain under root and drop an empty file at the end.
    @discardableResult
    private func make(_ components: [String], marker: String? = nil) -> URL {
        var url = root!
        for component in components {
            url.appendPathComponent(component)
        }
        try? FileManager.default.createDirectory(at: url,
                                                 withIntermediateDirectories: true)
        if let marker {
            FileManager.default.createFile(
                atPath: url.appendingPathComponent(marker).path, contents: Data())
        }
        return url
    }

    private func markPackage(_ dir: URL) {
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("Package.swift").path, contents: Data())
    }

    /// projectDir standardizes but deliberately does NOT resolve symlinks,
    /// and the temp dir is one (/var → /private/var) — so normalize both
    /// sides rather than assume which form comes back.
    private func assertProjectDir(_ execPath: String, isRepo repo: URL,
                                  line: UInt = #line) {
        guard let found = Bundler.projectDir(fromExecutable: execPath) else {
            XCTFail("expected a project dir for \(execPath)", line: line)
            return
        }
        XCTAssertEqual(URL(fileURLWithPath: found).resolvingSymlinksInPath().path,
                       repo.resolvingSymlinksInPath().path, line: line)
    }

    // MARK: - The two real layouts

    func testFindsRepoFromBundleExecutable() {
        let repo = make(["repo"])
        markPackage(repo)
        let exec = make(["repo", "Marduk.app", "Contents", "MacOS"])
            .appendingPathComponent("marduk")
        assertProjectDir(exec.path, isRepo: repo)
    }

    func testFindsRepoFromBuildExecutable() {
        let repo = make(["repo"])
        markPackage(repo)
        let exec = make(["repo", ".build", "arm64-apple-macosx", "debug"])
            .appendingPathComponent("marduk")
        assertProjectDir(exec.path, isRepo: repo)
    }

    // MARK: - The bare-binary / no-repo answer

    func testNilWhenNoPackageSwiftAnywhereAbove() {
        let exec = make(["nowhere", "bin"]).appendingPathComponent("marduk")
        XCTAssertNil(Bundler.projectDir(fromExecutable: exec.path))
    }

    /// The walk stops after 6 hops — a Package.swift further up than that
    /// is deliberately NOT adopted (an unrelated ancestor repo must never
    /// be mistaken for Marduk's own).
    func testStopsAfterSixHops() {
        let deepRoot = make(["deep"])
        markPackage(deepRoot)
        let exec = make(["deep", "a", "b", "c", "d", "e", "f", "g"])
            .appendingPathComponent("marduk")
        XCTAssertNil(Bundler.projectDir(fromExecutable: exec.path))
    }

    func testFindsPackageExactlyAtTheSixthHop() {
        let sixth = make(["six"])
        markPackage(sixth)
        let exec = make(["six", "a", "b", "c", "d", "e"])
            .appendingPathComponent("marduk")
        assertProjectDir(exec.path, isRepo: sixth)
    }

    // MARK: - Path shapes that must not fool it

    /// The walk keys on Package.swift, never on a "Marduk.app" name — a
    /// parent directory that merely happens to be called Marduk.app must
    /// not short-circuit the search.
    func testMarkukAppInAParentNameIsNotASignal() {
        let exec = make(["Marduk.app", "nested", "bin"])
            .appendingPathComponent("marduk")
        XCTAssertNil(Bundler.projectDir(fromExecutable: exec.path))
    }

    func testStandardizesRelativeTraversal() {
        let repo = make(["repo"])
        markPackage(repo)
        make(["repo", "Marduk.app", "Contents", "MacOS"])
        let messy = root.appendingPathComponent(
            "repo/Marduk.app/Contents/other/../MacOS/marduk").path
        assertProjectDir(messy, isRepo: repo)
    }

    /// A path at (or adjacent to) the filesystem root must terminate, not
    /// spin — the `url.path != "/"` guard.
    func testRootAdjacentPathTerminates() {
        XCTAssertNil(Bundler.projectDir(fromExecutable: "/marduk"))
        XCTAssertNil(Bundler.projectDir(fromExecutable: "/"))
    }

    // MARK: - Path builders

    func testBundleAndExecutablePathsCompose() {
        XCTAssertEqual(Bundler.bundlePath(projectDir: "/x/repo"),
                       "/x/repo/Marduk.app")
        XCTAssertEqual(Bundler.executablePath(projectDir: "/x/repo"),
                       "/x/repo/Marduk.app/Contents/MacOS/marduk")
    }

    /// The identity trio: codesign identifier == CFBundleIdentifier ==
    /// launchd label. TCC grants survive rebuilds only while these agree.
    func testBundleIDMatchesCodesignIdentity() {
        XCTAssertEqual(Bundler.bundleID, Codesign.identifier)
        XCTAssertEqual(Bundler.bundleID, "com.marduk.daemon")
    }
}
