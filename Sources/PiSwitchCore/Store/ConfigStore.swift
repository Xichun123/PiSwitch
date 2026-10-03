import Foundation

public enum StoreError: LocalizedError, Equatable {
    case isDirectory(String)
    case readFailed(String)
    case conflict
    case backupFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .isDirectory(let path): return "\(path) 是一个目录，不是文件"
        case .readFailed(let reason): return "读取配置失败：\(reason)"
        case .conflict: return "文件在加载后被外部修改、删除或新建，已拒绝保存。请重新加载（⌘R）后再编辑。"
        case .backupFailed(let reason): return "写入备份失败，已中止保存：\(reason)"
        case .writeFailed(let reason): return "写入配置失败：\(reason)"
        }
    }
}

public struct LoadedConfig: Sendable {
    public let document: ConfigDocument
    /// Bytes on disk at load time; `nil` when the file did not exist.
    public let baseline: Data?
}

public struct ConfigStore: Sendable {
    public let path: URL

    public init(path: URL = ConfigStore.defaultPath) {
        self.path = path
    }

    public static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/models.json")
    }

    /// Real file behind any symlinks, so a dotfiles-repo link is updated in place rather than replaced.
    public var resolvedPath: URL { path.resolvingSymlinksInPath() }
    public var backupPath: URL { resolvedPath.appendingPathExtension("bak") }

    public func load() throws -> LoadedConfig {
        guard let data = try Self.readIfExists(resolvedPath) else {
            return LoadedConfig(document: .empty, baseline: nil)
        }
        return LoadedConfig(document: try ConfigDocument.parse(data), baseline: data)
    }

    /// Returns the bytes written, to be used as the next baseline.
    @discardableResult
    public func save(_ document: ConfigDocument, baseline: Data?) throws -> Data {
        let data = try document.encoded()
        let target = resolvedPath

        // A tiny race window exists between this check and the rename below; no file lock by design (personal tool).
        let current = try Self.readIfExists(target)
        guard current == baseline else { throw StoreError.conflict }

        let directory = target.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw StoreError.writeFailed(error.localizedDescription)
            }
        }

        if let current {
            do { try Self.secureWrite(current, to: backupPath) } catch {
                throw StoreError.backupFailed(error.localizedDescription)
            }
        }

        do { try Self.secureWrite(data, to: target) } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
        return data
    }

    static func readIfExists(_ url: URL) throws -> Data? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { throw StoreError.isDirectory(url.path) }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw StoreError.readFailed(error.localizedDescription)
        }
    }

    /// Writes via a 0600 temp file + rename, so the key is never world-readable, even briefly.
    static func secureWrite(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw posixError("创建临时文件") }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }

        guard rename(temp.path, url.path) == 0 else {
            let error = posixError("替换文件")
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func posixError(_ action: String) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(action)失败：\(String(cString: strerror(code)))"]
        )
    }
}
