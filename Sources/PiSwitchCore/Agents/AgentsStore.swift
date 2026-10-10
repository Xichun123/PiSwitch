import Foundation
import Darwin

public actor AgentsStore {
    public nonisolated let root: URL
    public nonisolated let agentDirectory: URL
    public nonisolated var globalURL: URL { agentDirectory.appendingPathComponent("AGENTS.md") }
    public nonisolated var stateURL: URL { root.appendingPathComponent("agents-state.json") }
    private var files: URL { root.appendingPathComponent("agents") }
    private let fm = FileManager.default
    private let step: @Sendable (AgentsStoreStep) throws -> Void
    private var cleanupWarning: String?
    public static let maxFileBytes = 2 * 1024 * 1024

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("PiSwitch"),
                agentDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent"),
                step: @escaping @Sendable (AgentsStoreStep) throws -> Void = { _ in }) {
        self.root = Self.canonicalDirectory(root)
        self.agentDirectory = Self.canonicalDirectory(agentDirectory)
        self.step = step
    }

    private nonisolated static func canonicalDirectory(_ url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            missing.insert(ancestor.lastPathComponent, at: 0)
            ancestor.deleteLastPathComponent()
        }
        var result = ancestor
        if let resolved = realpath(ancestor.path, nil) {
            result = URL(fileURLWithPath: String(cString: resolved))
            free(resolved)
        }
        for component in missing { result.appendPathComponent(component) }
        return result
    }

    public func inspect() throws -> AgentsInspection {
        try checkDirectories(files)
        let revision = try snapshot(stateURL)
        let state: AgentsState
        if let data = revision.data {
            do { state = try JSONDecoder().decode(AgentsState.self, from: data) }
            catch { throw AgentsError("AGENTS 记录损坏，已禁止写入：\(stateURL.path)") }
        } else { state = AgentsState() }
        try validate(state)
        var warnings: [String] = []
        let staging = files.appendingPathComponent("staging")
        if try type(staging) != nil {
            try checkDirectories(staging)
            let leftovers = try fm.contentsOfDirectory(atPath: staging.path)
            if !leftovers.isEmpty { warnings.append("暂存区有未清理的操作，请人工检查；不会自动恢复或删除：\(staging.path)") }
        }
        if let cleanupWarning { warnings.append(cleanupWarning) }
        return AgentsInspection(state: state, revision: revision, warnings: warnings)
    }

    public func read(_ target: AgentTarget) throws -> AgentFileSnapshot {
        let state = try inspect().state
        return try snapshot(url(target, state: state))
    }

    public func importFile(_ path: URL) throws -> AgentFileSnapshot {
        try snapshot(Self.canonicalDirectory(path.deletingLastPathComponent()).appendingPathComponent(path.lastPathComponent))
    }

    public func path(_ target: AgentTarget) throws -> URL { try url(target, state: inspect().state) }

    public func backup(_ target: AgentTarget) throws -> AgentFileSnapshot? {
        let state = try inspect().state
        _ = try url(target, state: state)
        return try checkedBackup(target.key, state: state)
    }

    public func create(_ collection: AgentsCollection, name: String, data: Data,
                       expected: AgentFileSnapshot) throws -> UUID {
        let loaded = try checkedState(expected)
        var state = loaded.state
        let entry = AgentEntry(name: try validName(name))
        if collection == .global { state.globals.append(entry) } else { state.templates.append(entry) }
        let target = AgentTarget.entry(collection, entry.id)
        let destination = try url(target, state: state)
        let baseline = try snapshot(destination)
        guard baseline.data == nil else { throw AgentsError("库文件已被占用：\(destination.path)") }
        try commit(target, data: data, baseline: baseline, loaded: loaded, state: state)
        return entry.id
    }

    public func importGlobal(name: String, baseline: AgentFileSnapshot,
                             expected: AgentFileSnapshot) throws -> UUID {
        guard let data = baseline.data else { throw AgentsError("全局 AGENTS.md 不存在。") }
        guard try snapshot(globalURL) == baseline else { throw conflict(globalURL) }
        let loaded = try checkedState(expected)
        var state = loaded.state
        let entry = AgentEntry(name: try validName(name))
        state.globals.append(entry)
        state.activeGlobal = AgentApplication(versionId: entry.id, appliedHash: AgentFileSnapshot.digest(data))
        let target = AgentTarget.entry(.global, entry.id)
        let destination = try url(target, state: state)
        let empty = try snapshot(destination)
        guard empty.data == nil else { throw AgentsError("库文件已被占用。") }
        try commit(target, data: data, baseline: empty, loaded: loaded, state: state,
                   check: { guard try self.snapshot(self.globalURL) == baseline else { throw self.conflict(self.globalURL) } })
        return entry.id
    }

    public func save(_ target: AgentTarget, data: Data, name: String? = nil,
                     baseline: AgentFileSnapshot, expected: AgentFileSnapshot) throws {
        let loaded = try checkedState(expected)
        var state = loaded.state
        _ = try url(target, state: state)
        if case .entry(let collection, let id) = target, let name {
            let name = try validName(name)
            if collection == .global { state.globals[state.globals.firstIndex { $0.id == id }!].name = name }
            else { state.templates[state.templates.firstIndex { $0.id == id }!].name = name }
        }
        if target == .global { state.activeGlobal = nil }
        try commit(target, data: data, baseline: baseline, loaded: loaded, state: state)
    }

    public func deleteEntry(_ collection: AgentsCollection, id: UUID, baseline: AgentFileSnapshot,
                            expected: AgentFileSnapshot) throws {
        let loaded = try checkedState(expected)
        guard loaded.state.activeGlobal?.versionId != id else {
            throw AgentsError("请先切换全局版本或解除管理；不会删除正在应用的版本。")
        }
        let target = AgentTarget.entry(collection, id)
        _ = try url(target, state: loaded.state)
        var state = loaded.state
        if collection == .global { state.globals.removeAll { $0.id == id } }
        else { state.templates.removeAll { $0.id == id } }
        state.backups.removeAll { $0.key == target.key }
        try commit(target, data: nil, baseline: baseline, loaded: loaded, state: state, keepBackup: false)
    }

    public func detachGlobal(expected: AgentFileSnapshot) throws {
        let loaded = try checkedState(expected)
        var state = loaded.state; state.activeGlobal = nil
        try persist(state, expected: loaded.revision)
    }

    public func addProject(_ path: URL, expected: AgentFileSnapshot) throws -> UUID {
        let loaded = try checkedState(expected)
        let directory = Self.canonicalDirectory(path)
        try checkDirectories(directory)
        guard try type(directory) == .typeDirectory else { throw AgentsError("项目目录不存在：\(directory.path)") }
        guard directory != agentDirectory, !directory.path.hasPrefix(files.path + "/"), directory != files else {
            throw AgentsError("不能把 agent 目录或指令库登记为项目。")
        }
        let identity = try fm.attributesOfItem(atPath: directory.path)
        if let existing = loaded.state.projects.first(where: { project in
            if project.path == directory.path { return true }
            guard let other = try? fm.attributesOfItem(atPath: project.path) else { return false }
            return other[.systemNumber] as? NSNumber == identity[.systemNumber] as? NSNumber &&
                other[.systemFileNumber] as? NSNumber == identity[.systemFileNumber] as? NSNumber
        }) { return existing.id }
        var state = loaded.state
        let project = AgentProject(path: directory.path)
        state.projects.append(project)
        try persist(state, expected: loaded.revision)
        return project.id
    }

    public func removeProject(_ id: UUID, expected: AgentFileSnapshot) throws {
        let loaded = try checkedState(expected)
        var state = loaded.state; state.projects.removeAll { $0.id == id }
        try persist(state, expected: loaded.revision)
    }

    public func applyGlobal(_ id: UUID, source: AgentFileSnapshot, baseline: AgentFileSnapshot,
                            expected: AgentFileSnapshot, allowExternal: Bool = false) throws {
        let loaded = try checkedState(expected)
        let sourceURL = try url(.entry(.global, id), state: loaded.state)
        guard let data = source.data, try snapshot(sourceURL) == source else { throw conflict(sourceURL) }
        if let active = loaded.state.activeGlobal, baseline.hash != active.appliedHash, !allowExternal {
            throw AgentsError("全局文件被外部修改、删除或重建，请先另存为版本或明确确认备份后覆盖。")
        }
        try requireUnmasked(agentDirectory)
        var state = loaded.state
        state.activeGlobal = AgentApplication(versionId: id, appliedHash: AgentFileSnapshot.digest(data))
        try commit(.global, data: data, baseline: baseline, loaded: loaded, state: state,
                   check: {
            try self.requireUnmasked(self.agentDirectory)
            guard try self.snapshot(sourceURL) == source else { throw self.conflict(sourceURL) }
        })
    }

    public func useTemplate(_ templateId: UUID, projectId: UUID, source: AgentFileSnapshot,
                            baseline: AgentFileSnapshot, expected: AgentFileSnapshot) throws {
        let loaded = try checkedState(expected)
        let sourceURL = try url(.entry(.templates, templateId), state: loaded.state)
        guard let data = source.data, try snapshot(sourceURL) == source else { throw conflict(sourceURL) }
        let target = AgentTarget.project(projectId)
        let destination = try url(target, state: loaded.state)
        try requireUnmasked(destination.deletingLastPathComponent())
        var state = loaded.state
        let template = state.templates.first { $0.id == templateId }!
        state.projects[state.projects.firstIndex { $0.id == projectId }!].origin = AgentOrigin(
            templateId: templateId, templateName: template.name, createdFromHash: AgentFileSnapshot.digest(data))
        try commit(target, data: data, baseline: baseline, loaded: loaded, state: state,
                   check: {
            try self.requireUnmasked(destination.deletingLastPathComponent())
            guard try self.snapshot(sourceURL) == source else { throw self.conflict(sourceURL) }
        })
    }

    public func restore(_ target: AgentTarget, baseline: AgentFileSnapshot,
                        expected: AgentFileSnapshot) throws {
        let loaded = try checkedState(expected)
        guard let old = try checkedBackup(target.key, state: loaded.state), let data = old.data else {
            throw AgentsError("没有可恢复的备份。")
        }
        var state = loaded.state
        if target == .global { state.activeGlobal = nil }
        let mode = loaded.state.backups.first { $0.key == target.key }!.permissions
        try commit(target, data: data, baseline: baseline, loaded: loaded, state: state, newMode: mode)
    }

    // shortcut: 普通祖先链预测不处理嵌套 linked worktree；需要精确会话诊断时接入 Git 去重。
    public func contextChain(cwd: URL) -> [AgentContext] {
        var directories = [agentDirectory]
        var ancestors: [URL] = []
        var current = Self.canonicalDirectory(cwd)
        while true {
            ancestors.insert(current, at: 0)
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        directories += ancestors.filter { $0 != agentDirectory }
        return directories.map { directory in
            var present: [String] = [], seen = Set<String>(), problem: String?
            for filename in ["AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"] {
                let path = directory.appendingPathComponent(filename)
                if !fm.fileExists(atPath: path.path) { continue }
                do {
                    let attributes = try fm.attributesOfItem(atPath: path.resolvingSymlinksInPath().path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
                    let identity = "\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? "")"
                    guard seen.insert(identity).inserted else { continue }
                    guard fm.isReadableFile(atPath: path.path) else { problem = "候选文件不可读：\(path.path)"; continue }
                    present.append(path.path)
                } catch { problem = "候选检查失败：\(path.path)" }
            }
            return AgentContext(directory: directory.path, selectedPath: present.first,
                                otherPaths: Array(present.dropFirst()), problem: problem)
        }
    }

    private func checkedState(_ expected: AgentFileSnapshot) throws -> AgentsInspection {
        let loaded = try inspect()
        guard loaded.revision == expected else { throw conflict(stateURL) }
        return loaded
    }

    private func url(_ target: AgentTarget, state: AgentsState) throws -> URL {
        switch target {
        case .global: return globalURL
        case .entry(let collection, let id):
            guard state.entries(collection).contains(where: { $0.id == id }) else { throw AgentsError("版本或模板已不存在。") }
            return files.appendingPathComponent("\(collection.rawValue)/\(id.uuidString).md")
        case .project(let id):
            guard let project = state.projects.first(where: { $0.id == id }) else { throw AgentsError("项目已不存在。") }
            let directory = URL(fileURLWithPath: project.path)
            try checkDirectories(directory)
            guard try type(directory) == .typeDirectory else { throw AgentsError("项目目录已不存在：\(project.path)") }
            return directory.appendingPathComponent("AGENTS.md")
        }
    }

    private func backupURL(_ key: String) -> URL { files.appendingPathComponent("backups/\(key)/content.md") }

    private func checkedBackup(_ key: String, state: AgentsState) throws -> AgentFileSnapshot? {
        let file = try snapshot(backupURL(key))
        guard let record = state.backups.first(where: { $0.key == key }) else {
            guard file.data == nil else { throw AgentsError("备份路径有未登记内容，已停止写入：\(backupURL(key).path)") }
            return nil
        }
        guard file.hash == record.hash, file.permissions == 0o600 else { throw AgentsError("备份缺失或被修改，已停止写入：\(backupURL(key).path)") }
        return file
    }

    private func commit(_ target: AgentTarget, data: Data?, baseline: AgentFileSnapshot,
                        loaded: AgentsInspection, state proposed: AgentsState, keepBackup: Bool = true,
                        newMode: Int? = nil, check: () throws -> Void = {}) throws {
        let destination = try url(target, state: loaded.state.entriesForNewTarget(target, proposed: proposed))
        if let data { try validateText(data) }
        guard try snapshot(destination) == baseline else { throw conflict(destination) }
        let oldBackup = try checkedBackup(target.key, state: loaded.state)
        try check()
        try ensureDirectory(destination.deletingLastPathComponent())
        let operation = files.appendingPathComponent("staging/\(UUID().uuidString)")
        try ensureDirectory(operation)
        var state = proposed
        var written: AgentFileSnapshot?
        var backupWritten: AgentFileSnapshot?
        var replaced = false
        var backupReplaced = false
        do {
            if let old = baseline.data { try ConfigStore.secureWrite(old, to: operation.appendingPathComponent("previous.md")) }
            if let old = oldBackup?.data { try ConfigStore.secureWrite(old, to: operation.appendingPathComponent("previous-backup.md")) }
            if let old = loaded.revision.data { try ConfigStore.secureWrite(old, to: operation.appendingPathComponent("previous-state.json")) }
            try step(.backup)
            if keepBackup, let old = baseline.data {
                try ensureDirectory(backupURL(target.key).deletingLastPathComponent())
                guard try checkedBackup(target.key, state: loaded.state) == oldBackup else { throw AgentsError("备份在操作期间发生变化。") }
                try ConfigStore.secureWrite(old, to: backupURL(target.key))
                backupReplaced = true
                backupWritten = try snapshot(backupURL(target.key))
                state.backups.removeAll { $0.key == target.key }
                state.backups.append(AgentBackup(key: target.key, hash: AgentFileSnapshot.digest(old), permissions: baseline.permissions!))
            }
            try step(.replace)
            try check()
            // shortcut: 没有进程间锁；外部写入密集时需升级检查到替换的并发保护。
            guard try snapshot(destination) == baseline else { throw conflict(destination) }
            guard try inspect().revision == loaded.revision else { throw conflict(stateURL) }
            if let data {
                let mode = baseline.permissions ?? newMode ?? (target.isProject ? 0o644 : 0o600)
                try ConfigStore.secureWrite(data, to: destination, permissions: mode)
            } else if baseline.data != nil { try fm.removeItem(at: destination) }
            replaced = true
            written = try snapshot(destination)
            try step(.writeState)
            try persist(state, expected: loaded.revision)
        } catch {
            var failures: [String] = []
            if replaced && written == nil { failures.append("替换后无法核对目标，未自动恢复：\(destination.path)") }
            if backupReplaced && backupWritten == nil { failures.append("备份写入后无法核对，未自动恢复：\(backupURL(target.key).path)") }
            if let written {
                do {
                    guard try snapshot(destination) == written else { throw conflict(destination) }
                    if let old = baseline.data { try ConfigStore.secureWrite(old, to: destination, permissions: baseline.permissions!) }
                    else if written.data != nil { try fm.removeItem(at: destination) }
                } catch { failures.append("目标恢复失败：\(destination.path)") }
            }
            if let backupWritten {
                do {
                    guard try snapshot(backupURL(target.key)) == backupWritten else { throw AgentsError("备份被外部修改。") }
                    if let old = oldBackup?.data { try ConfigStore.secureWrite(old, to: backupURL(target.key)) }
                    else { try fm.removeItem(at: backupURL(target.key)) }
                } catch { failures.append("备份恢复失败：\(backupURL(target.key).path)") }
            }
            if failures.isEmpty { try? fm.removeItem(at: operation) }
            else { failures.append("恢复材料：\(operation.path)") }
            throw AgentsError(([error.localizedDescription] + failures).joined(separator: "\n"))
        }
        do {
            try step(.cleanup)
            if !keepBackup, oldBackup != nil { try fm.removeItem(at: backupURL(target.key)) }
            try fm.removeItem(at: operation)
            cleanupWarning = nil
        } catch { cleanupWarning = "写入已完成，清理失败：\(operation.path)；\(error.localizedDescription)" }
    }

    private func persist(_ state: AgentsState, expected: AgentFileSnapshot) throws {
        try validate(state)
        try ensureDirectory(root)
        guard try snapshot(stateURL) == expected else { throw conflict(stateURL) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= Self.maxFileBytes else { throw AgentsError("AGENTS 记录超过 2 MiB。") }
        try ConfigStore.secureWrite(data, to: stateURL)
    }

    private func validate(_ state: AgentsState) throws {
        guard state.version == 1 else { throw AgentsError("不支持的 AGENTS 记录版本，已禁止写入。") }
        let ids = state.globals.map(\.id) + state.templates.map(\.id) + state.projects.map(\.id)
        guard Set(ids).count == ids.count else { throw AgentsError("AGENTS 记录存在重复标识。") }
        for entry in state.globals + state.templates { _ = try validName(entry.name) }
        var paths = Set<String>()
        for project in state.projects {
            let path = URL(fileURLWithPath: project.path).path
            guard project.path.hasPrefix("/"), path == project.path,
                  !project.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  !project.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), paths.insert(path).inserted,
                  path != agentDirectory.path, path != files.path, !path.hasPrefix(files.path + "/") else {
                throw AgentsError("项目记录路径无效或重复。")
            }
            if let origin = project.origin { guard validHash(origin.createdFromHash) else { throw AgentsError("模板来源记录无效。") } }
        }
        if let active = state.activeGlobal {
            guard state.globals.contains(where: { $0.id == active.versionId }), validHash(active.appliedHash) else { throw AgentsError("全局应用记录无效。") }
        }
        var keys = Set<String>()
        for backup in state.backups {
            guard (backup.key == "global" || UUID(uuidString: backup.key)?.uuidString == backup.key),
                  validHash(backup.hash), (0...0o777).contains(backup.permissions), keys.insert(backup.key).inserted else {
                throw AgentsError("备份记录无效。")
            }
        }
    }

    private func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120, !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AgentsError("名称须为 1–120 个字符，不能包含控制字符。")
        }
        return trimmed
    }

    private func validHash(_ hash: String) -> Bool { hash.count == 64 && hash.allSatisfy { "0123456789abcdef".contains($0) } }

    private func validateText(_ data: Data) throws {
        guard data.count <= Self.maxFileBytes, let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw AgentsError("只支持不超过 2 MiB、无 NUL 字符的 UTF-8 文本。")
        }
    }

    private func requireUnmasked(_ directory: URL) throws {
        let override = directory.appendingPathComponent("AGENTS.override.md")
        if fm.fileExists(atPath: override.path), fm.isReadableFile(atPath: override.path),
           (try fm.attributesOfItem(atPath: override.resolvingSymlinksInPath().path)[.type]) as? FileAttributeType == .typeRegular {
            throw AgentsError("AGENTS.md 被同目录 AGENTS.override.md 遮蔽，请先自行处理：\(override.path)")
        }
    }

    private func conflict(_ url: URL) -> AgentsError { AgentsError("文件在预览或加载后被修改、删除或新建，已拒绝覆盖：\(url.path)\n请导出草稿或重新加载后再确认。") }

    private func type(_ url: URL) throws -> FileAttributeType? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw AgentsError("无法检查路径：\(url.path)")
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .typeDirectory
        case S_IFREG: return .typeRegular
        case S_IFLNK: return .typeSymbolicLink
        default: return .typeUnknown
        }
    }

    private func checkDirectories(_ directory: URL) throws {
        var path = URL(fileURLWithPath: "/", isDirectory: true)
        for component in directory.pathComponents.dropFirst() {
            path.appendPathComponent(component)
            if let kind = try type(path), kind != .typeDirectory { throw AgentsError("目录路径被占用或含符号链接：\(path.path)") }
        }
    }

    private func ensureDirectory(_ directory: URL) throws {
        try checkDirectories(directory)
        if try type(directory) == nil { try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try checkDirectories(directory)
    }

    private func snapshot(_ url: URL) throws -> AgentFileSnapshot {
        try checkDirectories(url.deletingLastPathComponent())
        guard let kind = try type(url) else { return AgentFileSnapshot(data: nil, permissions: nil, inode: nil, device: nil, modificationTime: nil, modificationNanoseconds: nil, changeTime: nil, changeNanoseconds: nil) }
        guard kind == .typeRegular else { throw AgentsError("拒绝读取或写入链接、目录或特殊文件：\(url.path)") }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw AgentsError("无法读取：\(url.path)") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= Self.maxFileBytes else {
            throw AgentsError("文件类型异常或超过 2 MiB：\(url.path)")
        }
        guard info.st_nlink == 1, info.st_flags == 0, info.st_uid == getuid(), info.st_gid == getgid(), info.st_mode & 0o7000 == 0 else {
            throw AgentsError("文件有硬链接、特殊标志或所有权，不能安全替换：\(url.path)")
        }
        let attributes = flistxattr(fd, nil, 0, 0)
        guard attributes == 0 else { throw AgentsError("文件带扩展属性或属性不可读，不能安全替换：\(url.path)") }
        if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t?
            guard acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) != 0 else {
                throw AgentsError("文件带 ACL，不能安全替换：\(url.path)")
            }
        } else if errno != ENOENT { throw AgentsError("无法检查文件 ACL：\(url.path)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var data = Data()
        while data.count <= Self.maxFileBytes {
            guard let part = try handle.read(upToCount: Self.maxFileBytes + 1 - data.count), !part.isEmpty else { break }
            data.append(part)
        }
        try validateText(data)
        var after = stat()
        guard fstat(fd, &after) == 0, info.st_size == after.st_size,
              info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              info.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw conflict(url)
        }
        var linked = stat()
        guard lstat(url.path, &linked) == 0, linked.st_ino == info.st_ino, linked.st_dev == info.st_dev,
              linked.st_mode == info.st_mode else { throw conflict(url) }
        return AgentFileSnapshot(data: data, permissions: Int(info.st_mode & 0o777), inode: UInt64(info.st_ino), device: UInt64(info.st_dev),
                                 modificationTime: info.st_mtimespec.tv_sec, modificationNanoseconds: info.st_mtimespec.tv_nsec,
                                 changeTime: info.st_ctimespec.tv_sec, changeNanoseconds: info.st_ctimespec.tv_nsec)
    }
}

private extension AgentTarget {
    var isProject: Bool { if case .project = self { return true }; return false }
}

private extension AgentsState {
    func entriesForNewTarget(_ target: AgentTarget, proposed: AgentsState) -> AgentsState {
        if case .entry(let collection, let id) = target, !entries(collection).contains(where: { $0.id == id }) { return proposed }
        return self
    }
}
