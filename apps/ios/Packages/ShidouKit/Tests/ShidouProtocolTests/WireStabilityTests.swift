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
}
