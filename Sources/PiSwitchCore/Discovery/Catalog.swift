import Foundation

public struct CatalogEntry: Identifiable, Equatable, Sendable {
    public let provider: String
    public let modelID: String
    public let name: String
    public let api: String?
    public let baseUrl: String?
    public let contextWindow: Int
    public let maxTokens: Int
    public let reasoning: Bool
    public let input: [String]
    /// Copied verbatim (may contain `tiers`); only required to be an object.
    public let cost: JSONValue
    public let thinkingLevelMap: JSONValue?
    public let compat: JSONValue?

    public var id: String { "\(provider)/\(modelID)" }

    init?(provider: String, json: JSONValue) {
        guard let id = json["id"]?.stringValue, !id.isEmpty,
              let name = json["name"]?.stringValue, !name.isEmpty,
              let contextWindow = json["contextWindow"]?.intValue, contextWindow > 0,
              let maxTokens = json["maxTokens"]?.intValue, maxTokens > 0,
              let reasoning = json["reasoning"]?.boolValue,
              let inputValues = json["input"]?.arrayValue,
              let cost = json["cost"], cost.objectValue != nil else { return nil }
        let input = inputValues.compactMap(\.stringValue)
        guard input.count == inputValues.count else { return nil }
        let api = json["api"]?.stringValue
        let baseUrl = json["baseUrl"]?.stringValue
        if json["api"] != nil, api?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { return nil }
        if json["baseUrl"] != nil, baseUrl.map(ProviderDraft.isValidBaseURL) != true { return nil }
        let thinkingLevelMap = json["thinkingLevelMap"]
        let compat = json["compat"]
        if let thinkingLevelMap, !thinkingLevelMap.isThinkingLevelMap { return nil }
        if let compat, compat.objectValue == nil { return nil }

        self.provider = provider
        self.modelID = id
        self.name = name
        self.api = api
        self.baseUrl = baseUrl
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.reasoning = reasoning
        self.input = input
        self.cost = cost
        self.thinkingLevelMap = thinkingLevelMap
        self.compat = compat
    }

    public var fields: [String: JSONValue] {
        var result: [String: JSONValue] = [
            "name": .string(name),
            "contextWindow": .int(contextWindow),
            "maxTokens": .int(maxTokens),
            "reasoning": .bool(reasoning),
            "input": .array(input.map(JSONValue.string)),
            "cost": cost,
        ]
        // Model connections inherit the configured provider, not the catalog endpoint.
        result["thinkingLevelMap"] = thinkingLevelMap
        result["compat"] = compat
        return result
    }

    public var summary: String {
        var parts = [
            "上下文 \(DisplayFormat.tokens(contextWindow))",
            "输出 \(DisplayFormat.tokens(maxTokens))",
        ]
        if let input = cost["input"]?.numberValue, let output = cost["output"]?.numberValue {
            parts.append("\(DisplayFormat.price(input)) / \(DisplayFormat.price(output)) 每百万")
        }
        if reasoning { parts.append("推理") }
        if input.contains("image") { parts.append("图像") }
        return parts.joined(separator: " · ")
    }
}

public enum Catalog {
    public static let url = URL(string: "https://pi.dev/api/models")!

    /// Order is priority: the first provider listing an ID wins.
    public static let providers = [
        "anthropic", "openai", "google", "deepseek", "xai",
        "moonshotai", "zai", "minimax", "xiaomi", "qwen-token-plan-individual",
    ]

    public static func fetch(using fetcher: HTTPFetcher) async throws -> [CatalogEntry] {
        try parse(try await fetcher.get(url))
    }

    public static func parse(_ data: Data) throws -> [CatalogEntry] {
        guard let root = try? JSONValue.decode(data), let byProvider = root.objectValue else {
            throw DiscoveryError.badFormat("目录不是对象")
        }
        var entries: [CatalogEntry] = []
        var seen = Set<String>()
        for provider in providers {
            guard let models = byProvider[provider]?.objectValue else { continue }
            for key in models.keys.sorted() {
                guard let entry = CatalogEntry(provider: provider, json: models[key]!),
                      seen.insert(entry.modelID).inserted else { continue }
                entries.append(entry)
            }
        }
        return entries
    }
}

public struct ImportChoice: Equatable, Sendable {
    public let modelID: String
    public let entry: CatalogEntry?

    public init(modelID: String, entry: CatalogEntry?) {
        self.modelID = modelID
        self.entry = entry
    }
}

public enum ModelMerge {
    /// Never touches provider-level fields and never removes existing models.
    public static func merge(_ models: [ModelDraft], importing choices: [ImportChoice]) -> [ModelDraft] {
        var result = models
        for choice in choices {
            if let index = result.firstIndex(where: { $0.currentID == choice.modelID }) {
                if let entry = choice.entry { result[index].apply(entry) }
            } else {
                var json: [String: JSONValue] = ["id": .string(choice.modelID)]
                if let entry = choice.entry { json.merge(entry.fields) { _, new in new } }
                result.append(ModelDraft(json: json))
            }
        }
        return result
    }
}

public enum DisplayFormat {
    public static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return count % 1_000_000 == 0 ? "\(count / 1_000_000)M" : String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return count % 1_000 == 0 ? "\(count / 1_000)K" : String(format: "%.1fK", Double(count) / 1_000)
        }
        return String(count)
    }

    public static func price(_ value: Double) -> String {
        "$" + String(format: "%g", value)
    }
}
