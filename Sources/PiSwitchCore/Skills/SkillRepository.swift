import Foundation

public struct SkillRepository: Sendable {
    public static let maxFiles = 1000
    public static let maxTotalBytes = 50 * 1024 * 1024
    public static let maxCandidates = 100
    private let fetcher: HTTPFetcher

    public init(fetcher: HTTPFetcher = HTTPFetcher()) { self.fetcher = fetcher }

    public func snapshot(_ address: SkillRepositoryAddress) async throws -> SkillRepositorySnapshot {
        struct Repository: Decodable { let default_branch: String }
        struct Commit: Decodable { let sha: String }
        struct Tree: Decodable { let tree: [SkillTreeEntry]; let truncated: Bool }
        let base = URL(string: "https://api.github.com/repos/\(address.slug)")!
        let repo: Repository = try await json(base)
        var refURL = URLComponents(url: base.appendingPathComponent("commits"), resolvingAgainstBaseURL: false)!
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        guard !repo.default_branch.isEmpty, let ref = repo.default_branch.addingPercentEncoding(withAllowedCharacters: allowed) else { throw SkillError("GitHub 默认分支无效。") }
        refURL.percentEncodedPath += "/" + ref
        let commit: Commit = try await json(refURL.url!)
        guard SkillSafety.validSHA(commit.sha) else { throw SkillError("GitHub 返回无效提交。") }
        let treeURL = base.appendingPathComponent("git/trees").appendingPathComponent(commit.sha)
        var components = URLComponents(url: treeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        let tree: Tree = try await json(components.url!)
        guard !tree.truncated else { throw SkillError("GitHub 文件树被截断，请使用较小的仓库。未安装任何内容。") }
        var paths = Set<String>()
        for entry in tree.tree {
            try SkillSafety.validatePath(entry.path)
            guard SkillSafety.validSHA(entry.sha), paths.insert(entry.path).inserted else { throw SkillError("GitHub 文件树含无效或重复条目。") }
        }
        return SkillRepositorySnapshot(repository: address, commit: commit.sha, entries: tree.tree)
    }

    public func candidates(in snapshot: SkillRepositorySnapshot) async throws -> [SkillCandidate] {
        let entries = snapshot.entries.filter { $0.path.split(separator: "/").last == "SKILL.md" }
        guard !entries.isEmpty else { throw SkillError("仓库中没有找到 SKILL.md。") }
        guard entries.count <= Self.maxCandidates else { throw SkillError("候选 skill 超过 100 个，请使用较小的仓库。") }
        var result: [SkillCandidate] = []
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let path = entry.path == "SKILL.md" ? "" : String(entry.path.dropLast("/SKILL.md".count))
            do {
                _ = try snapshot.files(in: path)
                let metadata = try SkillMetadata.parse(await file(entry, in: snapshot))
                result.append(SkillCandidate(path: path, metadata: metadata, problem: nil))
            } catch is CancellationError { throw CancellationError() }
            catch { result.append(SkillCandidate(path: path, metadata: nil, problem: error.localizedDescription)) }
        }
        return result
    }

    public func download(_ path: String, in snapshot: SkillRepositorySnapshot) async throws -> SkillDownload {
        let entries = try snapshot.files(in: path)
        let prefix = path.isEmpty ? "" : path + "/"
        var files: [String: Data] = [:]
        for entry in entries {
            try Task.checkCancellation()
            files[String(entry.path.dropFirst(prefix.count))] = try await file(entry, in: snapshot)
        }
        guard let instructions = files["SKILL.md"] else { throw SkillError("下载缺少 SKILL.md。") }
        return SkillDownload(snapshot: snapshot, path: path, metadata: try SkillMetadata.parse(instructions), files: files)
    }

    private func file(_ entry: SkillTreeEntry, in snapshot: SkillRepositorySnapshot) async throws -> Data {
        guard entry.type == "blob", ["100644", "100755"].contains(entry.mode),
              let size = entry.size, size <= HTTPFetcher.maxBytes else { throw SkillError("不支持或过大的文件：\(entry.path)") }
        var url = URL(string: "https://raw.githubusercontent.com/\(snapshot.repository.slug)/\(snapshot.commit)")!
        for component in entry.path.split(separator: "/") { url.appendPathComponent(String(component)) }
        let data = try await get(url, headers: ["Accept": "application/octet-stream"])
        guard data.count == size, SkillSafety.blobSHA(data) == entry.sha else {
            throw SkillError("下载内容与固定提交不一致：\(entry.path)")
        }
        return data
    }

    private func json<T: Decodable>(_ url: URL) async throws -> T {
        let data = try await get(url, headers: ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"])
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw SkillError("GitHub 返回的数据格式有误。") }
    }

    private func get(_ url: URL, headers: [String: String]) async throws -> Data {
        do { return try await fetcher.get(url, headers: headers.merging(["User-Agent": "PiSwitch"]) { _, new in new }) }
        catch DiscoveryError.http(let status) {
            switch status {
            case 403, 429: throw SkillError("GitHub 访问被拒绝或请求限流（HTTP \(status)），请稍后手动重试。")
            case 404: throw SkillError("仓库或文件不存在，或不是可访问的公开仓库（HTTP 404）。")
            default: throw SkillError("GitHub 请求失败（HTTP \(status)）。")
            }
        }
    }
}
