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
            command: .prompt(
                "hello",
                submissionId: try XCTUnwrap(
                    UUID(uuidString: "00000000-0000-0000-0000-00000000000d")
                )
            )
        )
        let object = try json(ClientMessage.request(request))
        XCTAssertEqual(object["type"] as? String, "request")
        XCTAssertEqual(object["requestId"] as? String, "00000000-0000-0000-0000-00000000000a")
        XCTAssertEqual(object["sessionId"] as? String, "00000000-0000-0000-0000-00000000000b")
        XCTAssertEqual(object["runtimeId"] as? String, "00000000-0000-0000-0000-00000000000c")
        let command = try XCTUnwrap(object["command"] as? [String: Any])
        XCTAssertEqual(command["type"] as? String, "prompt")
        XCTAssertEqual(command["prompt"] as? String, "hello")
        XCTAssertEqual(command["submissionId"] as? String, "00000000-0000-0000-0000-00000000000d")
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

        let sessionId = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000002a"))
        let turnRefs = try json(Command.workspace(
            .sessionTurnRefs(cwd: "/tmp/repo", sessionId: sessionId)
        ))
        let turnRefsOperation = try XCTUnwrap(turnRefs["operation"] as? [String: Any])
        XCTAssertEqual(turnRefsOperation["type"] as? String, "sessionTurnRefs")
        XCTAssertEqual(turnRefsOperation["session_id"] as? String, sessionId.wireString)
    }

    /// The rewind offer is built from this response, so its one field is
    /// exactly as load-bearing as the command that asks for it.
    func testTurnRefsResultDecodes() throws {
        let data = Data(#"{"type":"turnRefs","turn_counts":[0,1,3]}"#.utf8)
        let result = try JSONDecoder().decode(WorkspaceResult.self, from: data)
        guard case .turnRefs(let counts) = result else {
            return XCTFail("expected turnRefs, got \(result)")
        }
        XCTAssertEqual(counts, [0, 1, 3])
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

    // MARK: - Slice ② commands

    func testComposerDraftCommandsHaveStableWireKeys() throws {
        let projectId = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000007"))
        let sessionId = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000008"))

        XCTAssertEqual(
            try json(Command.loadComposerDrafts)["type"] as? String, "loadComposerDrafts")

        var object = try json(Command.applyComposerDraftChanges(changes: [
            ComposerDraftChange(
                target: .newSession(projectId: projectId),
                draft: ComposerDraft(text: "unfinished")
            )
        ]))
        XCTAssertEqual(object["type"] as? String, "applyComposerDraftChanges")
        let changes = try XCTUnwrap(object["changes"] as? [[String: Any]])
        let target = try XCTUnwrap(changes[0]["target"] as? [String: Any])
        XCTAssertEqual(target["type"] as? String, "newSession")
        XCTAssertEqual(target["projectId"] as? String, "00000000-0000-0000-0000-000000000007")
        let draft = try XCTUnwrap(changes[0]["draft"] as? [String: Any])
        XCTAssertEqual(draft["text"] as? String, "unfinished")

        var drafts = ComposerDrafts()
        drafts[.session(sessionId: sessionId)] = ComposerDraft(text: "keep")
        object = try json(Command.saveComposerDrafts(drafts: drafts, generation: 3))
        XCTAssertEqual(object["type"] as? String, "saveComposerDrafts")
        XCTAssertEqual(object["generation"] as? UInt64, 3)
        let saved = try XCTUnwrap(object["drafts"] as? [String: Any])
        // The maps stay snake_case: `ComposerDrafts` carries no `rename_all`.
        let sessionDrafts = try XCTUnwrap(saved["sessions"] as? [String: Any])
        XCTAssertNotNil(sessionDrafts["00000000-0000-0000-0000-000000000008"])
        XCTAssertNotNil(saved["new_sessions"])
    }

    func testComposerDraftsDecodeFromTheDaemonsMaps() throws {
        let drafts = try JSONDecoder().decode(
            ComposerDrafts.self,
            from: Data(
                """
                {"new_sessions":{"00000000-0000-0000-0000-000000000007":{"text":"a"}},\
                "sessions":{"00000000-0000-0000-0000-000000000008":{"text":"b",\
                "attachments":[{"path":"/p","mention":"p","name":"p","is_dir":false,\
                "is_image":true,"blob_reference":"shidou-blob:1"}]}}}
                """.utf8
            )
        )
        let projectId = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000007"))
        let sessionId = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000008"))
        XCTAssertEqual(drafts[.newSession(projectId: projectId)]?.text, "a")
        XCTAssertEqual(drafts[.session(sessionId: sessionId)]?.attachments.first?.isImage, true)
    }

    func testAttachmentAndBlobCommandsHaveStableWireKeys() throws {
        var object = try json(Command.storeBlob(mimeType: "image/png", bytes: Data([0, 1, 2, 255])))
        XCTAssertEqual(object["type"] as? String, "storeBlob")
        XCTAssertEqual(object["mimeType"] as? String, "image/png")
        XCTAssertEqual(object["bytes"] as? String, "AAEC/w==")

        object = try json(Command.importAttachment(
            name: "shot.png", upload: .file(dataBase64: "AAEC")
        ))
        XCTAssertEqual(object["type"] as? String, "importAttachment")
        XCTAssertEqual(object["name"] as? String, "shot.png")
        let upload = try XCTUnwrap(object["upload"] as? [String: Any])
        XCTAssertEqual(upload["kind"] as? String, "file")
        // The upload enum has no `rename_all_fields`, so this one stays snake.
        XCTAssertEqual(upload["data_base64"] as? String, "AAEC")
        XCTAssertNil(upload["dataBase64"])

        object = try json(Command.importPathAttachment(path: "/src/main.rs"))
        XCTAssertEqual(object["type"] as? String, "importPathAttachment")
        XCTAssertEqual(object["path"] as? String, "/src/main.rs")

    }

    func testApplyOptionsHasStableWireKeys() throws {
        let object = try json(Command.applyOptions(SessionOptions(
            mode: .autoAcceptEdits, interactionMode: .plan, model: "gpt-5", reasoningEffort: "high"
        )))
        XCTAssertEqual(object["type"] as? String, "applyOptions")
        let options = try XCTUnwrap(object["options"] as? [String: Any])
        XCTAssertEqual(options["mode"] as? String, "autoAcceptEdits")
        XCTAssertEqual(options["interactionMode"] as? String, "plan")
        XCTAssertEqual(options["reasoningEffort"] as? String, "high")
        XCTAssertTrue(options.keys.contains("serviceTier"), "unset traits are sent as null")
    }

    func testComposerWorkspaceOperationsHaveStableWireKeys() throws {
        var operation = try XCTUnwrap(
            try json(Command.workspace(.browseDirectory(path: nil)))["operation"] as? [String: Any])
        XCTAssertEqual(operation["type"] as? String, "browseDirectory")
        XCTAssertTrue(operation.keys.contains("path"), "a nil path means the daemon's home")

        operation = try XCTUnwrap(
            try json(Command.workspace(.listProjectFiles(root: "/src", cap: 50_000)))["operation"]
                as? [String: Any])
        XCTAssertEqual(operation["type"] as? String, "listProjectFiles")
        XCTAssertEqual(operation["root"] as? String, "/src")
        XCTAssertEqual(operation["cap"] as? Int, 50_000)

        operation = try XCTUnwrap(
            try json(Command.workspace(
                .discoverSlashCommands(provider: .claude, projectRoot: "/src")
            ))["operation"] as? [String: Any])
        XCTAssertEqual(operation["type"] as? String, "discoverSlashCommands")
        XCTAssertEqual(operation["provider"] as? String, "claude")
        XCTAssertEqual(operation["project_root"] as? String, "/src")
        XCTAssertNil(operation["projectRoot"])

        operation = try XCTUnwrap(
            try json(Command.workspace(.inspectBranches(cwd: "/src")))["operation"]
                as? [String: Any])
        XCTAssertEqual(operation["type"] as? String, "inspectBranches")

        operation = try XCTUnwrap(
            try json(Command.workspace(
                .checkoutBranch(cwd: "/src", branch: "main", create: true)
            ))["operation"] as? [String: Any])
        XCTAssertEqual(operation["type"] as? String, "checkoutBranch")
        XCTAssertEqual(operation["branch"] as? String, "main")
        XCTAssertEqual(operation["create"] as? Bool, true)

        operation = try XCTUnwrap(
            try json(Command.workspace(.createWorktree(
                projectPath: "/src",
                projectId: .zero,
                sessionId: .zero,
                prompt: "fix the limiter",
                baseBranch: "main"
            )))["operation"] as? [String: Any])
        XCTAssertEqual(operation["type"] as? String, "createWorktree")
        XCTAssertEqual(operation["project_path"] as? String, "/src")
        XCTAssertEqual(operation["base_branch"] as? String, "main")
    }

    func testComposerWorkspaceResultsDecode() throws {
        var result = try JSONDecoder().decode(
            WorkspaceResult.self,
            from: Data(
                """
                {"type":"directory","path":"/Users/demo","parent":"/Users","home":"/Users/demo",                "filesystem_root":"/","entries":[{"relativePath":"src","absolutePath":                "/Users/demo/src","name":"src","isDir":true,"expanded":false,"depth":0,                "status":"modified"}]}
                """.utf8
            )
        )
        guard case .directory(let directory) = result else {
            return XCTFail("expected a directory result")
        }
        XCTAssertEqual(directory.parent, "/Users")
        XCTAssertEqual(directory.filesystemRoot, "/")
        XCTAssertEqual(directory.entries.first?.absolutePath, "/Users/demo/src")
        XCTAssertEqual(directory.entries.first?.status, .modified)

        result = try JSONDecoder().decode(
            WorkspaceResult.self,
            from: Data(
                #"{"type":"projectFiles","entries":[{"path":"src/main.rs","is_dir":false}]}"#.utf8)
        )
        guard case .projectFiles(let files) = result else {
            return XCTFail("expected a project-file result")
        }
        XCTAssertEqual(files.first?.path, "src/main.rs")

        result = try JSONDecoder().decode(
            WorkspaceResult.self,
            from: Data(
                """
                {"type":"slashCommands","commands":[{"name":"tdd","description":"Test first",                "scope":"Skill","argument_hint":null,"template":null}]}
                """.utf8
            )
        )
        guard case .slashCommands(let commands) = result else {
            return XCTFail("expected a slash-command result")
        }
        // `CommandScope` has no serde rename, so its values are PascalCase.
        XCTAssertEqual(commands.first?.scope, .skill)

        result = try JSONDecoder().decode(
            WorkspaceResult.self,
            from: Data(
                """
                {"type":"branches","snapshot":{"repository":"/src","current":"main",                "detached_head":null,"default_branch":"main","branches":[{"name":"main",                "checked_out_elsewhere":false}],"additions":3,"deletions":1}}
                """.utf8
            )
        )
        guard case .branches(let snapshot) = result else {
            return XCTFail("expected a branches result")
        }
        XCTAssertEqual(snapshot?.displayBranch, "main")
        XCTAssertEqual(snapshot?.branches.first?.checkedOutElsewhere, false)

        result = try JSONDecoder().decode(
            WorkspaceResult.self,
            from: Data(
                """
                {"type":"branchChanged","snapshot":{"repository":"/src","current":"feature",                "detached_head":null,"default_branch":"main","branches":[],"additions":0,                "deletions":0}}
                """.utf8
            )
        )
        guard case .branchChanged(let changed) = result else {
            return XCTFail("expected a branchChanged result")
        }
        XCTAssertEqual(changed.current, "feature")
    }

    func testComposerResponsePayloadsDecode() throws {
        var payload = try JSONDecoder().decode(
            ResponsePayload.self, from: Data(#"{"type":"optionsApplied","applied":true}"#.utf8))
        guard case .optionsApplied(let applied) = payload else {
            return XCTFail("expected optionsApplied")
        }
        XCTAssertTrue(applied)

        payload = try JSONDecoder().decode(
            ResponsePayload.self,
            from: Data(
                #"{"type":"blobStored","reference":"shidou-blob:1","path":"/blobs/1.png"}"#.utf8)
        )
        guard case .blobStored(let reference, let path) = payload else {
            return XCTFail("expected blobStored")
        }
        XCTAssertEqual(reference, "shidou-blob:1")
        XCTAssertEqual(path, "/blobs/1.png")

        payload = try JSONDecoder().decode(
            ResponsePayload.self,
            from: Data(
                """
                {"type":"attachmentStored","attachment":{"reference":"shidou-attachment:2",                "path":"/src/main.rs","name":"main.rs","isDir":false}}
                """.utf8
            )
        )
        guard case .attachmentStored(let attachment) = payload else {
            return XCTFail("expected attachmentStored")
        }
        XCTAssertEqual(attachment.name, "main.rs")

    }

    func testPlanUsageRoundTripsThroughItsCamelCaseFields() throws {
        let object = try json(Command.fetchPlanUsage(
            provider: .claude, binaryOverride: "/opt/claude", cliVersion: "2.4.1"))
        XCTAssertEqual(object["type"] as? String, "fetchPlanUsage")
        XCTAssertEqual(object["binaryOverride"] as? String, "/opt/claude")
        XCTAssertEqual(object["cliVersion"] as? String, "2.4.1")

        let payload = try JSONDecoder().decode(
            ResponsePayload.self,
            from: Data(
                """
                {"type":"planUsage","usage":{"planLabel":"Demo","windows":[{"label":"5-hour",\
                "percent":34.0,"resetsAt":1700000000}]}}
                """.utf8
            )
        )
        guard case .planUsage(let usage) = payload else { return XCTFail("expected planUsage") }
        XCTAssertEqual(usage?.planLabel, "Demo")
        XCTAssertEqual(usage?.windows.first?.resetsAt, 1_700_000_000)
    }

    func testProjectCarriesItsWorkspaceDefault() throws {
        let project = try JSONDecoder().decode(
            Project.self,
            from: Data(
                """
                {"id":"00000000-0000-0000-0000-000000000001","name":"shidou","path":"/src",                "created_at":7,"workspace_default":"NewWorktree"}
                """.utf8
            )
        )
        XCTAssertEqual(project.workspaceDefault, .newWorktree)
        XCTAssertEqual(project.workspaceDefault.sessionWorkspace, .newWorktree(baseBranch: nil))

        // Older daemons omit the field entirely rather than sending a default.
        let legacy = try JSONDecoder().decode(
            Project.self,
            from: Data(
                #"{"id":"00000000-0000-0000-0000-000000000001","name":"n","path":"/p"}"#.utf8)
        )
        XCTAssertEqual(legacy.workspaceDefault, .local)
    }

    // MARK: - Slice ③ commands

    /// The read-only surfaces, settings and git commands this slice sends.
    /// Same rule as the earlier slices: a command with a consumer and no
    /// assertion is a command whose field names nothing is holding still.
    func testSurfaceWorkspaceOperationsHaveStableWireKeys() throws {
        var operation = try XCTUnwrap(try json(Command.workspace(
            .listTree(root: "/src", expandedPaths: ["/src/app", "/src/app/ui"])
        ))["operation"] as? [String: Any])
        XCTAssertEqual(operation["type"] as? String, "listTree")
        XCTAssertEqual(operation["root"] as? String, "/src")
        XCTAssertEqual(operation["expanded_paths"] as? [String], ["/src/app", "/src/app/ui"])
        XCTAssertNil(operation["expandedPaths"])

        operation = try XCTUnwrap(try json(Command.workspace(
            .readTextFile(root: "/src", relativePath: "src/limiter.rs")
        ))["operation"] as? [String: Any])
        XCTAssertEqual(operation["type"] as? String, "readTextFile")
        XCTAssertEqual(operation["relative_path"] as? String, "src/limiter.rs")
        XCTAssertNil(operation["relativePath"])

        operation = try XCTUnwrap(try json(Command.workspace(
            .collectReviewDiff(cwd: "/src", source: .uncommitted)
        ))["operation"] as? [String: Any])
        XCTAssertEqual(operation["type"] as? String, "collectReviewDiff")
        XCTAssertEqual(operation["source"] as? String, "uncommitted")

        let turnId = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-0000000000b1"))
        operation = try XCTUnwrap(try json(Command.workspace(.collectReviewDiff(
            cwd: "/src", source: .lastTurn(sessionId: .zero, turnId: turnId, turnCount: 3)
        )))["operation"] as? [String: Any])
        let source = try XCTUnwrap(operation["source"] as? [String: Any])
        let lastTurn = try XCTUnwrap(source["lastTurn"] as? [String: Any])
        // `rename_all` on `ReviewDiffSource` renames variants, not fields.
        XCTAssertEqual(lastTurn["turn_count"] as? Int, 3)
        XCTAssertEqual(lastTurn["turn_id"] as? String, "00000000-0000-0000-0000-0000000000b1")
        XCTAssertNil(lastTurn["turnCount"])

        operation = try XCTUnwrap(try json(Command.workspace(.push(cwd: "/src")))["operation"]
            as? [String: Any])
        XCTAssertEqual(operation["type"] as? String, "push")
        XCTAssertEqual(operation["cwd"] as? String, "/src")

        operation = try XCTUnwrap(try json(Command.workspace(.generateCommitMessage(
            cwd: "/src",
            includeUnstaged: true,
            conventionalCommits: true,
            invocation: AgentInvocation(
                provider: .claude, binary: "/opt/claude", model: "sonnet", reasoningEffort: "medium"
            )
        )))["operation"] as? [String: Any])
        XCTAssertEqual(operation["type"] as? String, "generateCommitMessage")
        XCTAssertEqual(operation["include_unstaged"] as? Bool, true)
        XCTAssertEqual(operation["conventional_commits"] as? Bool, true)
        XCTAssertNil(operation["conventionalCommits"])
        let invocation = try XCTUnwrap(operation["invocation"] as? [String: Any])
        XCTAssertEqual(invocation["provider"] as? String, "claude")
        XCTAssertEqual(invocation["binary"] as? String, "/opt/claude")
        XCTAssertEqual(invocation["reasoning_effort"] as? String, "medium")
        XCTAssertNil(invocation["reasoningEffort"])
    }

    func testSurfaceWorkspaceResultsDecode() throws {
        var result = try JSONDecoder().decode(
            WorkspaceResult.self,
            from: Data(
                """
                {"type":"workingTree","entries":[{"relativePath":"src/limiter.rs",\
                "absolutePath":"/src/src/limiter.rs","name":"limiter.rs","isDir":false,\
                "expanded":false,"depth":1,"status":"modified"}]}
                """.utf8
            )
        )
        guard case .workingTree(let entries) = result else {
            return XCTFail("expected a workingTree result")
        }
        XCTAssertEqual(entries.first?.relativePath, "src/limiter.rs")
        XCTAssertEqual(entries.first?.status, .modified)

        result = try JSONDecoder().decode(
            WorkspaceResult.self,
            from: Data(#"{"type":"textFile","content":"fn main() {}\n"}"#.utf8)
        )
        guard case .textFile(let content) = result else {
            return XCTFail("expected a textFile result")
        }
        XCTAssertEqual(content, "fn main() {}\n")

        result = try JSONDecoder().decode(
            WorkspaceResult.self,
            from: Data(#"{"type":"commitMessage","message":"fix(limiter): refill continuously"}"#.utf8)
        )
        guard case .commitMessage(let message) = result else {
            return XCTFail("expected a commitMessage result")
        }
        XCTAssertEqual(message, "fix(limiter): refill continuously")

        result = try JSONDecoder().decode(
            WorkspaceResult.self,
            from: Data(
                """
                {"type":"reviewDiff","data":{"source":"uncommitted","numstat":"1\\t0\\ta.rs",\
                "patch":"diff --git a/a.rs b/a.rs\\n","completeContext":true}}
                """.utf8
            )
        )
        guard case .reviewDiff(let data) = result else {
            return XCTFail("expected a reviewDiff result")
        }
        // `ReviewDiffData` is a struct with `rename_all`, so this one is camel.
        XCTAssertTrue(data.completeContext)
        XCTAssertEqual(data.source, .uncommitted)

        result = try JSONDecoder().decode(
            WorkspaceResult.self,
            from: Data(
                """
                {"type":"commitSnapshot","snapshot":{"branch":"demo/rate-limiter","additions":11,\
                "deletions":6,"staged_additions":0,"staged_deletions":0,"has_staged":false,\
                "has_unstaged":true,"can_push":true}}
                """.utf8
            )
        )
        guard case .commitSnapshot(let snapshot) = result else {
            return XCTFail("expected a commitSnapshot result")
        }
        XCTAssertTrue(snapshot.canPush)
        XCTAssertTrue(snapshot.hasUnstaged)
    }

    func testSettingsSkillsAndUsageCommandsHaveStableWireKeys() throws {
        XCTAssertEqual(
            try json(Command.refreshBackgroundWork)["type"] as? String, "refreshBackgroundWork")

        var object = try json(Command.stopBackgroundWork(
            key: BackgroundWorkKey(kind: .process, providerId: "bash-7"), controlId: "7"
        ))
        XCTAssertEqual(object["type"] as? String, "stopBackgroundWork")
        XCTAssertEqual(object["controlId"] as? String, "7")
        let key = try XCTUnwrap(object["key"] as? [String: Any])
        XCTAssertEqual(key["kind"] as? String, "process")
        XCTAssertEqual(key["providerId"] as? String, "bash-7")

        object = try json(Command.loadUsageHistory(
            window: .trailingDays(30), projectRoots: ["/src/shidou"]))
        XCTAssertEqual(object["type"] as? String, "loadUsageHistory")
        XCTAssertEqual(object["projectRoots"] as? [String], ["/src/shidou"])
        let window = try XCTUnwrap(object["window"] as? [String: Any])
        XCTAssertEqual(window["trailingDays"] as? UInt32, 30)

        object = try json(Command.loadUsageHistory(window: .thisMonth, projectRoots: []))
        XCTAssertEqual(object["window"] as? String, "thisMonth")

        object = try json(Command.loadSkills(projects: [
            SkillProjectRoot(name: "shidou", root: "/src/shidou")
        ]))
        XCTAssertEqual(object["type"] as? String, "loadSkills")
        // A Rust tuple is a two-element array, not an object.
        XCTAssertEqual(object["projects"] as? [[String]], [["shidou", "/src/shidou"]])

        object = try json(Command.setSkillsEnabled(dirs: ["/skills/tdd"], enabled: false))
        XCTAssertEqual(object["type"] as? String, "setSkillsEnabled")
        XCTAssertEqual(object["dirs"] as? [String], ["/skills/tdd"])
        XCTAssertEqual(object["enabled"] as? Bool, false)

        object = try json(Command.trashSkills(dirs: ["/skills/tdd"]))
        XCTAssertEqual(object["type"] as? String, "trashSkills")
        XCTAssertEqual(object["dirs"] as? [String], ["/skills/tdd"])
    }

    /// The settings file is shared with the Mac app and the web client, so
    /// what the phone sends back has to carry the keys it never showed. A
    /// round trip that dropped `computer_use_allowed_apps` would let a toggle
    /// on the phone erase a grant made on the desktop.
    func testUpdateSettingsPreservesKeysThePhoneNeverShows() throws {
        let settings = try JSONDecoder().decode(
            DaemonSettings.self,
            from: Data(
                """
                {"computer_use_enabled":true,"computer_use_allowed_apps":[{"bundle_id":"com.apple.Safari"}],\
                "conventional_commit_messages":false,"disabled_providers":["codex"],\
                "provider_binary_overrides":{"claude":"/opt/claude"},"someFutureKey":42}
                """.utf8
            )
        )
        XCTAssertTrue(settings.computerUseEnabled)
        XCTAssertFalse(settings.isEnabled(.codex))
        XCTAssertEqual(settings.binaryOverride(for: .claude), "/opt/claude")

        var edited = settings
        edited.conventionalCommitMessages = true
        edited.setEnabled(true, for: .codex)
        edited.setBinaryOverride(nil, for: .claude)

        let object = try XCTUnwrap(
            try json(Command.updateSettings(edited))["settings"] as? [String: Any])
        XCTAssertEqual(object["conventional_commit_messages"] as? Bool, true)
        XCTAssertEqual(object["disabled_providers"] as? [String], [])
        XCTAssertEqual((object["provider_binary_overrides"] as? [String: String])?.isEmpty, true)
        XCTAssertEqual(object["someFutureKey"] as? Int, 42)
        XCTAssertNotNil(object["computer_use_allowed_apps"], "a desktop-only grant survives")
    }

    func testSkillsCatalogDecodes() throws {
        let payload = try JSONDecoder().decode(
            ResponsePayload.self,
            from: Data(
                """
                {"type":"skillsCatalog","catalog":{"skills":[{"name":"tdd",\
                "description":"Test first","scope":"user","project":null,\
                "installs":[{"source":"shared","dir":"/skills/tdd",\
                "skillFile":"/skills/tdd/SKILL.md","enabled":true},\
                {"source":{"provider":"claude"},"dir":"/claude/skills/tdd",\
                "skillFile":"/claude/skills/tdd/SKILL.md","enabled":false}],\
                "enabled":true,"allowedTools":null,"body":"# TDD","supportingFiles":2,\
                "totalBytes":4096,"modifiedAt":1700000000,"duplicates":0,"rowKey":17}]}}
                """.utf8
            )
        )
        guard case .skillsCatalog(let catalog) = payload else {
            return XCTFail("expected a skills catalog")
        }
        let skill = try XCTUnwrap(catalog.skills.first)
        XCTAssertEqual(skill.scope, .user)
        XCTAssertEqual(skill.supportingFiles, 2)
        XCTAssertEqual(skill.installs.first?.source, .shared)
        XCTAssertEqual(skill.installs.last?.source, .provider(.claude))
        XCTAssertEqual(skill.dirs, ["/skills/tdd", "/claude/skills/tdd"])
        XCTAssertEqual(catalog.disabledCount, 0)
    }

    func testUsageHistoryDecodes() throws {
        let payload = try JSONDecoder().decode(
            ResponsePayload.self,
            from: Data(
                """
                {"type":"usageHistory","history":{"window":{"trailingDays":7},\
                "sinceDay":"2026-08-22","untilDay":"2026-08-28",\
                "totals":{"uncachedInput":10,"cachedInput":20,"cacheCreation":5,"output":30,\
                "reasoning":4},"totalTokens":65,"costUsd":1.25,"records":9,"sessions":3,\
                "providers":[{"provider":"claude","costUsd":1.0,"totalTokens":50,\
                "costShare":0.8,"tokenShare":0.77}],\
                "models":[{"provider":"claude","model":"sonnet","costUsd":1.0,\
                "totalTokens":50,"costShare":0.8}],\
                "daily":[{"day":"2026-08-28","costUsd":0.5,"totalTokens":20,\
                "byProvider":[{"costUsd":0.5,"totalTokens":20},{"costUsd":0.0,"totalTokens":0}]}],\
                "months":[{"firstDay":"2026-08-01","costUsd":1.25,"totalTokens":65,\
                "byProvider":[{"costUsd":1.0,"totalTokens":50},{"costUsd":0.25,"totalTokens":15}],\
                "sessions":3,"activeDays":4,"topModels":[["sonnet",1.0]]}],\
                "projects":[{"path":"/src/shidou","costUsd":1.25,"totalTokens":65,\
                "byProvider":[{"costUsd":1.0,"totalTokens":50},{"costUsd":0.25,"totalTokens":15}],\
                "sessions":3,"costShare":1.0,"lastDay":"2026-08-28","topModels":[["sonnet",1.0]]}],\
                "quality":{"providerReportedShare":0.5,"modelPricedShare":0.5,\
                "unpricedShare":0.0,"cacheSavingsUsd":0.1},"pricing":"fresh",\
                "scannedFiles":12,"skippedFiles":0,"errors":[],\
                "scanDuration":{"secs":0,"nanos":12000}}}
                """.utf8
            )
        )
        guard case .usageHistory(let history) = payload else {
            return XCTFail("expected a usage history")
        }
        XCTAssertEqual(history.window, .trailingDays(7))
        XCTAssertEqual(history.sinceDay, CalendarDay(year: 2026, month: 8, day: 22))
        XCTAssertEqual(history.totals.total, 65)
        XCTAssertEqual(history.daily.first?.provider(.claude)?.totalTokens, 20)
        XCTAssertEqual(history.daily.first?.provider(.codex)?.totalTokens, 0)
        // A `Vec<(String, f64)>` is an array of pairs, not an object.
        XCTAssertEqual(history.months.first?.topModels.first?.model, "sonnet")
        XCTAssertEqual(history.projects.first?.name, "shidou")
        XCTAssertEqual(history.pricing, .fresh)
    }

    /// `BackgroundWorkEvent` is internally tagged, so `upsert` and
    /// `stopRequested` carry their payload's fields beside `type` rather than
    /// nesting them — the one shape a hand-written decoder gets wrong.
    func testBackgroundWorkEventsDecode() throws {
        var event = DriverEvent(wire: try JSONDecoder().decode(
            WireDriverEvent.self,
            from: Data(
                """
                {"kind":"backgroundWork","payload":{"type":"upsert",\
                "key":{"kind":"process","providerId":"bash-7"},"title":"cargo watch",\
                "detail":"running tests","command":"cargo watch -x test","cwd":"/src",\
                "output":"ok","outputTruncated":false,"startedAtMs":1000,"updatedAtMs":2000,\
                "durationMs":1000,"exitCode":null,"background":true,"canStop":true,\
                "controlId":"7","originActivityId":null,"role":null,"model":null,\
                "parentId":null,"status":"running"}}
                """.utf8
            )
        ))
        guard case .backgroundWork(.upsert(let item)) = event else {
            return XCTFail("expected an upsert")
        }
        XCTAssertEqual(item.key.providerId, "bash-7")
        XCTAssertEqual(item.title, "cargo watch")
        XCTAssertTrue(item.canStop)
        XCTAssertTrue(item.status.isStoppable)

        event = DriverEvent(wire: try JSONDecoder().decode(
            WireDriverEvent.self,
            from: Data(
                """
                {"kind":"backgroundWork","payload":{"type":"stopRequested",\
                "kind":"subagent","providerId":"reviewer-1"}}
                """.utf8
            )
        ))
        guard case .backgroundWork(.stopRequested(let key)) = event else {
            return XCTFail("expected a stopRequested")
        }
        XCTAssertEqual(key.kind, .subagent)
        XCTAssertEqual(key.providerId, "reviewer-1")

        event = DriverEvent(wire: try JSONDecoder().decode(
            WireDriverEvent.self,
            from: Data(
                """
                {"kind":"backgroundWork","payload":{"type":"reconcileLive","items":[]}}
                """.utf8
            )
        ))
        guard case .backgroundWork(.reconcileLive(let items)) = event else {
            return XCTFail("expected a reconcileLive")
        }
        XCTAssertTrue(items.isEmpty)

        event = DriverEvent(wire: try JSONDecoder().decode(
            WireDriverEvent.self,
            from: Data(
                """
                {"kind":"backgroundWork","payload":{"type":"outputDelta",\
                "key":{"kind":"process","providerId":"bash-7"},"delta":"more\\n"}}
                """.utf8
            )
        ))
        guard case .backgroundWork(.outputDelta(_, let delta)) = event else {
            return XCTFail("expected an outputDelta")
        }
        XCTAssertEqual(delta, "more\n")

        // A variant a newer daemon adds must not throw the whole event away.
        event = DriverEvent(wire: try JSONDecoder().decode(
            WireDriverEvent.self,
            from: Data(#"{"kind":"backgroundWork","payload":{"type":"somethingNew"}}"#.utf8)
        ))
        guard case .backgroundWork(.unknown(let type)) = event else {
            return XCTFail("expected an unknown background-work variant")
        }
        XCTAssertEqual(type, "somethingNew")
    }
}
