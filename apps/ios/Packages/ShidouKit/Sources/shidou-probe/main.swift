import Foundation
import ShidouClient
import ShidouProtocol

// CLI harness for milestone verification:
//   swift run shidou-probe ws://127.0.0.1:34123 <token>
// Connects, prints the daemon hello, loads task state, and dumps counts.
// With --watch <sessionId>, attaches and streams events until interrupted.

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data(
        "usage: shidou-probe <address> <token> [--watch <sessionId>]\n".utf8
    ))
    exit(2)
}

let address = arguments[1]
let token = arguments[2]
var watchSession: UUID?
if let flagIndex = arguments.firstIndex(of: "--watch"), arguments.indices.contains(flagIndex + 1) {
    watchSession = UUID(uuidString: arguments[flagIndex + 1])
}
let hydrateAll = arguments.contains("--hydrate-all")

func run(watchSession: UUID?) async -> Int32 {
    do {
        let endpoint = try DaemonEndpoint(address: address, token: token)
        let client = ShidouDaemonClient(endpoint: endpoint)
        let hello = try await client.connect()
        print("connected: protocol \(hello.protocolVersion), daemon \(hello.daemonVersion)")

        let payload = try await client.request(.loadTaskState)
        guard case .taskState(let projects, let sessions, let defaultCwd, _) = payload else {
            print("unexpected response to loadTaskState")
            return 1
        }
        print("projects: \(projects.count), sessions: \(sessions.count), defaultCwd: \(defaultCwd)")
        for session in sessions.prefix(20) {
            print("  [\(session.status.rawValue)] \(session.displayTitle) (\(session.provider.rawValue)) \(session.id.wireString)")
        }

        if hydrateAll {
            for session in sessions {
                let response = try await client.request(.hydrateSession(sessionId: session.id))
                guard case .session(let hydrated) = response else {
                    print("  hydrate \(session.id.wireString): unexpected response")
                    continue
                }
                guard let hydrated else {
                    print("  hydrate \(session.id.wireString): daemon returned no session")
                    continue
                }
                let activities = hydrated.transcriptBlocks.reduce(0) { $0 + $1.activities.count }
                print(
                    "  hydrated \(hydrated.displayTitle): \(hydrated.messages.count) messages, "
                        + "\(hydrated.turns.count) turns, \(activities) activities"
                )
            }
        }

        guard let watchSession else { return 0 }
        let events = await client.events()
        let runtime = try await client.request(.attachSession, sessionId: watchSession)
        guard case .sessionRuntime(let runtimeId, let supportsSteer) = runtime else {
            print("unexpected response to attachSession")
            return 1
        }
        print("attached: runtime \(runtimeId?.wireString ?? "none"), supportsSteer: \(supportsSteer)")
        for await item in events {
            switch item {
            case .event(let event):
                guard event.sessionId == watchSession else { continue }
                let driver = DriverEvent(wire: event.event)
                print("#\(event.sequence) \(event.event.kind): \(summary(of: driver))")
            case .taskStateChanged(let revision):
                print("taskStateChanged revision \(revision)")
            case .replayGap(let gap):
                print("replayGap: journal starts at #\(gap.firstAvailable)")
            case .disconnected:
                print("disconnected")
                return 0
            }
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        return 1
    }
}

func summary(of event: DriverEvent) -> String {
    switch event {
    case .textDelta(let text), .reasoningDelta(let text):
        return String(text.prefix(60)).replacingOccurrences(of: "\n", with: "\\n")
    case .activity(_, let kind, let title, _, let complete):
        return "\(kind.rawValue) \(title) complete=\(complete)"
    case .richActivity(let item):
        return "\(item.kind.rawValue) \(item.title) complete=\(item.complete)"
    case .turnFinished(let success, let summary):
        return "success=\(success) \(summary ?? "")"
    case .permission(_, let title, _, let options):
        return "\(title) (\(options.count) options)"
    case .error(let message):
        return message
    default:
        return ""
    }
}

exit(await run(watchSession: watchSession))
