import Foundation

public enum DiscoveryProtocol: Sendable, Equatable {
    case openAI
    case anthropic

    public init?(api: String) {
        switch api.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "openai-completions", "openai-responses": self = .openAI
        case "anthropic-messages": self = .anthropic
        default: return nil
        }
    }
}

public enum APIKeyKind: Equatable, Sendable {
    case empty
    case literal
    case command
    case environmentVariable

    public init(_ key: String) {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            self = .empty
        } else if value.hasPrefix("!") {
            self = .command
        } else if value.range(of: #"^[A-Z_][A-Z0-9_]*$"#, options: .regularExpression) != nil {
            self = .environmentVariable
        } else {
            self = .literal
        }
    }

    public var allowsDiscovery: Bool { self == .empty || self == .literal }
}

public struct ModelListClient: Sendable {
    public static let maxPages = 50

    let fetcher: HTTPFetcher

    public init(fetcher: HTTPFetcher) {
        self.fetcher = fetcher
    }

    public static func modelsURL(baseUrl: String, kind: DiscoveryProtocol) throws -> URL {
        let api = kind == .openAI ? "openai-completions" : "anthropic-messages"
        let base = ProviderDraft.normalizedBaseURL(baseUrl, api: api)
        guard ProviderDraft.isValidBaseURL(base),
              var components = URLComponents(string: base) else {
            throw DiscoveryError.invalidBaseURL
        }
        components.percentEncodedPath += kind == .anthropic ? "/v1/models" : "/models"
        guard let url = components.url else { throw DiscoveryError.invalidBaseURL }
        return url
    }

    public func fetchIDs(baseUrl: String, apiKey: String, kind: DiscoveryProtocol) async throws -> [String] {
        guard APIKeyKind(apiKey).allowsDiscovery else { throw DiscoveryError.nonLiteralKey }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = try Self.modelsURL(baseUrl: baseUrl, kind: kind)

        var ids: [String] = []
        var seen = Set<String>()
        func collect(_ page: [String]) {
            for raw in page {
                let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !id.isEmpty, seen.insert(id).inserted { ids.append(id) }
            }
        }

        switch kind {
        case .openAI:
            let headers = key.isEmpty ? [:] : ["Authorization": "Bearer \(key)"]
            collect(try Self.parsePage(try await fetcher.get(url, headers: headers)).ids)
            return ids

        case .anthropic:
            var headers = ["anthropic-version": "2023-06-01"]
            if !key.isEmpty { headers["x-api-key"] = key }
            var cursor: String?
            var usedCursors = Set<String>()
            for _ in 0..<Self.maxPages {
                try Task.checkCancellation()
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                var query = components.queryItems ?? []
                query.append(URLQueryItem(name: "limit", value: "1000"))
                if let cursor { query.append(URLQueryItem(name: "after_id", value: cursor)) }
                components.queryItems = query

                let page = try Self.parsePage(try await fetcher.get(components.url!, headers: headers))
                collect(page.ids)
                guard page.hasMore else { return ids }
                guard let last = page.lastID, !last.isEmpty else {
                    throw DiscoveryError.pagination("has_more 为 true 但缺少 last_id")
                }
                guard usedCursors.insert(last).inserted else {
                    throw DiscoveryError.pagination("游标重复（\(last)）")
                }
                cursor = last
            }
            throw DiscoveryError.pagination("超过 \(Self.maxPages) 页上限")
        }
    }

    static func parsePage(_ data: Data) throws -> (ids: [String], hasMore: Bool, lastID: String?) {
        guard let root = try? JSONValue.decode(data), let items = root["data"]?.arrayValue else {
            throw DiscoveryError.badFormat("没有 data 数组")
        }
        var ids: [String] = []
        for item in items {
            guard let id = item["id"]?.stringValue else {
                throw DiscoveryError.badFormat("data 中有条目缺少字符串 id")
            }
            ids.append(id)
        }
        return (ids, root["has_more"]?.boolValue ?? false, root["last_id"]?.stringValue)
    }
}
