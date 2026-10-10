import Foundation
import Darwin
import XCTest
@testable import PiSwitchCore

final class AgentsTests: XCTestCase {
    private var directory: URL!
    private var store: AgentsStore!
    private var root: URL { directory.appendingPathComponent("library") }
    private var agent: URL { directory.appendingPathComponent("agent") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = AgentsStore(root: root, agentDirectory: agent)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func create(_ kind: AgentsCollection = .global, _ text: String = "v1") async throws -> UUID {
        let loaded = try await store.inspect()
        return try await store.create(kind, name: "名称", data: Data(text.utf8), expected: loaded.revision)
    }

    private func save(_ target: AgentTarget, _ text: String) async throws {
        let revision = try await store.inspect().revision
        let baseline = try await store.read(target)
        try await store.save(target, data: Data(text.utf8), baseline: baseline, expected: revision)
    }

    private func apply(_ id: UUID, allowExternal: Bool = false) async throws {
        let revision = try await store.inspect().revision
        let source = try await store.read(.entry(.global, id))
        let baseline = try await store.read(.global)
        try await store.applyGlobal(id, source: source, baseline: baseline, expected: revision, allowExternal: allowExternal)
    }

    private func project(_ name: String) async throws -> UUID {
        let path = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let revision = try await store.inspect().revision
        return try await store.addProject(path, expected: revision)
    }

    private func use(_ template: UUID, _ project: UUID) async throws {
        let revision = try await store.inspect().revision
        let source = try await store.read(.entry(.templates, template))
        let baseline = try await store.read(.project(project))
        try await store.useTemplate(template, projectId: project, source: source, baseline: baseline, expected: revision)
    }

    private func rejected(_ work: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await work(); XCTFail("Expected refusal", file: file, line: line) }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line) }
    }

    func testReadOnlyStartupAndGlobalSaveVersusApply() async throws {
        let loaded = try await store.inspect()
        XCTAssertNil(loaded.revision.data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let id = try await create()
        let missing = try await store.read(.global)
        XCTAssertNil(missing.data)
        try await apply(id)
        let first = try await store.read(.global)
        XCTAssertEqual(first.text, "v1")
        XCTAssertEqual(first.permissions, 0o600)
        let type = try FileManager.default.attributesOfItem(atPath: store.globalURL.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeRegular)
        try await save(.entry(.global, id), "v2")
        let unchanged = try await store.read(.global)
        XCTAssertEqual(unchanged.text, "v1")
        try await apply(id)
        let updated = try await store.read(.global)
        let backup = try await store.backup(.global)
        XCTAssertEqual(updated.text, "v2")
        XCTAssertEqual(backup?.text, "v1")
        let state = try await store.inspect().state
        XCTAssertEqual(state.activeGlobal?.versionId, id)
        XCTAssertEqual(state.activeGlobal?.appliedHash, updated.hash)
    }

    func testImportPreservesBytesAndOriginalIdentity() async throws {
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("# 全局\r\n".utf8)
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try bytes.write(to: store.globalURL)
        let before = try await store.read(.global)
        let revision = try await store.inspect().revision
        let id = try await store.importGlobal(name: "导入", baseline: before, expected: revision)
        let after = try await store.read(.global)
        let imported = try await store.read(.entry(.global, id))
        XCTAssertEqual(after, before)
        XCTAssertEqual(imported.data, bytes)
        let active = try await store.inspect().state.activeGlobal
        XCTAssertEqual(active?.versionId, id)
    }

    func testIndependentProjectsTemplateEditAndDeletion() async throws {
        let template = try await create(.templates, "template v1")
        let a = try await project("a"), b = try await project("b")
        try await use(template, a); try await use(template, b)
        let initial = try await store.read(.project(a))
        XCTAssertEqual(initial.permissions, 0o644)
        try await save(.project(a), "a customized")
        try await save(.entry(.templates, template), "template v2")
        let currentA = try await store.read(.project(a)), currentB = try await store.read(.project(b))
        XCTAssertEqual(currentA.text, "a customized"); XCTAssertEqual(currentB.text, "template v1")
        let revision = try await store.inspect().revision
        let baseline = try await store.read(.entry(.templates, template))
        try await store.deleteEntry(.templates, id: template, baseline: baseline, expected: revision)
        let state = try await store.inspect().state
        XCTAssertTrue(state.templates.isEmpty)
        XCTAssertEqual(state.projects.first { $0.id == a }?.origin?.templateName, "名称")
        let retained = try await store.read(.project(a))
        XCTAssertEqual(retained.text, "a customized")
        let removeRevision = try await store.inspect().revision
        let path = try await store.path(.project(a))
        try await store.removeProject(a, expected: removeRevision)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "a customized")
    }

    func testExternalGlobalEditNeedsExplicitConsentAndIsBackedUp() async throws {
        let a = try await create(), b = try await create(.global, "other")
        try await apply(a)
        try write("external", to: store.globalURL)
        await rejected { try await self.apply(b) }
        XCTAssertEqual(try String(contentsOf: store.globalURL, encoding: .utf8), "external")
        try await apply(b, allowExternal: true)
        let backup = try await store.backup(.global)
        XCTAssertEqual(backup?.text, "external")
    }

    func testContentIdentityPermissionAndStateConflicts() async throws {
        let id = try await create()
        let target = AgentTarget.entry(.global, id)
        let revision = try await store.inspect().revision
        let baseline = try await store.read(target)
        let path = try await store.path(target)
        try write("external", to: path)
        await rejected { try await self.store.save(target, data: Data("mine".utf8), baseline: baseline, expected: revision) }
        try write("v1", to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path.path)
        await rejected { try await self.store.save(target, data: Data("mine".utf8), baseline: baseline, expected: revision) }
        try FileManager.default.removeItem(at: path)
        try write("v1", to: path)
        await rejected { try await self.store.save(target, data: Data("mine".utf8), baseline: baseline, expected: revision) }
        let fresh = try await store.read(target)
        _ = try await create(.global, "another")
        await rejected { try await self.store.save(target, data: Data("mine".utf8), baseline: fresh, expected: revision) }
    }

    func testMissingTargetAppearingAndMissingProjectDirectoryRefused() async throws {
        let p = try await project("project")
        let revision = try await store.inspect().revision
        let empty = try await store.read(.project(p))
        let path = try await store.path(.project(p))
        try write("external", to: path)
        await rejected { try await self.store.save(.project(p), data: Data("mine".utf8), baseline: empty, expected: revision) }
        try FileManager.default.removeItem(at: path.deletingLastPathComponent())
        await rejected { try await self.store.save(.project(p), data: Data("mine".utf8), baseline: empty, expected: revision) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path))
    }

    func testRestoreRotatesAndPreservesPermissions() async throws {
        let p = try await project("project")
        let path = try await store.path(.project(p))
        try write("v1", to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path.path)
        try await save(.project(p), "v2"); try await save(.project(p), "v3")
        let old = try await store.backup(.project(p))
        XCTAssertEqual(old?.text, "v2")
        let revision = try await store.inspect().revision
        let baseline = try await store.read(.project(p))
        try await store.restore(.project(p), baseline: baseline, expected: revision)
        let restored = try await store.read(.project(p)), backup = try await store.backup(.project(p))
        XCTAssertEqual(restored.text, "v2"); XCTAssertEqual(restored.permissions, 0o640)
        XCTAssertEqual(backup?.text, "v3")
    }

    func testCandidateChainOverrideEmptyFileAndClaudeFallback() async throws {
        let p = try await project("parent/project")
        let cwd = try await store.path(.project(p)).deletingLastPathComponent()
        try write("global", to: store.globalURL)
        try write("parent", to: cwd.deletingLastPathComponent().appendingPathComponent("AGENTS.md"))
        try write("claude", to: cwd.appendingPathComponent("CLAUDE.md"))
        let before = await store.contextChain(cwd: cwd).compactMap(\.selectedPath)
        XCTAssertEqual(before.suffix(3), [store.globalURL.path, cwd.deletingLastPathComponent().appendingPathComponent("AGENTS.md").path, cwd.appendingPathComponent("CLAUDE.md").path])
        let template = try await create(.templates)
        try await use(template, p)
        let after = await store.contextChain(cwd: cwd).last!
        XCTAssertEqual(after.selectedPath, cwd.appendingPathComponent("AGENTS.md").path)
        XCTAssertTrue(after.otherPaths.contains(cwd.appendingPathComponent("CLAUDE.md").path))
        try write("", to: cwd.appendingPathComponent("AGENTS.override.md"))
        await rejected { try await self.use(template, p) }
        let masked = await store.contextChain(cwd: cwd).last!
        XCTAssertEqual(masked.selectedPath, cwd.appendingPathComponent("AGENTS.override.md").path)
        let id = try await create()
        try write("", to: agent.appendingPathComponent("AGENTS.override.md"))
        await rejected { try await self.apply(id) }
    }

    func testLinksDirectoriesHardLinksAttributesAndInvalidTextRefused() async throws {
        let id = try await create()
        let path = try await store.path(.entry(.global, id))
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: store.globalURL, withDestinationURL: path)
        await rejected { _ = try await self.store.read(.global) }
        try FileManager.default.removeItem(at: store.globalURL)
        try FileManager.default.createDirectory(at: store.globalURL, withIntermediateDirectories: false)
        await rejected { _ = try await self.store.read(.global) }
        try FileManager.default.removeItem(at: store.globalURL)
        try FileManager.default.linkItem(at: path, to: store.globalURL)
        await rejected { _ = try await self.store.read(.global) }
        try FileManager.default.removeItem(at: store.globalURL)
        let value: [UInt8] = [1]
        XCTAssertEqual(setxattr(path.path, "user.agents-test", value, 1, 0, 0), 0)
        await rejected { _ = try await self.store.read(.entry(.global, id)) }
        XCTAssertEqual(removexattr(path.path, "user.agents-test", 0), 0)
        for invalid in [Data([0xff]), Data([0]), Data(repeating: 65, count: AgentsStore.maxFileBytes + 1)] {
            let revision = try await store.inspect().revision
            await rejected { _ = try await self.store.create(.global, name: "bad", data: invalid, expected: revision) }
        }
        let revision = try await store.inspect().revision
        await rejected { try await self.store.save(.entry(.global, UUID()), data: Data(), name: "bad", baseline: try await self.store.read(.entry(.global, id)), expected: revision) }
    }

    func testCorruptAndUnsupportedStateNeverResetAndStorageLinksRefused() async throws {
        let id = try await create()
        let path = try await store.path(.entry(.global, id))
        let original = try Data(contentsOf: store.stateURL)
        for text in ["{", "{\"version\":2}"] {
            try write(text, to: store.stateURL)
            await rejected { _ = try await self.store.inspect() }
            XCTAssertEqual(try String(contentsOf: store.stateURL, encoding: .utf8), text)
        }
        try original.write(to: store.stateURL)
        let external = directory.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let globals = path.deletingLastPathComponent()
        try FileManager.default.removeItem(at: globals)
        try FileManager.default.createSymbolicLink(at: globals, withDestinationURL: external)
        await rejected { _ = try await self.store.read(.entry(.global, id)) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
    }

    func testActiveDeletionRefusedAndDetachPreservesGlobal() async throws {
        let id = try await create(); try await apply(id)
        let baseline = try await store.read(.entry(.global, id))
        let revision = try await store.inspect().revision
        await rejected { try await self.store.deleteEntry(.global, id: id, baseline: baseline, expected: revision) }
        try await store.detachGlobal(expected: revision)
        let actual = try await store.read(.global)
        XCTAssertEqual(actual.text, "v1")
    }

    func testBackupTamperingAndUnknownStagingPreserved() async throws {
        let id = try await create(); try await save(.entry(.global, id), "v2")
        let backup = root.appendingPathComponent("agents/backups/\(id.uuidString)/content.md")
        try write("tampered", to: backup)
        await rejected { try await self.save(.entry(.global, id), "v3") }
        let current = try await store.read(.entry(.global, id))
        XCTAssertEqual(current.text, "v2")
        let unknown = root.appendingPathComponent("agents/staging/unknown/keep.md")
        try write("keep", to: unknown)
        let loaded = try await store.inspect()
        XCTAssertFalse(loaded.warnings.isEmpty)
        XCTAssertEqual(try String(contentsOf: unknown, encoding: .utf8), "keep")
    }

    func testInjectedFailuresPreserveTargetStateAndPreviousBackup() async throws {
        let id = try await create(); try await apply(id)
        try await save(.entry(.global, id), "v2"); try await apply(id)
        try await save(.entry(.global, id), "v3")
        let originalState = try Data(contentsOf: store.stateURL)
        for failure in [AgentsStoreStep.backup, .replace, .writeState] {
            let failing = AgentsStore(root: root, agentDirectory: agent) { point in
                if point == failure { throw AgentsError("injected") }
            }
            let revision = try await failing.inspect().revision
            let source = try await failing.read(.entry(.global, id)), baseline = try await failing.read(.global)
            await rejected { try await failing.applyGlobal(id, source: source, baseline: baseline, expected: revision) }
            let current = try await failing.read(.global), backup = try await failing.backup(.global)
            XCTAssertEqual(current.text, "v2"); XCTAssertEqual(backup?.text, "v1")
            XCTAssertEqual(try Data(contentsOf: store.stateURL), originalState)
        }
    }

    func testFailedStateWriteDoesNotOverwriteConcurrentTargetAndReportsRecovery() async throws {
        let id = try await create(); try await apply(id); try await save(.entry(.global, id), "v2")
        let destination = store.globalURL
        let failing = AgentsStore(root: root, agentDirectory: agent) { point in
            if point == .writeState { try Data("external".utf8).write(to: destination); throw AgentsError("injected") }
        }
        let revision = try await failing.inspect().revision
        let source = try await failing.read(.entry(.global, id)), baseline = try await failing.read(.global)
        do { try await failing.applyGlobal(id, source: source, baseline: baseline, expected: revision); XCTFail("Expected failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("恢复材料")) }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "external")
        let warnings = try await failing.inspect().warnings
        XCTAssertFalse(warnings.isEmpty)
    }

    func testFarFutureTimestampDoesNotOverflowSnapshot() async throws {
        let id = try await create()
        let path = try await store.path(.entry(.global, id))
        let times = [timeval(tv_sec: 32_503_680_000, tv_usec: 0), timeval(tv_sec: 32_503_680_000, tv_usec: 0)]
        XCTAssertEqual(times.withUnsafeBufferPointer { utimes(path.path, $0.baseAddress) }, 0)
        let file = try await store.read(.entry(.global, id))
        XCTAssertEqual(file.text, "v1")
        XCTAssertNotNil(file.modificationTime)
    }

    func testSourcePreviewConflictAndGlobalRestoreClearsAssociation() async throws {
        let id = try await create(); try await apply(id)
        let source = try await store.read(.entry(.global, id))
        let baseline = try await store.read(.global)
        let path = try await store.path(.entry(.global, id))
        let revision = try await store.inspect().revision
        try write("external source", to: path)
        await rejected { try await self.store.applyGlobal(id, source: source, baseline: baseline, expected: revision) }
        let unchanged = try await store.read(.global)
        XCTAssertEqual(unchanged.text, "v1")
        try await apply(id)
        let fresh = try await store.inspect().revision
        let current = try await store.read(.global)
        try await store.restore(.global, baseline: current, expected: fresh)
        let restored = try await store.read(.global), state = try await store.inspect().state
        XCTAssertEqual(restored.text, "v1")
        XCTAssertNil(state.activeGlobal)
    }

    func testProjectAliasesImportPathAndACLRefusal() async throws {
        let p = try await project("actual")
        let path = try await store.path(.project(p))
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: path.deletingLastPathComponent())
        let revision = try await store.inspect().revision
        let same = try await store.addProject(alias, expected: revision)
        XCTAssertEqual(p, same)
        try write("original", to: path)
        let imported = try await store.importFile(path)
        XCTAssertEqual(imported.text, "original")
        let chmod = Process(); chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "\(NSUserName()) allow read", path.path]
        try chmod.run(); chmod.waitUntilExit()
        XCTAssertEqual(chmod.terminationStatus, 0)
        await rejected { _ = try await self.store.read(.project(p)) }
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "original")
    }

    func testConcurrentTargetCreationDuringReplaceKeepsExternalContent() async throws {
        let id = try await create()
        let destination = store.globalURL
        let failing = AgentsStore(root: root, agentDirectory: agent) { point in
            if point == .replace { try Data("external new file".utf8).write(to: destination) }
        }
        let revision = try await failing.inspect().revision
        let source = try await failing.read(.entry(.global, id)), baseline = try await failing.read(.global)
        await rejected { try await failing.applyGlobal(id, source: source, baseline: baseline, expected: revision) }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "external new file")
        let state = try await failing.inspect().state
        XCTAssertNil(state.activeGlobal)
    }

    func testCleanupFailureReportsSuccessWithRetainedMaterials() async throws {
        let id = try await create()
        let failing = AgentsStore(root: root, agentDirectory: agent) { point in
            if point == .cleanup { throw AgentsError("injected cleanup") }
        }
        let revision = try await failing.inspect().revision
        let source = try await failing.read(.entry(.global, id)), baseline = try await failing.read(.global)
        try await failing.applyGlobal(id, source: source, baseline: baseline, expected: revision)
        let loaded = try await failing.inspect()
        XCTAssertEqual(loaded.state.activeGlobal?.versionId, id)
        XCTAssertFalse(loaded.warnings.isEmpty)
    }
}
