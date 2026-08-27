import Foundation
import XCTest

/// A locally spawned `shidou-demo`, which is what the store's tests drive.
///
/// The slicing decision put the demo daemon in front of the UI work precisely
/// so the client would be built against real protocol traffic rather than an
/// in-memory fake. That applies hardest here: the store's difficult behaviours
/// are handshake, replay and reconnect behaviours, and a fake would be a
/// second implementation of exactly the thing under test.
final class DemoDaemonProcess {
    let address: String
    let token = "shidou-demo"

    private let process: Process

    /// `replayJournalLimit` shrinks the daemon's per-session event ring so a
    /// test can overflow it in a handful of events. The real ring is 4096 deep
    /// — a phone reaches it after minutes of streaming, a test never would.
    init(replayJournalLimit: Int? = nil) throws {
        guard let binary = Self.binaryURL() else {
            throw XCTSkip(
                """
                shidou-demo was not found. Build it with `cargo build -p shidou-demo`, \
                or point SHIDOU_DEMO_BIN at it.
                """
            )
        }
        var arguments = ["--bind", "127.0.0.1:0"]
        if let replayJournalLimit {
            arguments += ["--replay-journal-limit", String(replayJournalLimit)]
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process

        // The daemon prints one `DaemonReady` line before it serves, so the
        // test never has to guess a port or poll for readiness.
        guard let ready = Self.readReadyLine(from: output.fileHandleForReading),
            let address = ready["address"] as? String
        else {
            process.terminate()
            throw XCTSkip("shidou-demo did not report a listening address")
        }
        self.address = address
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    private static func readReadyLine(from handle: FileHandle) -> [String: Any]? {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { continue }
            buffer.append(chunk)
            guard let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) else { continue }
            let line = buffer[..<newline]
            return try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        }
        return nil
    }

    /// `SHIDOU_DEMO_BIN` wins; otherwise walk up to the workspace root and
    /// look where `cargo build` puts it.
    private static func binaryURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["SHIDOU_DEMO_BIN"] {
            let url = URL(fileURLWithPath: override)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            for profile in ["debug", "release"] {
                let candidate = directory
                    .appendingPathComponent("target")
                    .appendingPathComponent(profile)
                    .appendingPathComponent("shidou-demo")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }
}
