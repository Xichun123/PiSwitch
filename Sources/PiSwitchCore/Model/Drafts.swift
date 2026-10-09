import Foundation

public struct ValidationError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Text shown in an input, remembering what was loaded. Only edited fields are written back,
/// so untouched values (even of unexpected types) are preserved byte-for-byte in meaning.
public struct FieldText: Equatable, Sendable {
    public let original: String
    public var text: String

    public init(_ value: JSONValue?) {
        switch value {
        case .string(let string)?: original = string
        case .int(let int)?: original = String(int)
        default: original = ""
        }
        text = original
    }

    public init(json value: JSONValue?) {
        let data = value.flatMap { try? $0.prettyData() }
        let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        self.init(.string(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    public var isEdited: Bool { text != original }
    public var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Dictionary where Key == String, Value == JSONValue {
    mutating func apply(string field: FieldText, to key: String) {
        guard field.isEdited else { return }
        let value = field.trimmed
        if value.isEmpty { removeValue(forKey: key) } else { self[key] = .string(value) }
    }

    mutating func apply(positiveInt field: FieldText, to key: String, label: String) throws {
        guard field.isEdited else { return }
        let value = field.trimmed
        if value.isEmpty {
            removeValue(forKey: key)
        } else if let number = Int(value), number > 0 {
            self[key] = .int(number)
        } else {
            throw ValidationError("\(label)必须是正整数（当前为“\(value)”）")
        }
    }

    mutating func apply(json field: FieldText, to key: String) throws {
        guard field.isEdited else { return }
        let text = field.trimmed
        if text.isEmpty {
            removeValue(forKey: key)
            return
        }
        guard let value = try? JSONValue.decode(Data(text.utf8)) else {
            throw ValidationError("\(key) 必须是有效的 JSON（留空可删除）")
        }
        switch key {
        case "reasoning":
            guard value.boolValue != nil else { throw ValidationError("reasoning 必须是 true 或 false") }
        case "input":
            guard let items = value.arrayValue,
                  items.allSatisfy({ $0.stringValue == "text" || $0.stringValue == "image" }) else {
                throw ValidationError("input 必须是仅含 text/image 的 JSON 数组")
            }
        default:
            guard value.objectValue != nil else {
                throw ValidationError("\(key) 必须是 JSON 对象（留空可删除）")
            }
        }
        if key == "thinkingLevelMap", !value.isThinkingLevelMap {
            throw ValidationError("thinkingLevelMap 仅支持 off/minimal/low/medium/high/xhigh/max，值必须是字符串或 null")
        }
        if key == "cost" {
            var costs = [value]
            if let tiers = value["tiers"] {
                guard let items = tiers.arrayValue,
                      items.allSatisfy({
                          guard let threshold = $0["inputTokensAbove"]?.numberValue else { return false }
                          return threshold.isFinite && threshold >= 0
                      }) else {
                    throw ValidationError("cost.tiers 必须是数组，每项 inputTokensAbove 必须是有限非负数字")
                }
                costs += items
            }
            guard costs.allSatisfy({ cost in
                ["input", "output", "cacheRead", "cacheWrite"].allSatisfy { key in
                    guard let price = cost[key]?.numberValue else { return false }
                    return price.isFinite && price >= 0
                }
            }) else {
                throw ValidationError("cost 及每个 tier 的 input/output/cacheRead/cacheWrite 必须是有限非负数字")
            }
        }
        // ponytail: compat validates object shape only; API-specific checks stay with Pi.
        self[key] = value
    }
}

extension JSONValue {
    var isThinkingLevelMap: Bool {
        guard let fields = objectValue else { return false }
        let levels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
        return fields.allSatisfy { levels.contains($0.key) && ($0.value.stringValue != nil || $0.value == .null) }
    }
}

public struct ModelDraft: Identifiable, Equatable, Sendable {
    public static let defaultUserAgent = "claude-cli/2.1.295 (external, cli)"

    public let uid: UUID
    public var id: UUID { uid }

    public var raw: [String: JSONValue]
    public var modelID: FieldText
    public var name: FieldText
    public var api: FieldText
    public var baseUrl: FieldText
    public var userAgentEnabled: Bool
    public var userAgent: FieldText
    public var reasoning: FieldText
    public var input: FieldText
    public var cost: FieldText
    public var contextWindow: FieldText
    public var maxTokens: FieldText
    public var thinkingLevelMap: FieldText
    public var compat: FieldText

    public init(json: [String: JSONValue]) {
        uid = UUID()
        raw = json
        modelID = FieldText(json["id"])
        name = FieldText(json["name"])
        api = FieldText(json["api"])
        baseUrl = FieldText(json["baseUrl"])
        let userAgentKey = json["headers"]?.objectValue?.keys.sorted().first { $0.lowercased() == "user-agent" }
        userAgentEnabled = userAgentKey != nil
        userAgent = FieldText(userAgentKey.flatMap { json["headers"]?[$0] })
        reasoning = FieldText(json: json["reasoning"])
        input = FieldText(json: json["input"])
        cost = FieldText(json: json["cost"])
        contextWindow = FieldText(json["contextWindow"])
        maxTokens = FieldText(json["maxTokens"])
        thinkingLevelMap = FieldText(json: json["thinkingLevelMap"])
        compat = FieldText(json: json["compat"])
    }

    public var currentID: String { modelID.trimmed }

    public mutating func setUserAgentEnabled(_ enabled: Bool) {
        userAgentEnabled = enabled
        if enabled, userAgent.trimmed.isEmpty {
            userAgent.text = Self.defaultUserAgent
        }
    }

    public mutating func apply(_ entry: CatalogEntry) {
        name.text = entry.name
        contextWindow.text = String(entry.contextWindow)
        maxTokens.text = String(entry.maxTokens)
        reasoning.text = entry.reasoning ? "true" : "false"
        input.text = FieldText(json: .array(entry.input.map(JSONValue.string))).text
        cost.text = FieldText(json: entry.cost).text
        if let value = entry.thinkingLevelMap { thinkingLevelMap.text = FieldText(json: value).text }
        if let value = entry.compat { compat.text = FieldText(json: value).text }
    }

    public func resolvedBaseURL(providerAPI: String, providerBaseURL: String) -> String {
        let effectiveAPI = api.trimmed.isEmpty ? providerAPI : api.trimmed
        if !baseUrl.trimmed.isEmpty {
            return ProviderDraft.normalizedBaseURL(baseUrl.text, api: effectiveAPI)
        }
        guard !api.trimmed.isEmpty else { return baseUrl.text }
        let inherited = ProviderDraft.normalizedBaseURL(providerBaseURL, api: providerAPI)
        let resolved = ProviderDraft.normalizedBaseURL(inherited, api: effectiveAPI)
        return resolved == inherited ? baseUrl.text : resolved
    }

    func build(providerName: String, index: Int, providerAPI: String = "", providerBaseURL: String = "") throws -> JSONValue {
        var address = baseUrl
        address.text = resolvedBaseURL(providerAPI: providerAPI, providerBaseURL: providerBaseURL)
        let id = currentID
        guard !id.isEmpty else {
            throw ValidationError("“\(providerName)”的第 \(index + 1) 个模型 ID 为空")
        }
        var object = raw
        if modelID.isEdited { object["id"] = .string(id) }
        if address.isEdited, !address.trimmed.isEmpty, !ProviderDraft.isValidBaseURL(address.trimmed) {
            throw ValidationError("“\(id)”的模型地址必须是带主机名的 http/https URL")
        }
        object.apply(string: name, to: "name")
        object.apply(string: api, to: "api")
        object.apply(string: address, to: "baseUrl")
        let hadUserAgent = raw["headers"]?.objectValue?.keys.contains { $0.lowercased() == "user-agent" } ?? false
        if userAgent.isEdited || userAgentEnabled != hadUserAgent {
            if let existing = raw["headers"], existing.objectValue == nil {
                throw ValidationError("“\(id)”的 headers 必须是 JSON 对象，无法修改 User-Agent")
            }
            var headers = raw["headers"]?.objectValue ?? [:]
            headers = headers.filter { $0.key.lowercased() != "user-agent" }
            if userAgentEnabled {
                guard !userAgent.trimmed.isEmpty,
                      userAgent.text.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else {
                    throw ValidationError("“\(id)”的 User-Agent 不能为空或包含换行及控制字符")
                }
                headers["User-Agent"] = .string(userAgent.trimmed)
            }
            object["headers"] = headers.isEmpty ? nil : .object(headers)
        }
        try object.apply(positiveInt: contextWindow, to: "contextWindow", label: "“\(id)”的上下文窗口")
        try object.apply(positiveInt: maxTokens, to: "maxTokens", label: "“\(id)”的最大输出")
        try object.apply(json: reasoning, to: "reasoning")
        try object.apply(json: input, to: "input")
        try object.apply(json: cost, to: "cost")
        try object.apply(json: thinkingLevelMap, to: "thinkingLevelMap")
        try object.apply(json: compat, to: "compat")
        return .object(object)
    }
}

public struct ProviderDraft: Identifiable, Equatable, Sendable {
    public static let managedKeys: Set<String> = ["baseUrl", "api", "apiKey", "models"]

    public let uid: UUID
    public var id: UUID { uid }

    /// Original provider object without `models`.
    public var raw: [String: JSONValue]
    public let hadModelsKey: Bool
    public var name: String
    public var baseUrl: FieldText
    public var api: FieldText
    public var apiKey: FieldText
    public var models: [ModelDraft]

    init(name: String, raw: [String: JSONValue], hadModelsKey: Bool, models: [ModelDraft]) {
        uid = UUID()
        self.raw = raw
        self.hadModelsKey = hadModelsKey
        self.name = name
        baseUrl = FieldText(raw["baseUrl"])
        api = FieldText(raw["api"])
        apiKey = FieldText(raw["apiKey"])
        self.models = models
    }

    public static func new(named name: String) -> ProviderDraft {
        ProviderDraft(name: name, raw: [:], hadModelsKey: false, models: [])
    }

    public var unmanagedKeys: [String] {
        raw.keys.filter { !Self.managedKeys.contains($0) }.sorted()
    }

    public var usesInsecureHTTP: Bool {
        baseUrl.trimmed.lowercased().hasPrefix("http://")
    }

    static func parse(name: String, object: [String: JSONValue]) throws -> ProviderDraft {
        var raw = object
        let hadModelsKey = raw["models"] != nil
        var models: [ModelDraft] = []
        if let value = raw.removeValue(forKey: "models") {
            guard let items = value.arrayValue else {
                throw ConfigError("“\(name)”的 models 必须是数组")
            }
            for (index, item) in items.enumerated() {
                let position = "“\(name)”的第 \(index + 1) 个模型"
                guard let model = item.objectValue else { throw ConfigError("\(position)必须是对象") }
                guard let id = model["id"]?.stringValue,
                      !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ConfigError("\(position)缺少非空字符串 id")
                }
                for key in ["contextWindow", "maxTokens"] {
                    if let value = model[key], value.intValue == nil {
                        throw ConfigError("\(position)的 \(key) 必须是整数")
                    }
                }
                models.append(ModelDraft(json: model))
            }
        }
        return ProviderDraft(name: name, raw: raw, hadModelsKey: hadModelsKey, models: models)
    }

    static func isValidBaseURL(_ string: String) -> Bool {
        guard let components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return false }
        return true
    }

    // ponytail: conventional terminal /v1 only; custom protocol/endpoint rules stay manual.
    public static func normalizedBaseURL(_ string: String, api: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let kind = DiscoveryProtocol(api: api), isValidBaseURL(trimmed),
              var components = URLComponents(string: trimmed) else { return string }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/v1") { path.removeLast(3) }
        if kind == .openAI { path += "/v1" }
        components.percentEncodedPath = path
        return components.string ?? string
    }

    public mutating func normalizeConnections() {
        baseUrl.text = Self.normalizedBaseURL(baseUrl.text, api: api.trimmed)
        for index in models.indices {
            models[index].baseUrl.text = models[index].resolvedBaseURL(
                providerAPI: api.trimmed, providerBaseURL: baseUrl.text)
        }
    }

    func build() throws -> JSONValue {
        var address = baseUrl
        address.text = Self.normalizedBaseURL(baseUrl.text, api: api.trimmed)
        var object = raw
        if address.isEdited, !address.trimmed.isEmpty, !Self.isValidBaseURL(address.trimmed) {
            throw ValidationError("“\(name)”的地址必须是带主机名的 http/https URL")
        }
        object.apply(string: address, to: "baseUrl")
        object.apply(string: api, to: "api")
        object.apply(string: apiKey, to: "apiKey")

        var seen = Set<String>()
        var built: [JSONValue] = []
        for (index, model) in models.enumerated() {
            let value = try model.build(providerName: name, index: index,
                                        providerAPI: api.trimmed, providerBaseURL: address.text)
            guard seen.insert(model.currentID).inserted else {
                throw ValidationError("“\(name)”中模型 ID 重复：\(model.currentID)")
            }
            built.append(value)
        }
        if hadModelsKey || !built.isEmpty { object["models"] = .array(built) }
        return .object(object)
    }
}
