import Foundation

public enum SkillStoreStep: Equatable, Sendable { case prepare, backup, replace, writeState, cleanup }

public actor SkillStore {
    public static let globalScope = "@global"
    public let root: URL
    public let home: URL
    private let fm = FileManager.default
    private let before: @Sendable (SkillStoreStep) throws -> Void

    public init(root: URL? = nil, home: URL? = nil, before: @escaping @Sendable (SkillStoreStep) throws -> Void = { _ in }) {
        self.home = (home ?? FileManager.default.homeDirectoryForCurrentUser).standardizedFileURL.resolvingSymlinksInPath()
        self.root = (root ?? self.home.appendingPathComponent("PiSwitch")).standardizedFileURL
        self.before = before
    }

    private var stateURL: URL { root.appendingPathComponent("skills-state.json") }
    private var skillsURL: URL { root.appendingPathComponent("skills") }
    private var stagingURL: URL { root.appendingPathComponent("staging") }
    private var backupsURL: URL { root.appendingPathComponent("backups") }

    public func inspect() throws -> SkillInspection {
        var warnings = try retryCleanup()
        let (library, _) = try load()
        var changes: [String: [String]] = [:]
        var problems: [String: [String: String]] = [:]
        for skill in library.skills {
            do { changes[skill.id] = try localChanges(skill) }
            catch { changes[skill.id] = [error.localizedDescription] }
            for scope in skill.scopes {
                do { try validateLink(skill, scope: scope, required: true) }
                catch { problems[skill.id, default: [:]][scope] = error.localizedDescription }
            }
        }
        if let type = try itemType(stagingURL) {
            guard type == .typeDirectory else { throw SkillError("暂存目录被占用：\(stagingURL.path)") }
            let pending = Set(library.pendingCleanup)
            // ponytail: no crash journal; keep unknown staging until explicit crash recovery is implemented.
            for child in try fm.contentsOfDirectory(at: stagingURL, includingPropertiesForKeys: nil) where !pending.contains(child.lastPathComponent) {
                warnings.append("发现未完成的操作目录，未自动删除，请检查：\(child.path)")
            }
        }
        warnings += library.pendingCleanup.map { "备份或暂存清理未完成：\(stagingURL.appendingPathComponent($0).path)" }
        return SkillInspection(library: library, localChanges: changes, scopeProblems: problems, warnings: warnings)
    }

    public func additionProblem(name: String, repository: SkillRepositoryAddress, path: String) throws -> String? {
        let (library, _) = try load()
        if let existing = library.skills.first(where: { $0.repository == repository && $0.sourcePath == path }) { return "已添加：\(existing.name)" }
        if let existing = library.skills.first(where: { $0.name.lowercased() == name.lowercased() }) { return "同名来源冲突：\(existing.repository.url)/\(existing.sourcePath)" }
        if try itemType(skillsURL.appendingPathComponent(name)) != nil { return "安装目录被占用：\(skillsURL.appendingPathComponent(name).path)" }
        return nil
    }

    @discardableResult
    public func install(_ download: SkillDownload) throws -> String {
        try validateDownload(download)
        if let problem = try additionProblem(name: download.metadata.name, repository: download.snapshot.repository, path: download.path) { throw SkillError(problem) }
        var (library, revision) = try load()
        try prepareRoot()
        let transaction = try makeTransaction()
        let prepared = transaction.appendingPathComponent("new")
        let current = skillsURL.appendingPathComponent(download.metadata.name)
        var moved = false
        do {
            let baseline = try prepare(download, at: prepared)
            guard try itemType(current) == nil else { throw SkillError("安装目录已被占用：\(current.path)") }
            try before(.replace)
            try fm.moveItem(at: prepared, to: current)
            moved = true
            library.skills.append(InstalledSkill(id: UUID().uuidString, name: download.metadata.name, description: download.metadata.description,
                repository: download.snapshot.repository, sourcePath: download.path, commit: download.snapshot.commit,
                sourceFingerprint: try download.snapshot.fingerprint(in: download.path), baseline: baseline, scopes: []))
            library.pendingCleanup.append(transaction.lastPathComponent)
            try save(library, expected: revision)
        } catch {
            var failures: [String] = []
            if moved { do { try fm.moveItem(at: current, to: prepared) } catch { failures.append(error.localizedDescription) } }
            if failures.isEmpty { do { try fm.removeItem(at: transaction) } catch { failures.append(error.localizedDescription) } }
            throw failure(error, transaction: transaction, recovery: failures)
        }
        return try finishCleanup(transaction)
    }

    @discardableResult
    public func update(_ id: String, with download: SkillDownload) throws -> String {
        try validateDownload(download)
        var (library, revision) = try load()
        guard let index = library.skills.firstIndex(where: { $0.id == id }) else { throw SkillError("skill 已不在技能库中。") }
        let old = library.skills[index]
        guard old.repository == download.snapshot.repository, old.sourcePath == download.path else { throw SkillError("更新来源不一致。") }
        let changes = try localChanges(old)
        guard changes.isEmpty else { throw SkillError("已跳过本地修改：\n" + changes.joined(separator: "\n")) }
        let fingerprint = try download.snapshot.fingerprint(in: download.path)
        guard fingerprint != old.sourceFingerprint else { return "已是最新。" }
        try prepareRoot()
        let transaction = try makeTransaction()
        let prepared = transaction.appendingPathComponent("new")
        let snapshot = transaction.appendingPathComponent("backup")
        let retired = transaction.appendingPathComponent("old-current")
        let older = transaction.appendingPathComponent("previous-backup")
        let current = skillsURL.appendingPathComponent(old.name)
        let backup = backupsURL.appendingPathComponent(old.name)
        var retiredCurrent = false, installedNew = false, movedOlder = false, installedBackup = false
        do {
            let baseline = try prepare(download, at: prepared)
            try before(.backup)
            try fm.createDirectory(at: snapshot, withIntermediateDirectories: false)
            try fm.copyItem(at: current, to: snapshot.appendingPathComponent("files"))
            try ConfigStore.secureWrite(try JSONEncoder().encode(old), to: snapshot.appendingPathComponent("record.json"))
            guard try stamps(at: snapshot.appendingPathComponent("files")) == old.baseline else { throw SkillError("备份期间文件发生变化，已停止更新。") }
            try before(.replace)
            guard try localChanges(old).isEmpty else { throw SkillError("替换前检测到本地修改，已停止更新。") }
            if try itemType(backup) != nil { try validateBackup(backup, skill: old) }
            try fm.moveItem(at: current, to: retired)
            retiredCurrent = true
            try fm.moveItem(at: prepared, to: current)
            installedNew = true
            if try itemType(backup) != nil {
                try fm.moveItem(at: backup, to: older)
                movedOlder = true
            }
            try fm.moveItem(at: snapshot, to: backup)
            installedBackup = true
            library.skills[index].description = download.metadata.description
            library.skills[index].commit = download.snapshot.commit
            library.skills[index].sourceFingerprint = fingerprint
            library.skills[index].baseline = baseline
            library.pendingCleanup.append(transaction.lastPathComponent)
            try save(library, expected: revision)
        } catch {
            var failures: [String] = []
            func recover(_ operation: () throws -> Void) {
                do { try operation() } catch { failures.append(error.localizedDescription) }
            }
            if installedBackup { recover { try fm.moveItem(at: backup, to: snapshot) } }
            if movedOlder { recover { try fm.moveItem(at: older, to: backup) } }
            if installedNew { recover { try fm.moveItem(at: current, to: prepared) } }
            if retiredCurrent { recover { try fm.moveItem(at: retired, to: current) } }
            if failures.isEmpty { recover { try fm.removeItem(at: transaction) } }
            throw failure(error, transaction: transaction, recovery: failures)
        }
        return "已更新；" + (try finishCleanup(transaction))
    }

    public func addProject(_ url: URL) throws {
        let project = url.standardizedFileURL.resolvingSymlinksInPath()
        guard try itemType(project) == .typeDirectory else { throw SkillError("项目目录不存在：\(project.path)") }
        var (library, revision) = try load()
        guard !library.projects.contains(project.path) else { return }
        library.projects.append(project.path)
        try prepareRoot()
        try save(library, expected: revision)
    }

    public func setScopes(_ scopes: [String], for id: String) throws {
        var (library, revision) = try load()
        guard let index = library.skills.firstIndex(where: { $0.id == id }) else { throw SkillError("skill 已不在技能库中。") }
        let skill = library.skills[index]
        let desired = Array(Set(scopes)).sorted()
        guard !desired.contains(Self.globalScope) || desired.count == 1,
              desired.allSatisfy({ $0 == Self.globalScope || library.projects.contains($0) }) else { throw SkillError("启用范围无效。") }
        guard try itemType(skillsURL.appendingPathComponent(skill.name)) == .typeDirectory else { throw SkillError("技能库文件不可用：\(skill.name)") }
        let adding = desired.filter { !skill.scopes.contains($0) || (try? itemType(linkURL(skill, scope: $0))) == nil }
        let removing = skill.scopes.filter { !desired.contains($0) }
        for scope in skill.scopes { try validateLink(skill, scope: scope, required: false) }
        for scope in desired {
            let link = linkURL(skill, scope: scope)
            if !skill.scopes.contains(scope), try itemType(link) != nil { throw SkillError("启用入口被占用：\(link.path)") }
            try checkNameConflicts(skill, scope: scope, library: library)
        }
        var created: [String] = [], removed: [String] = []
        do {
            for scope in adding {
                let directory = try scopeDirectory(scope, create: true)
                let link = directory.appendingPathComponent(skill.name)
                guard try itemType(link) == nil else { throw SkillError("启用入口已被占用：\(link.path)") }
                try fm.createSymbolicLink(at: link, withDestinationURL: skillsURL.appendingPathComponent(skill.name))
                created.append(scope)
            }
            for scope in removing {
                let link = linkURL(skill, scope: scope)
                try validateLink(skill, scope: scope, required: false)
                if try itemType(link) != nil {
                    try fm.removeItem(at: link)
                    removed.append(scope)
                }
            }
            library.skills[index].scopes = desired
            try prepareRoot()
            try save(library, expected: revision)
        } catch {
            var failures: [String] = []
            for scope in created {
                do { try validateLink(skill, scope: scope, required: true); try fm.removeItem(at: linkURL(skill, scope: scope)) }
                catch { failures.append(error.localizedDescription) }
            }
            for scope in removed {
                do {
                    let link = linkURL(skill, scope: scope)
                    guard try itemType(link) == nil else { throw SkillError("恢复入口被占用：\(link.path)") }
                    try fm.createSymbolicLink(at: link, withDestinationURL: skillsURL.appendingPathComponent(skill.name))
                } catch { failures.append(error.localizedDescription) }
            }
            throw SkillError(error.localizedDescription + (failures.isEmpty ? "" : "\n入口恢复失败：" + failures.joined(separator: "\n")))
        }
    }

    public func localChanges(_ skill: InstalledSkill) throws -> [String] {
        let actual = try stamps(at: skillsURL.appendingPathComponent(skill.name))
        return Set(actual.keys).union(skill.baseline.keys).sorted().compactMap { path in
            guard actual[path] != skill.baseline[path] else { return nil }
            if skill.baseline[path] == nil { return "新增：\(path)" }
            if actual[path] == nil { return "删除：\(path)" }
            return "变化：\(path)"
        }
    }

    private func load() throws -> (SkillLibrary, Data?) {
        try checkStorageDirectories()
        guard let type = try itemType(stateURL) else { return (SkillLibrary(), nil) }
        guard type == .typeRegular else { throw SkillError("安装记录不是普通文件：\(stateURL.path)") }
        let data = try Data(contentsOf: stateURL)
        guard data.count <= 16 * 1024 * 1024 else { throw SkillError("安装记录过大，已停止写操作。") }
        let library: SkillLibrary
        do { library = try JSONDecoder().decode(SkillLibrary.self, from: data) }
        catch { throw SkillError("安装记录损坏，已停止写操作；请检查：\(stateURL.path)") }
        guard library.version == 1 else { throw SkillError("不支持该安装记录版本，已停止写操作。") }
        var ids = Set<String>(), names = Set<String>(), sources = Set<String>()
        for skill in library.skills {
            try SkillSafety.validateName(skill.name)
            guard UUID(uuidString: skill.id) != nil, ids.insert(skill.id).inserted, names.insert(skill.name).inserted,
                  (try SkillRepositoryAddress(skill.repository.url)) == skill.repository,
                  sources.insert(skill.repository.slug + ":" + skill.sourcePath).inserted,
                  SkillSafety.validSHA(skill.commit), skill.sourceFingerprint.count == 64,
                  Set(skill.scopes).count == skill.scopes.count,
                  !skill.scopes.contains(Self.globalScope) || skill.scopes.count == 1 else { throw SkillError("安装记录校验失败。") }
            if !skill.sourcePath.isEmpty { try SkillSafety.validatePath(skill.sourcePath) }
            for path in skill.baseline.keys { try SkillSafety.validatePath(path) }
            for scope in skill.scopes where scope != Self.globalScope {
                guard library.projects.contains(scope) else { throw SkillError("安装记录含未知项目。") }
            }
        }
        for project in library.projects {
            guard project.hasPrefix("/"), URL(fileURLWithPath: project).standardizedFileURL.path == project else { throw SkillError("项目路径记录无效。") }
        }
        guard Set(library.pendingCleanup).count == library.pendingCleanup.count,
              library.pendingCleanup.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw SkillError("清理记录无效。") }
        return (library, data)
    }

    private func save(_ library: SkillLibrary, expected: Data?) throws {
        let (_, current) = try load()
        guard current == expected else { throw SkillError("安装记录被外部修改，请重新加载后重试。") }
        try before(.writeState)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try ConfigStore.secureWrite(encoder.encode(library), to: stateURL)
    }

    private func prepareRoot() throws {
        try ensureDirectory(root)
        for directory in [skillsURL, stagingURL, backupsURL] { try ensureDirectory(directory) }
    }

    private func checkStorageDirectories() throws {
        for directory in [root, skillsURL, stagingURL, backupsURL] {
            if let type = try itemType(directory), type != .typeDirectory { throw SkillError("存储目录被占用或是外部链接：\(directory.path)") }
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        if let type = try itemType(url) {
            guard type == .typeDirectory else { throw SkillError("目录被占用或是链接：\(url.path)") }
            return
        }
        let parent = url.deletingLastPathComponent()
        if parent != url { try ensureDirectory(parent) }
        try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    private func itemType(_ url: URL) throws -> FileAttributeType? {
        do { return try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType }
        catch let error as CocoaError where [.fileReadNoSuchFile, .fileNoSuchFile].contains(error.code) { return nil }
    }

    private func makeTransaction() throws -> URL {
        let url = stagingURL.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    private func validateDownload(_ download: SkillDownload) throws {
        guard SkillSafety.validSHA(download.snapshot.commit),
              (try SkillRepositoryAddress(download.snapshot.repository.url)) == download.snapshot.repository else { throw SkillError("下载来源记录无效。") }
        let files = try download.snapshot.files(in: download.path)
        let prefix = download.path.isEmpty ? "" : download.path + "/"
        guard files.count == download.files.count else { throw SkillError("下载文件清单不完整。") }
        for entry in files {
            let path = String(entry.path.dropFirst(prefix.count))
            guard let data = download.files[path], data.count == entry.size, SkillSafety.blobSHA(data) == entry.sha else { throw SkillError("下载文件校验失败：\(path)") }
        }
        guard let instructions = download.files["SKILL.md"], try SkillMetadata.parse(instructions) == download.metadata else { throw SkillError("下载 frontmatter 不一致。") }
    }

    private func prepare(_ download: SkillDownload, at directory: URL) throws -> [String: SkillFileStamp] {
        try before(.prepare)
        try ensureDirectory(directory)
        let prefix = download.path.isEmpty ? "" : download.path + "/"
        for entry in try download.snapshot.files(in: download.path) {
            let path = String(entry.path.dropFirst(prefix.count))
            let url = directory.appendingPathComponent(path)
            try ensureDirectory(url.deletingLastPathComponent())
            try ConfigStore.secureWrite(download.files[path]!, to: url)
            try fm.setAttributes([.posixPermissions: entry.mode == "100755" ? 0o755 : 0o644], ofItemAtPath: url.path)
        }
        return try stamps(at: directory)
    }

    private func stamps(at directory: URL) throws -> [String: SkillFileStamp] {
        guard try itemType(directory) == .typeDirectory else { throw SkillError("skill 目录不可用或被替换为链接：\(directory.path)") }
        var result: [String: SkillFileStamp] = [:]
        var bytes = 0
        func walk(_ url: URL, prefix: String) throws {
            for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                let path = prefix + child.lastPathComponent
                try SkillSafety.validatePath(path)
                let attributes = try fm.attributesOfItem(atPath: child.path)
                let type = attributes[.type] as? FileAttributeType
                let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                guard result.count < Self.maxLocalEntries else { throw SkillError("本地 skill 条目过多，已停止操作。") }
                if type == .typeDirectory {
                    result[path] = SkillFileStamp(hash: "", executable: permissions & 0o111, directory: true)
                    try walk(child, prefix: path + "/")
                } else if type == .typeRegular {
                    let size = (attributes[.size] as? NSNumber)?.intValue ?? Int.max
                    guard size <= HTTPFetcher.maxBytes, bytes + size <= SkillRepository.maxTotalBytes else { throw SkillError("本地文件过大，已停止操作：\(path)") }
                    let data = try Data(contentsOf: child)
                    bytes += data.count
                    result[path] = SkillFileStamp(hash: SkillSafety.digest(data), executable: permissions & 0o111, directory: false)
                } else { throw SkillError("本地存在符号链接或特殊文件，已停止操作：\(path)") }
            }
        }
        try walk(directory, prefix: "")
        return result
    }
    private static let maxLocalEntries = 2000

    private func validateBackup(_ directory: URL, skill: InstalledSkill) throws {
        guard try itemType(directory) == .typeDirectory, try itemType(directory.appendingPathComponent("record.json")) == .typeRegular else { throw SkillError("旧版备份路径被占用：\(directory.path)") }
        let record = try JSONDecoder().decode(InstalledSkill.self, from: Data(contentsOf: directory.appendingPathComponent("record.json")))
        guard record.id == skill.id, record.name == skill.name, try stamps(at: directory.appendingPathComponent("files")) == record.baseline else { throw SkillError("旧版备份已被修改，未覆盖：\(directory.path)") }
    }

    private func retryCleanup() throws -> [String] {
        var (library, revision) = try load()
        var warnings: [String] = []
        for id in library.pendingCleanup {
            let directory = stagingURL.appendingPathComponent(id)
            do {
                try before(.cleanup)
                if try itemType(directory) != nil {
                    guard try itemType(directory) == .typeDirectory else { throw SkillError("清理路径被外部修改：\(directory.path)") }
                    try fm.removeItem(at: directory)
                }
                library.pendingCleanup.removeAll { $0 == id }
                try save(library, expected: revision)
                revision = try load().1
            } catch { warnings.append("清理失败：\(directory.path)；\(error.localizedDescription)") }
        }
        return warnings
    }

    private func finishCleanup(_ transaction: URL) throws -> String {
        do {
            let warnings = try retryCleanup()
            return warnings.isEmpty ? "已完成。" : "操作成功，清理未完成：\n" + warnings.joined(separator: "\n")
        } catch { return "操作成功，清理未完成：\(transaction.path)；\(error.localizedDescription)" }
    }

    private func failure(_ error: Error, transaction: URL, recovery: [String]) -> SkillError {
        SkillError(error.localizedDescription + (recovery.isEmpty ? "" : "\n恢复或清理失败：" + recovery.joined(separator: "\n") + "\n保留操作目录：\(transaction.path)"))
    }

    private func scopeDirectory(_ scope: String, create: Bool) throws -> URL {
        let base = scope == Self.globalScope ? home : URL(fileURLWithPath: scope)
        guard try itemType(base) == .typeDirectory else { throw SkillError("项目或主目录不可用：\(base.path)") }
        var url = base.appendingPathComponent(".pi")
        let components = scope == Self.globalScope ? [url, url.appendingPathComponent("agent"), url.appendingPathComponent("agent/skills")] : [url, url.appendingPathComponent("skills")]
        for directory in components {
            if create { try ensureDirectory(directory) }
            else if let type = try itemType(directory), type != .typeDirectory { throw SkillError("入口父目录被占用或是链接：\(directory.path)") }
        }
        url = components.last!
        return url
    }

    private func linkURL(_ skill: InstalledSkill, scope: String) -> URL {
        let base = scope == Self.globalScope ? home.appendingPathComponent(".pi/agent/skills") : URL(fileURLWithPath: scope).appendingPathComponent(".pi/skills")
        return base.appendingPathComponent(skill.name)
    }

    private func validateLink(_ skill: InstalledSkill, scope: String, required: Bool) throws {
        _ = try scopeDirectory(scope, create: false)
        let link = linkURL(skill, scope: scope)
        guard let type = try itemType(link) else {
            if required { throw SkillError("启用入口缺失：\(link.path)") }
            return
        }
        guard type == .typeSymbolicLink else { throw SkillError("启用入口被外部占用：\(link.path)") }
        let destination = try fm.destinationOfSymbolicLink(atPath: link.path)
        let target = destination.hasPrefix("/") ? URL(fileURLWithPath: destination) : link.deletingLastPathComponent().appendingPathComponent(destination)
        guard target.standardizedFileURL.path == skillsURL.appendingPathComponent(skill.name).path else { throw SkillError("链接已被修改：\(link.path) → \(destination)") }
        if required {
            guard try itemType(target) == .typeDirectory, try itemType(target.appendingPathComponent("SKILL.md")) == .typeRegular else {
                throw SkillError("启用链接目标或 SKILL.md 不可用：\(target.path)")
            }
        }
    }

    private func checkNameConflicts(_ skill: InstalledSkill, scope: String, library: SkillLibrary) throws {
        var roots = [home.appendingPathComponent(".pi/agent/skills"), home.appendingPathComponent(".agents/skills")]
        let projects = scope == Self.globalScope ? library.projects : [scope]
        for project in projects {
            roots.append(URL(fileURLWithPath: project).appendingPathComponent(".pi/skills"))
            roots.append(URL(fileURLWithPath: project).appendingPathComponent(".agents/skills"))
        }
        let own = skillsURL.appendingPathComponent(skill.name).standardizedFileURL.path
        var visited = Set<String>()
        var count = 0
        func walk(_ url: URL, isRoot: Bool = false, allowMarkdown: Bool = false) throws {
            let resolved = url.resolvingSymlinksInPath()
            guard visited.insert(resolved.path).inserted, resolved.path != own else { return }
            guard let type = try itemType(resolved) else { return }
            count += 1
            guard count <= 10000 else { throw SkillError("生效入口条目过多，无法完成同名检查。") }
            if type == .typeDirectory {
                let instructions = resolved.appendingPathComponent("SKILL.md")
                if try itemType(instructions) == .typeRegular {
                    let size = (try fm.attributesOfItem(atPath: instructions.path)[.size] as? NSNumber)?.intValue ?? Int.max
                    if size <= 256 * 1024, let metadata = try? SkillMetadata.parse(Data(contentsOf: instructions)), metadata.name == skill.name {
                        throw SkillError("生效范围存在同名 skill：\(instructions.path)")
                    }
                    return
                }
                for child in try fm.contentsOfDirectory(at: resolved, includingPropertiesForKeys: nil) where !child.lastPathComponent.hasPrefix(".") && child.lastPathComponent != "node_modules" { try walk(child, allowMarkdown: isRoot) }
            } else if type == .typeRegular, allowMarkdown, resolved.pathExtension.lowercased() == "md" {
                let size = (try fm.attributesOfItem(atPath: resolved.path)[.size] as? NSNumber)?.intValue ?? Int.max
                if size <= 256 * 1024, let metadata = try? SkillMetadata.parse(Data(contentsOf: resolved)), metadata.name == skill.name {
                    throw SkillError("生效范围存在同名 skill：\(resolved.path)")
                }
            }
        }
        for root in roots { try walk(root, isRoot: true) }
    }
}
