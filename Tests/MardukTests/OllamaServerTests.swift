import XCTest
@testable import marduk

/// The pure decision bits of the Ollama lifecycle manager. The spawn /
/// terminate side is I/O against a real binary and stays a hardware
/// concern (like every Process-driven subsystem here).
final class OllamaServerTests: XCTestCase {

    // MARK: - isLocal (only a loopback base may be started or stopped)

    func testDefaultBaseIsLocal() {
        XCTAssertTrue(OllamaServer.isLocal(base: "http://127.0.0.1:11434"))
    }

    func testLocalhostNameIsLocal() {
        XCTAssertTrue(OllamaServer.isLocal(base: "http://localhost:11434"))
    }

    func testRemoteHostIsNotLocal() {
        XCTAssertFalse(OllamaServer.isLocal(base: "http://192.168.1.20:11434"))
        XCTAssertFalse(OllamaServer.isLocal(base: "https://ollama.example.com"))
    }

    func testGarbageBaseIsNotLocal() {
        XCTAssertFalse(OllamaServer.isLocal(base: ""))
        XCTAssertFalse(OllamaServer.isLocal(base: "not a url"))
    }

    // MARK: - serveHost (OLLAMA_HOST derivation, custom ports honored)

    func testServeHostDefaultPort() {
        XCTAssertEqual(OllamaServer.serveHost(base: "http://127.0.0.1"),
                       "127.0.0.1:11434")
    }

    func testServeHostCustomPort() {
        XCTAssertEqual(OllamaServer.serveHost(base: "http://127.0.0.1:12345"),
                       "127.0.0.1:12345")
    }

    func testServeHostGarbage() {
        XCTAssertNil(OllamaServer.serveHost(base: ""))
    }

    // MARK: - binary table

    func testBinaryPathsAreAbsolute() {
        for path in OllamaServer.binaryPaths {
            XCTAssertTrue(path.hasPrefix("/"), "\(path) must be absolute")
        }
    }

    // MARK: - refcount safety (no server spawned — probe fails fast on
    // a port nothing listens on, so acquire/release exercise only the
    // bookkeeping; a raw release can never underflow or kill anything)

    func testUnbalancedReleaseIsHarmless() {
        let server = OllamaServer()
        server.release()
        server.release()
        server.stop()
    }
}
