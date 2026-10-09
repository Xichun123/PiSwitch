import Foundation
import CryptoKit
import Yams

public struct SkillError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct SkillRepositoryAddress: Codable, Hashable, Sendable {
    public let slug: String
    public var url: String { "https://github.com/\(slug)" }

    public init(_ input: String) throws {
        guard let url = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host?.lowercased() == "github.com",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else {
            throw SkillError("请输入公开 GitHub 仓库首页地址：https://github.com/owner/repo")
        }
        var path = url.percentEncodedPath
        if path.hasSuffix("/") { path.removeLast() }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty else { throw SkillError("仅支持仓库首页，不支持分支或文件地址。") }
        let owner = String(parts[1])
        var repo = String(parts[2])
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        let valid = "^[A-Za-z0-9_.-]+$"
        guard [owner, repo].allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.range(of: valid, options: .regularExpression) != nil }) else {
            throw SkillError("GitHub 仓库地址格式有误。")
        }
        slug = "\(owner)/\(repo)".lowercased()
    }
}

public struct SkillMetadata: Equatable, Sendable {
    public let name: String
    public let description: String

    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= 256 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw SkillError("SKILL.md 必须是 UTF-8 文本，且不能超过 256 KiB。")
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            throw SkillError("SKILL.md 缺少完整 YAML frontmatter。")
        }
        let node: Node?
        do {
            let resolver = try Resolver.default.removing(.timestamp).replacing(.bool, with: "^(?:true|True|TRUE|false|False|FALSE)$")
            node = try Yams.compose(yaml: lines[1..<end].joined(separator: "\n"), resolver)
        }
        catch { throw SkillError("SKILL.md 的 YAML frontmatter 解析失败。") }
        guard let node, case .mapping(let mapping) = node,
              Set(mapping.map { $0.key.string ?? "" }).count == mapping.count,
              node["name"]?.tag == Tag(.str), node["description"]?.tag == Tag(.str),
              let name = node["name"]?.string,
              let description = node["description"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty, description.count <= 1024 else {
            throw SkillError("frontmatter 需要唯一字段、有效 name 和非空 description（最多 1024 字符）。")
        }
        try SkillSafety.validateName(name)
        return Self(name: name, description: description)
    }
}

public enum SkillSafety {
    public static func validateName(_ name: String) throws {
        guard name.count <= 64, name.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil else {
            throw SkillError("skill 名称需使用小写字母、数字和单个连字符，最多 64 字符：\(name)")
        }
    }

    public static func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.contains("\\"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SkillError("不安全的相对路径：\(path)")
        }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func blobSHA(_ data: Data) -> String {
        let blob = Data("blob \(data.count)\0".utf8) + data
        return Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined()
    }

    static func validSHA(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil
    }
}

public struct SkillTreeEntry: Codable, Equatable, Sendable {
    public let path: String
    public let mode: String
    public let type: String
    public let sha: String
    public let size: Int?
}

public struct SkillRepositorySnapshot: Sendable {
    public let repository: SkillRepositoryAddress
    public let commit: String
    public let entries: [SkillTreeEntry]

    public func files(in path: String) throws -> [SkillTreeEntry] {
        if !path.isEmpty { try SkillSafety.validatePath(path) }
        let prefix = path.isEmpty ? "" : path + "/"
        let files = entries.filter { $0.path.hasPrefix(prefix) && $0.type != "tree" }
        guard files.contains(where: { $0.path == prefix + "SKILL.md" }) else {
            throw SkillError("原来源路径中没有 SKILL.md：\(path.isEmpty ? "." : path)")
        }
        guard !files.isEmpty, files.count <= SkillRepository.maxFiles else { throw SkillError("skill 文件数量超过限制（\(SkillRepository.maxFiles)）。") }
        var names = Set<String>()
        var total = 0
        for file in files {
            try SkillSafety.validatePath(file.path)
            guard file.type == "blob", ["100644", "100755"].contains(file.mode) else {
                throw SkillError("暂不支持符号链接或子模块：\(file.path)")
            }
            guard let size = file.size, size >= 0, size <= HTTPFetcher.maxBytes else { throw SkillError("文件过大或大小未知：\(file.path)") }
            total += size
            guard total <= SkillRepository.maxTotalBytes else { throw SkillError("skill 总大小超过 50 MiB。") }
            let relative = String(file.path.dropFirst(prefix.count))
            guard names.insert(relative.lowercased()).inserted else { throw SkillError("大小写路径冲突：\(relative)") }
        }
        // Reject differing case in any shared directory component as well.
        var spelling: [String: String] = [:]
        for file in files {
            let components = String(file.path.dropFirst(prefix.count)).split(separator: "/")
            for count in 1...components.count {
                let value = components.prefix(count).joined(separator: "/")
                if count < components.count, names.contains(value.lowercased()) { throw SkillError("文件与目录路径冲突：\(value)") }
                if let existing = spelling[value.lowercased()], existing != value { throw SkillError("大小写路径冲突：\(value)") }
                spelling[value.lowercased()] = value
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    public func fingerprint(in path: String) throws -> String {
        let prefix = path.isEmpty ? "" : path + "/"
        let values = try files(in: path).map { [String($0.path.dropFirst(prefix.count)), $0.mode, $0.sha] }
        return SkillSafety.digest(try JSONEncoder().encode(values))
    }
}

public struct SkillCandidate: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let metadata: SkillMetadata?
    public let problem: String?
}

public struct SkillDownload: Sendable {
    public let snapshot: SkillRepositorySnapshot
    public let path: String
    public let metadata: SkillMetadata
    public let files: [String: Data]
}

public struct SkillFileStamp: Codable, Equatable, Sendable {
    public let hash: String
    public let executable: Int
    public let directory: Bool
}

public struct InstalledSkill: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public var description: String
    public let repository: SkillRepositoryAddress
    public let sourcePath: String
    public var commit: String
    public var sourceFingerprint: String
    public var baseline: [String: SkillFileStamp]
    public var scopes: [String]
}

public struct SkillLibrary: Codable, Equatable, Sendable {
    public var version = 1
    public var skills: [InstalledSkill] = []
    public var projects: [String] = []
    public var pendingCleanup: [String] = []
    public init() {}
}

public struct SkillInspection: Sendable {
    public let library: SkillLibrary
    public let localChanges: [String: [String]]
    public let scopeProblems: [String: [String: String]]
    public let warnings: [String]
}
