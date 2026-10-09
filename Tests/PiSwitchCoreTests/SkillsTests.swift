import XCTest
@testable import PiSwitchCore

final class SkillsTests: XCTestCase {
    func testRepositoryAddress() throws {
        XCTAssertEqual(try SkillRepositoryAddress("https://github.com/Owner/Repo.git/").slug, "owner/repo")
        for input in ["https://evil.test/o/r", "https://github.com/o/r/tree/main", "https://u:p@github.com/o/r", "https://github.com/o/.."] {
            XCTAssertThrowsError(try SkillRepositoryAddress(input), input)
        }
    }

    func testFrontmatter() throws {
        let metadata = try SkillMetadata.parse(Data("""
        ---
        name: test-skill
        description: >-
          Supports quoted values
          and multiple lines.
        metadata:
          other: value
        ---
        # Instructions
        """.utf8))
        XCTAssertEqual(metadata.name, "test-skill")
        XCTAssertEqual(metadata.description, "Supports quoted values and multiple lines.")
        for description in ["123", "true", "[x]"] {
            XCTAssertThrowsError(try SkillMetadata.parse(Data("---\nname: test\ndescription: \(description)\n---\n".utf8)))
        }
        let on = try SkillMetadata.parse(Data("---\nname: on\ndescription: off\n---\n".utf8))
        XCTAssertEqual(on.description, "off")
        XCTAssertThrowsError(try SkillMetadata.parse(Data("---\nname: test\nname: other\ndescription: x\n---\n".utf8)))
        XCTAssertThrowsError(try SkillMetadata.parse(Data("---\nname: test\n---\n".utf8)))
        XCTAssertThrowsError(try SkillMetadata.parse(Data("---\nname: ../test\ndescription: x\n---\n".utf8)))
    }

    func testPaths() throws {
        for path in ["../file", "/absolute", "a/../b", "a//b", "a\\b"] {
            XCTAssertThrowsError(try SkillSafety.validatePath(path), path)
        }
        XCTAssertNoThrow(try SkillSafety.validatePath("scripts/run.sh"))
    }
}

private final class SkillFault: @unchecked Sendable {
    private let lock = NSLock()
    private var step: SkillStoreStep?
    func set(_ step: SkillStoreStep?) { lock.lock(); defer { lock.unlock() }; self.step = step }
    func check(_ value: SkillStoreStep) throws {
        lock.lock(); defer { lock.unlock() }
        if step == value { throw SkillError("injected \(value)") }
    }
}

extension SkillsTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PiSwitchSkills-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixture(_ version: Int = 1, name: String = "test-skill", repository: String = "owner/repo") throws -> SkillDownload {
        let files = ["SKILL.md": Data("---\nname: \(name)\ndescription: version \(version)\n---\nInstructions\n".utf8),
                     "scripts/run.sh": Data("#!/bin/sh\necho \(version)\n".utf8)]
        let entries = files.map { path, data in
            SkillTreeEntry(path: "skills/test/" + path, mode: path.hasSuffix(".sh") ? "100755" : "100644", type: "blob", sha: SkillSafety.blobSHA(data), size: data.count)
        }
        let snapshot = SkillRepositorySnapshot(repository: try SkillRepositoryAddress("https://github.com/" + repository),
            commit: String(repeating: "a", count: 39) + String(version), entries: entries)
        return SkillDownload(snapshot: snapshot, path: "skills/test", metadata: try SkillMetadata.parse(files["SKILL.md"]!), files: files)
    }

    func testInstallConflictAndExecutionPermissions() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("library")
        let store = SkillStore(root: root, home: directory)
        let download = try fixture()
        _ = try await store.install(download)
        let inspection = try await store.inspect()
        XCTAssertEqual(inspection.library.skills.count, 1)
        XCTAssertEqual(inspection.localChanges.values.first, [])
        XCTAssertEqual(inspection.library.skills[0].scopes, [])
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("skills/test-skill/scripts/run.sh").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        do { _ = try await store.install(download); XCTFail("Duplicate installed") } catch {}
        do { _ = try await store.install(fixture(repository: "different/repo")); XCTFail("Name conflict installed") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".pi").path))
    }

    func testSingleBackupRotationAndNoOp() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("library")
        let store = SkillStore(root: root, home: directory)
        _ = try await store.install(fixture())
        let installed = try await store.inspect().library.skills[0]
        _ = try await store.update(installed.id, with: fixture(2))
        let backupRecordURL = root.appendingPathComponent("backups/test-skill/record.json")
        let backup1 = try Data(contentsOf: backupRecordURL)
        XCTAssertEqual(try JSONDecoder().decode(InstalledSkill.self, from: backup1).commit, installed.commit)
        _ = try await store.update(installed.id, with: fixture(2))
        XCTAssertEqual(try Data(contentsOf: backupRecordURL), backup1)
        _ = try await store.update(installed.id, with: fixture(3))
        let backup2 = try JSONDecoder().decode(InstalledSkill.self, from: Data(contentsOf: backupRecordURL))
        XCTAssertEqual(backup2.commit, try fixture(2).snapshot.commit)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("backups").path), ["test-skill"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("staging").path), [])
        let current = try await store.inspect().library.skills[0]
        XCTAssertEqual(current.commit, try fixture(3).snapshot.commit)
    }

    func testLocalChangesSkipAndRecheckBeforeReplace() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("library")
        let script = root.appendingPathComponent("skills/test-skill/scripts/run.sh")
        let store = SkillStore(root: root, home: directory)
        _ = try await store.install(fixture())
        let installed = try await store.inspect().library.skills[0]
        try Data("user content".utf8).write(to: script)
        let changes = try await store.localChanges(installed)
        XCTAssertEqual(changes, ["变化：scripts/run.sh"])
        do { _ = try await store.update(installed.id, with: fixture(2)); XCTFail("Overwrote local edit") } catch {}
        XCTAssertEqual(try String(contentsOf: script, encoding: .utf8), "user content")
        let clean = try fixture().files["scripts/run.sh"]!
        try clean.write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)
        let permissions = try await store.localChanges(installed)
        XCTAssertEqual(permissions, ["变化：scripts/run.sh"])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let racingStore = SkillStore(root: root, home: directory, before: { step in
            if step == .replace { try Data("racing edit".utf8).write(to: script) }
        })
        do { _ = try await racingStore.update(installed.id, with: fixture(2)); XCTFail("Missed final check") } catch {}
        XCTAssertEqual(try String(contentsOf: script, encoding: .utf8), "racing edit")
        let state = try await store.inspect().library.skills[0]
        XCTAssertEqual(state.commit, installed.commit)
    }

    func testUpdateFailuresKeepCurrentAndPreviousBackup() async throws {
        for step in [SkillStoreStep.prepare, .backup, .replace, .writeState] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let root = directory.appendingPathComponent("library")
            let fault = SkillFault()
            let store = SkillStore(root: root, home: directory, before: { try fault.check($0) })
            _ = try await store.install(fixture())
            let id = try await store.inspect().library.skills[0].id
            _ = try await store.update(id, with: fixture(2))
            let before = try Data(contentsOf: root.appendingPathComponent("skills-state.json"))
            let backup = try Data(contentsOf: root.appendingPathComponent("backups/test-skill/record.json"))
            fault.set(step)
            do { _ = try await store.update(id, with: fixture(3)); XCTFail("Injected failure succeeded: \(step)") } catch {}
            fault.set(nil)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("skills-state.json")), before)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("backups/test-skill/record.json")), backup)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("skills/test-skill/SKILL.md")), try fixture(2).files["SKILL.md"])
        }
    }

    func testCleanupFailureReportedAndRetried() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = SkillFault()
        let store = SkillStore(root: directory.appendingPathComponent("library"), home: directory, before: { try fault.check($0) })
        _ = try await store.install(fixture())
        let id = try await store.inspect().library.skills[0].id
        _ = try await store.update(id, with: fixture(2))
        fault.set(.cleanup)
        let result = try await store.update(id, with: fixture(3))
        XCTAssertTrue(result.contains("清理未完成"))
        let dirty = try await store.inspect()
        XCTAssertEqual(dirty.library.pendingCleanup.count, 1)
        XCTAssertEqual(dirty.library.skills[0].commit, try fixture(3).snapshot.commit)
        fault.set(nil)
        let clean = try await store.inspect()
        XCTAssertEqual(clean.library.pendingCleanup, [])
        XCTAssertEqual(clean.warnings, [])
    }

    func testScopesAndExternalEntryProtection() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let fault = SkillFault()
        let root = directory.appendingPathComponent("library")
        let store = SkillStore(root: root, home: directory, before: { try fault.check($0) })
        _ = try await store.install(fixture())
        let id = try await store.inspect().library.skills[0].id
        try await store.addProject(project)
        try await store.setScopes([SkillStore.globalScope], for: id)
        let global = directory.appendingPathComponent(".pi/agent/skills/test-skill")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: global.path), root.appendingPathComponent("skills/test-skill").path)
        fault.set(.writeState)
        do { try await store.setScopes([project.path], for: id); XCTFail("Scope write succeeded") } catch {}
        fault.set(nil)
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: global.path))
        try await store.setScopes([project.path], for: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: global.path))
        let link = project.appendingPathComponent(".pi/skills/test-skill")
        XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/nonexistent/external")
        do { try await store.setScopes([], for: id); XCTFail("Deleted external link") } catch {}
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "/nonexistent/external")
        let inspected = try await store.inspect()
        XCTAssertNotNil(inspected.scopeProblems[id]?[project.path])
        try FileManager.default.removeItem(at: link)
        try await store.setScopes([], for: id)
        try Data("occupied".utf8).write(to: global)
        do { try await store.setScopes([SkillStore.globalScope], for: id); XCTFail("Overwrote occupied entry") } catch {}
        XCTAssertEqual(try String(contentsOf: global, encoding: .utf8), "occupied")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("skills/test-skill/SKILL.md").path))
    }

    func testCorruptStateAndSymlinkStorageRefused() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("library")
        let store = SkillStore(root: root, home: directory)
        _ = try await store.install(fixture())
        let state = root.appendingPathComponent("skills-state.json")
        try Data("broken".utf8).write(to: state)
        do { _ = try await store.inspect(); XCTFail("Reset corrupt state") } catch {}
        do { _ = try await store.install(fixture(name: "other")); XCTFail("Wrote through corrupt state") } catch {}
        XCTAssertEqual(try String(contentsOf: state, encoding: .utf8), "broken")
        let external = directory.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let linkedRoot = directory.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: external)
        let linked = SkillStore(root: linkedRoot, home: directory)
        do { _ = try await linked.install(fixture()); XCTFail("Wrote through storage symlink") } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
    }

    func testFingerprintIgnoresUnrelatedFilesAndRejectsCaseCollisions() throws {
        let download = try fixture()
        let unrelated = SkillTreeEntry(path: "other/file", mode: "100644", type: "blob", sha: String(repeating: "b", count: 40), size: 1)
        let expanded = SkillRepositorySnapshot(repository: download.snapshot.repository, commit: String(repeating: "b", count: 40), entries: download.snapshot.entries + [unrelated])
        XCTAssertEqual(try download.snapshot.fingerprint(in: download.path), try expanded.fingerprint(in: download.path))
        let conflicting = SkillTreeEntry(path: "skills/test/Scripts/other", mode: "100644", type: "blob", sha: unrelated.sha, size: 1)
        let bad = SkillRepositorySnapshot(repository: expanded.repository, commit: expanded.commit, entries: expanded.entries + [conflicting])
        XCTAssertThrowsError(try bad.files(in: download.path))
        let symlink = SkillTreeEntry(path: "skills/test/link", mode: "120000", type: "blob", sha: unrelated.sha, size: 1)
        let linked = SkillRepositorySnapshot(repository: expanded.repository, commit: expanded.commit, entries: download.snapshot.entries + [symlink])
        XCTAssertThrowsError(try linked.files(in: download.path))
    }
}

extension SkillsTests {
    func testMultipleProjectsAndUpdatePreserveLinks() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projects = [directory.appendingPathComponent("one"), directory.appendingPathComponent("two")]
        let root = directory.appendingPathComponent("library")
        let store = SkillStore(root: root, home: directory)
        _ = try await store.install(fixture())
        let skill = try await store.inspect().library.skills[0]
        for project in projects {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
            try await store.addProject(project)
        }
        try await store.setScopes(projects.map(\.path), for: skill.id)
        _ = try await store.update(skill.id, with: fixture(2))
        for project in projects {
            let link = project.appendingPathComponent(".pi/skills/test-skill")
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), root.appendingPathComponent("skills/test-skill").path)
        }
        let current = try await store.inspect().library.skills[0]
        XCTAssertEqual(Set(current.scopes), Set(projects.map(\.path)))
        try FileManager.default.removeItem(at: root.appendingPathComponent("skills/test-skill/SKILL.md"))
        let broken = try await store.inspect()
        for project in projects { XCTAssertNotNil(broken.scopeProblems[skill.id]?[project.path]) }
    }

    func testNameCollisionAndLocalAddedDeletedFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("library")
        let store = SkillStore(root: root, home: directory)
        _ = try await store.install(fixture())
        let skill = try await store.inspect().library.skills[0]
        let foreign = directory.appendingPathComponent(".pi/agent/skills/different-folder")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try fixture().files["SKILL.md"]!.write(to: foreign.appendingPathComponent("SKILL.md"))
        do { try await store.setScopes([SkillStore.globalScope], for: skill.id); XCTFail("Enabled duplicate declared name") } catch { XCTAssertTrue(error.localizedDescription.contains("同名")) }
        let current = root.appendingPathComponent("skills/test-skill")
        try Data("new".utf8).write(to: current.appendingPathComponent("added"))
        try FileManager.default.removeItem(at: current.appendingPathComponent("scripts/run.sh"))
        let changes = try await store.localChanges(skill)
        XCTAssertTrue(changes.contains("新增：added"))
        XCTAssertTrue(changes.contains("删除：scripts/run.sh"))
    }

    func testInterruptedStagingNotDeletedAndBackupChangesRefused() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("library")
        let store = SkillStore(root: root, home: directory)
        _ = try await store.install(fixture())
        let skill = try await store.inspect().library.skills[0]
        _ = try await store.update(skill.id, with: fixture(2))
        let orphan = root.appendingPathComponent("staging/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
        let inspection = try await store.inspect()
        XCTAssertTrue(inspection.warnings.contains(where: { $0.contains("未完成") }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
        let backupFile = root.appendingPathComponent("backups/test-skill/files/SKILL.md")
        try Data("user backup edit".utf8).write(to: backupFile)
        do { _ = try await store.update(skill.id, with: fixture(3)); XCTFail("Overwrote altered backup") } catch {}
        XCTAssertEqual(try String(contentsOf: backupFile, encoding: .utf8), "user backup edit")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("skills/test-skill/SKILL.md")), try fixture(2).files["SKILL.md"])
    }
}
