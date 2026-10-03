import Foundation

public struct ConfigError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { "配置文件无效：\(message)" }
}

public struct ConfigDocument: Equatable, Sendable {
    /// Top-level keys other than `providers`, preserved as-is.
    public var top: [String: JSONValue]
    public var providers: [ProviderDraft]

    public static let empty = ConfigDocument(top: [:], providers: [])

    public init(top: [String: JSONValue], providers: [ProviderDraft]) {
        self.top = top
        self.providers = providers
    }

    public static func parse(_ data: Data) throws -> ConfigDocument {
        let root: JSONValue
        do {
            root = try JSONValue.decode(data)
        } catch {
            throw ConfigError("不是合法的 JSON（\(error.localizedDescription)）")
        }
        guard var top = root.objectValue else { throw ConfigError("顶层必须是对象") }

        var providers: [ProviderDraft] = []
        if let value = top.removeValue(forKey: "providers") {
            guard let dict = value.objectValue else { throw ConfigError("providers 必须是对象") }
            for name in dict.keys.sorted() {
                guard let object = dict[name]?.objectValue else {
                    throw ConfigError("Provider “\(name)”必须是对象")
                }
                providers.append(try ProviderDraft.parse(name: name, object: object))
            }
        }
        return ConfigDocument(top: top, providers: providers)
    }

    /// Validates every edited field and produces the file bytes. Throws the first problem found.
    public func encoded() throws -> Data {
        var dict: [String: JSONValue] = [:]
        for provider in providers {
            let name = provider.name
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ValidationError("Provider 名称不能为空") }
            guard trimmed == name else { throw ValidationError("Provider 名称“\(name)”首尾不能有空白") }
            guard dict[name] == nil else { throw ValidationError("Provider 名称重复：\(name)") }
            dict[name] = try provider.build()
        }
        var object = top
        object["providers"] = .object(dict)
        return try JSONValue.object(object).configurationData()
    }
}
