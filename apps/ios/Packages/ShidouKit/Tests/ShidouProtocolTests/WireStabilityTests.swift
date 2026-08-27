import Foundation
import XCTest

@testable import ShidouProtocol

/// Mirrors the wire-stability tests in
/// `crates/shidou-protocol/src/protocol.rs` so Swift and Rust cannot drift
/// silently within protocol version 5.
final class WireStabilityTests: XCTestCase {
    private func json<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testHandshakeAndReplayFieldNamesAreStable() throws {
        let sessionId = UUID.zero
        let runtimeId = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let epoch = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let clientId = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let message = ClientMessage.hello(
            token: "secret",
            clientId: clientId,
            resumeFrom: [
                ReplayCursor(sessionId: sessionId, runtimeId: runtimeId, epoch: epoch, sequence: 9)
            ]
        )
        let object = try json(message)

        XCTAssertEqual(object["type"] as? String, "hello")
        XCTAssertEqual(object["protocolVersion"] as? UInt32, ShidouWire.protocolVersion)
        XCTAssertEqual(object["token"] as? String, "secret")
        XCTAssertEqual(object["clientId"] as? String, "00000000-0000-0000-0000-000000000002")
        let cursors = try XCTUnwrap(object["resumeFrom"] as? [[String: Any]])
        XCTAssertEqual(cursors[0]["sessionId"] as? String, "00000000-0000-0000-0000-000000000000")
        XCTAssertEqual(cursors[0]["runtimeId"] as? String, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(cursors[0]["epoch"] as? String, "00000000-0000-0000-0000-000000000003")
        XCTAssertEqual(cursors[0]["sequence"] as? UInt64, 9)
        XCTAssertNil(object["protocol_version"])
    }

    func testForkAndRewindCommandsUseStableCamelCaseFields() throws {
        var object = try json(Command.forkSessionFromResponse(turnCount: 7))
        XCTAssertEqual(object["type"] as? String, "forkSessionFromResponse")
        XCTAssertEqual(object["turnCount"] as? Int, 7)

        object = try json(Command.rewindSessionToMessage(turnCount: 4))
        XCTAssertEqual(object["type"] as? String, "rewindSessionToMessage")
        XCTAssertEqual(object["turnCount"] as? Int, 4)
    }

    func testRequestEnvelopeFlattensIntoClientMessage() throws {
        let request = Request(
            requestId: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000000a")),
            sessionId: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000000b")),
            runtimeId: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000000c")),
            command: .prompt("hello")
        )
        let object = try json(ClientMessage.request(request))
        XCTAssertEqual(object["type"] as? String, "request")
        XCTAssertEqual(object["requestId"] as? String, "00000000-0000-0000-0000-00000000000a")
        XCTAssertEqual(object["sessionId"] as? String, "00000000-0000-0000-0000-00000000000b")
        XCTAssertEqual(object["runtimeId"] as? String, "00000000-0000-0000-0000-00000000000c")
        let command = try XCTUnwrap(object["command"] as? [String: Any])
        XCTAssertEqual(command["type"] as? String, "prompt")
        XCTAssertEqual(command["prompt"] as? String, "hello")
    }

    func testWorkspaceOperationFieldsStaySnakeCase() throws {
        let object = try json(Command.workspace(.commit(
            cwd: "/tmp/repo", message: "msg", includeUnstaged: true, push: false
        )))
        let operation = try XCTUnwrap(object["operation"] as? [String: Any])
        XCTAssertEqual(operation["type"] as? String, "commit")
        XCTAssertEqual(operation["include_unstaged"] as? Bool, true)
        XCTAssertNil(operation["includeUnstaged"])

        let hasRef = try json(Command.workspace(.hasRef(cwd: "/tmp/repo", gitRef: "refs/shidou/x")))
        let refOperation = try XCTUnwrap(hasRef["operation"] as? [String: Any])
        XCTAssertEqual(refOperation["git_ref"] as? String, "refs/shidou/x")
    }

    /// The commands this slice sends. The wire tests are hand-mirrored rather
    /// than generated, so a command with a consumer and no assertion is a
    /// command whose field names nothing is holding still.
    func testTheCommandsTheSessionStoreSendsHaveStableShapes() throws {
        let sessionId = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000002a"))

        XCTAssertEqual(try json(Command.loadTaskState)["type"] as? String, "loadTaskState")
        XCTAssertEqual(try json(Command.attachSession)["type"] as? String, "attachSession")
        XCTAssertEqual(try json(Command.removeSession)["type"] as? String, "removeSession")

        var object = try json(Command.hydrateSession(sessionId: sessionId))
        XCTAssertEqual(object["type"] as? String, "hydrateSession")
        XCTAssertEqual(object["sessionId"] as? String, "00000000-0000-0000-0000-00000000002a")

        let session = AgentSession(
            id: sessionId, projectId: .zero, provider: .claude, createdAt: 1, updatedAt: 2
        )
        object = try json(Command.saveTaskState(
            projects: [], liveSessionIds: [sessionId], sessions: [session]
        ))
        XCTAssertEqual(object["type"] as? String, "saveTaskState")
        XCTAssertEqual(
            object["liveSessionIds"] as? [String], ["00000000-0000-0000-0000-00000000002a"]
        )
        let sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        // The session model has no `rename_all`, so its fields stay snake_case
        // even though the command wrapping them is camelCase.
        XCTAssertEqual(sessions[0]["project_id"] as? String, "00000000-0000-0000-0000-000000000000")
        XCTAssertEqual(sessions[0]["created_at"] as? UInt64, 1)
        XCTAssertNil(sessions[0]["projectId"])

        object = try json(Command.workspace(.inspectCommit(cwd: "/src/shidou")))
        let operation = try XCTUnwrap(object["operation"] as? [String: Any])
        XCTAssertEqual(operation["type"] as? String, "inspectCommit")
        XCTAssertEqual(operation["cwd"] as? String, "/src/shidou")
    }

    func testServerMessagesDecode() throws {
        let hello = try JSONDecoder().decode(
            ServerMessage.self,
            from: Data(#"{"type":"hello","protocolVersion":5,"daemonVersion":"1.2.3"}"#.utf8)
        )
        guard case .hello(let version, let daemon) = hello else {
            return XCTFail("expected hello")
        }
        XCTAssertEqual(version, 5)
        XCTAssertEqual(daemon, "1.2.3")

        let rejected = try JSONDecoder().decode(
            ServerMessage.self,
            from: Data(#"{"type":"rejected","message":"bad token"}"#.utf8)
        )
        guard case .rejected(let message) = rejected else {
            return XCTFail("expected rejected")
        }
        XCTAssertEqual(message, "bad token")

        let unknown = try JSONDecoder().decode(
            ServerMessage.self,
            from: Data(#"{"type":"somethingNew","whatever":1}"#.utf8)
        )
        guard case .unknown(let type) = unknown else {
            return XCTFail("expected unknown fallback")
        }
        XCTAssertEqual(type, "somethingNew")
    }

    /// Mirrors `ServerMessage::ReplayGap`. This one is worth pinning field by
    /// field: it only ever arrives when a client has already lost events, so a
    /// silent decode failure would be invisible until a transcript came back
    /// with a hole in it.
    func testReplayGapDecodes() throws {
        let data = Data("""
            {"type":"replayGap","sessionId":"00000000-0000-0000-0000-000000000001",
             "runtimeId":"00000000-0000-0000-0000-000000000002",
             "epoch":"00000000-0000-0000-0000-000000000003","firstAvailable":4097}
            """.utf8)
        let message = try JSONDecoder().decode(ServerMessage.self, from: data)
        guard case .replayGap(let gap) = message else {
            return XCTFail("expected a replay gap")
        }
        XCTAssertEqual(gap.sessionId.wireString, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(gap.runtimeId.wireString, "00000000-0000-0000-0000-000000000002")
        XCTAssertEqual(gap.epoch.wireString, "00000000-0000-0000-0000-000000000003")
        XCTAssertEqual(gap.firstAvailable, 4097)
    }

    func testEventEnvelopeDecodes() throws {
        let data = Data("""
            {"type":"event","sessionId":"00000000-0000-0000-0000-000000000001",
             "runtimeId":"00000000-0000-0000-0000-000000000002",
             "epoch":"00000000-0000-0000-0000-000000000003",
             "sequence":42,"event":{"kind":"textDelta","payload":"hi"}}
            """.utf8)
        let message = try JSONDecoder().decode(ServerMessage.self, from: data)
        guard case .event(let event) = message else {
            return XCTFail("expected event")
        }
        XCTAssertEqual(event.sequence, 42)
        guard case .textDelta(let text) = DriverEvent(wire: event.event) else {
            return XCTFail("expected textDelta")
        }
        XCTAssertEqual(text, "hi")
    }

    func testResponseOutcomeDecodes() throws {
        let ok = try JSONDecoder().decode(
            ResponseOutcome.self,
            from: Data(#"{"status":"ok","payload":{"type":"ack"}}"#.utf8)
        )
        guard case .ok(.ack) = ok else { return XCTFail("expected ack") }

        let error = try JSONDecoder().decode(
            ResponseOutcome.self,
            from: Data(#"{"status":"error","error":{"message":"nope"}}"#.utf8)
        )
        guard case .error(let rpc) = error else { return XCTFail("expected error") }
        XCTAssertEqual(rpc.message, "nope")
    }

    func testBlobDataDecodesBase64() throws {
        let payload = try JSONDecoder().decode(
            ResponsePayload.self,
            from: Data(#"{"type":"blobData","bytes":"AAEC/w=="}"#.utf8)
        )
        guard case .blobData(let data) = payload else { return XCTFail("expected blobData") }
        XCTAssertEqual([UInt8](data), [0, 1, 2, 255])
    }

    func testUnknownEnumValuesFallBack() throws {
        XCTAssertEqual(
            try JSONDecoder().decode(ProviderKind.self, from: Data(#""futureAgent""#.utf8)),
            .unknown
        )
        XCTAssertEqual(
            try JSONDecoder().decode(SessionStatus.self, from: Data(#""hibernating""#.utf8)),
            .unknown
        )
    }

    func testTranscriptBlockRoundTripsAndAcceptsLegacyReasoning() throws {
        let legacy = Data("""
            {"after_message":2,"turn_id":null,
             "content":{"kind":"reasoning","data":{"content":"hm","started_at_ms":1,"finished_at_ms":2}}}
            """.utf8)
        let block = try JSONDecoder().decode(TranscriptBlock.self, from: legacy)
        XCTAssertEqual(block.afterMessage, 2)
        XCTAssertEqual(block.activities.count, 1)
        XCTAssertEqual(block.activities[0].kind, .reasoning)
        XCTAssertEqual(block.activities[0].reasoning?.content, "hm")

        let reencoded = try json(block)
        let content = try XCTUnwrap(reencoded["content"] as? [String: Any])
        XCTAssertEqual(content["kind"] as? String, "activities")
    }

    func testReportedCommandAcceptsBareStrings() throws {
        let commands = try JSONDecoder().decode(
            [ReportedCommand].self,
            from: Data(#"["compact",{"name":"review","description":"Review code"}]"#.utf8)
        )
        XCTAssertEqual(commands[0].name, "compact")
        XCTAssertEqual(commands[1].description, "Review code")
    }
}
