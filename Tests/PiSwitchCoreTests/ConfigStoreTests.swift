import Foundation
@testable import PiSwitchCore
import XCTest

final class ConfigStoreTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("agent/models.json") }
    private var store: ConfigStore { ConfigStore(path: file) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("piswitch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String, to url: URL? = nil) throws {
        let target = url ?? file
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target)
    }

    private func readJSON(_ url: URL? = nil) throws -> JSONValue {
        try JSONValue.decode(Data(contentsOf: url ?? file))
    }

    private func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private let sample = """
    {
      "extra": {"keep": true},
      "providers": {
        "proxy": {
          "baseUrl": "https://api.example.com/v1",
          "api": "openai-completions",
          "apiKey": "sk-test",
          "headers": {"X-A": "1"},
          "compat": {"flag": true, "n": 3, "ratio": 0.5},
          "models": [
            {"id": "m1", "name": "Model 1", "contextWindow": 128000, "maxTokens": 8192,
             "reasoning": false, "cost": {"input": 1, "output": 2.5}}
          ]
        }
      }
    }
    """

    // 1. Unknown fields keep value and type.
    func testUnknownFieldsPreserved() throws {
        try write(sample)
        let loaded = try store.load()
        var document = loaded.document
        document.providers[0].models[0].name.text = "Renamed"
        try store.save(document, baseline: loaded.baseline)

        let json = try readJSON()
        XCTAssertEqual(json["extra"], .object(["keep": .bool(true)]))
        let provider = json["providers"]?["proxy"]
        XCTAssertEqual(provider?["compat"], .object(["flag": .bool(true), "n": .int(3), "ratio": .double(0.5)]))
        XCTAssertEqual(provider?["headers"], .object(["X-A": .string("1")]))
        let model = provider?["models"]?.arrayValue?.first
        XCTAssertEqual(model?["name"], .string("Renamed"))
        XCTAssertEqual(model?["contextWindow"], .int(128000))
        XCTAssertEqual(model?["reasoning"], .bool(false))
        XCTAssertEqual(model?["cost"], .object(["input": .int(1), "output": .double(2.5)]))
    }

    func testImportedCostSavedAndRetained() throws {
        try write(sample)
        let loaded = try store.load()
        var document = loaded.document
        let cost = try JSONValue.decode(Data("""
        {
          "input": 2, "output": 10, "cacheRead": 0.1, "cacheWrite": 2.5,
          "tiers": [
            {"inputTokensAbove": 272000, "input": 4, "output": 15,
             "cacheRead": 0.2, "cacheWrite": 5}
          ],
          "future": {"keep": true}
        }
        """.utf8))
        let entry = try XCTUnwrap(CatalogEntry(provider: "catalog", json: .object([
            "id": .string("m1"), "name": .string("Catalog Model"),
            "contextWindow": .int(272000), "maxTokens": .int(128000),
            "reasoning": .bool(true), "input": .array([.string("text")]),
            "cost": cost,
        ])))
        document.providers[0].models = ModelMerge.merge(document.providers[0].models, importing: [
            ImportChoice(modelID: "m1", entry: entry),
            ImportChoice(modelID: "new-model", entry: entry),
            ImportChoice(modelID: "id-only", entry: nil),
        ])
        for model in document.providers[0].models.prefix(2) {
            XCTAssertEqual(try JSONValue.decode(Data(model.cost.text.utf8)), cost)
        }
        try store.save(document, baseline: loaded.baseline)
        let savedModels = try XCTUnwrap(try readJSON()["providers"]?["proxy"]?["models"]?.arrayValue)
        XCTAssertEqual(savedModels[0]["cost"], cost)
        XCTAssertEqual(savedModels[1]["cost"], cost)
        XCTAssertNil(savedModels[2]["cost"])

        let reloaded = try store.load()
        document = reloaded.document
        document.providers[0].models[0].name.text = "Renamed"
        document.providers[0].models = ModelMerge.merge(document.providers[0].models, importing: [
            ImportChoice(modelID: "m1", entry: nil),
        ])
        try store.save(document, baseline: reloaded.baseline)
        let retainedModels = try XCTUnwrap(try readJSON()["providers"]?["proxy"]?["models"]?.arrayValue)
        XCTAssertEqual(retainedModels[0]["name"], .string("Renamed"))
        XCTAssertEqual(retainedModels[0]["cost"], cost)
        XCTAssertEqual(retainedModels[1]["cost"], cost)
        XCTAssertNil(retainedModels[2]["cost"])
    }

    func testFullModelMetadataAndConnectionOverrides() throws {
        let metadata = """
        {
          "id": "grok-4.7", "name": "Grok 4.7",
          "api": "openai-responses", "baseUrl": "https://api.x.ai/v1",
          "reasoning": true, "input": ["text", "image"],
          "thinkingLevelMap": {
            "off": null, "minimal": null, "low": "low", "medium": "medium",
            "high": "high", "xhigh": "xhigh", "max": null
          },
          "contextWindow": 500000, "maxTokens": 500000,
          "cost": {
            "input": 2, "output": 6, "cacheRead": 0.5, "cacheWrite": 0,
            "tiers": [{"inputTokensAbove": 200000, "input": 4, "output": 12,
                       "cacheRead": 1, "cacheWrite": 0}]
          },
          "compat": {"supportsLongCacheRetention": false}
        }
        """
        var expectedFields = try XCTUnwrap(JSONValue.decode(Data(metadata.utf8)).objectValue)
        expectedFields.removeValue(forKey: "api")
        expectedFields.removeValue(forKey: "baseUrl")
        let expected = JSONValue.object(expectedFields)
        let entry = try XCTUnwrap(Catalog.parse(Data("""
        {"xai": {"grok-4.7": \(metadata)}}
        """.utf8)).first)
        try write(sample)
        let loaded = try store.load()
        var document = loaded.document
        document.providers[0].models = ModelMerge.merge(document.providers[0].models, importing: [
            ImportChoice(modelID: "grok-4.7", entry: entry),
            ImportChoice(modelID: "m1", entry: entry),
        ])
        try store.save(document, baseline: loaded.baseline)
        let provider = try XCTUnwrap(try readJSON()["providers"]?["proxy"])
        let models = try XCTUnwrap(provider["models"]?.arrayValue)
        var alias = try XCTUnwrap(expected.objectValue)
        alias["id"] = .string("m1")
        XCTAssertEqual(models, [.object(alias), expected])
        XCTAssertEqual(provider["api"], .string("openai-completions"))
        XCTAssertEqual(provider["baseUrl"], .string("https://api.example.com/v1"))
        XCTAssertEqual(provider["apiKey"], .string("sk-test"))

        let reloaded = try store.load()
        document = reloaded.document
        XCTAssertEqual(document.providers[0].models[0].api.text, "")
        XCTAssertEqual(document.providers[0].models[0].baseUrl.text, "")
        for invalidURL in ["ftp://example.com", "not a url", "https://"] {
            var bad = document
            bad.providers[0].models[0].baseUrl.text = invalidURL
            XCTAssertThrowsError(try store.save(bad, baseline: reloaded.baseline))
            XCTAssertEqual(try Data(contentsOf: file), reloaded.baseline)
        }

        document.providers[0].models[0].api.text = "custom-extension-api"
        document.providers[0].models[0].baseUrl.text = "https://model.example.com/v1"
        let editedBaseline = try store.save(document, baseline: reloaded.baseline)
        let edited = try XCTUnwrap(try readJSON()["providers"]?["proxy"]?["models"]?.arrayValue?.first)
        alias["api"] = .string("custom-extension-api")
        alias["baseUrl"] = .string("https://model.example.com/v1")
        XCTAssertEqual(edited, .object(alias))

        document.providers[0].models[0].api.text = "  "
        document.providers[0].models[0].baseUrl.text = ""
        try store.save(document, baseline: editedBaseline)
        let cleared = try XCTUnwrap(try readJSON()["providers"]?["proxy"]?["models"]?.arrayValue?.first)
        alias.removeValue(forKey: "api")
        alias.removeValue(forKey: "baseUrl")
        XCTAssertEqual(cleared, .object(alias))
    }

    func testEditableModelMetadata() throws {
        try write(sample)
        let loaded = try store.load()
        var document = loaded.document
        // Untouched legacy prices need not contain all four rates.
        XCTAssertEqual(try JSONValue.decode(document.encoded()), try JSONValue.decode(Data(sample.utf8)))
        XCTAssertEqual(document.providers[0].models[0].reasoning.text, "false")
        XCTAssertEqual(document.providers[0].models[0].input.text, "")
        let costText = """
        {
          "input": 0, "output": 3, "cacheRead": 0, "cacheWrite": 0.5,
          "tiers": [{"inputTokensAbove": 200000, "input": 4, "output": 12,
                     "cacheRead": 1, "cacheWrite": 0}],
          "future": {"keep": true}
        }
        """
        document.providers[0].models[0].reasoning.text = "true"
        document.providers[0].models[0].input.text = #"["text","image"]"#
        document.providers[0].models[0].cost.text = costText
        try store.save(document, baseline: loaded.baseline)
        let savedModel = try XCTUnwrap(try readJSON()["providers"]?["proxy"]?["models"]?.arrayValue?.first)
        XCTAssertEqual(savedModel["reasoning"], .bool(true))
        XCTAssertEqual(savedModel["input"], .array([.string("text"), .string("image")]))
        XCTAssertEqual(savedModel["cost"], try JSONValue.decode(Data(costText.utf8)))

        let reloaded = try store.load()
        document = reloaded.document
        XCTAssertEqual(document.providers[0].models[0].reasoning.text, "true")
        XCTAssertEqual(try JSONValue.decode(Data(document.providers[0].models[0].input.text.utf8)), savedModel["input"])
        XCTAssertEqual(try JSONValue.decode(Data(document.providers[0].models[0].cost.text.utf8)), savedModel["cost"])

        let invalidFields: [(WritableKeyPath<ModelDraft, FieldText>, [String])] = [
            (\.reasoning, ["{", "null", "1", #""true""#]),
            (\.input, ["{", "null", "true", #"["audio"]"#, #"["text",1]"#]),
            (\.cost, ["{", "[]", "null", "{}", #"{"input":1,"output":2}"#,
                      #"{"input":"1","output":2,"cacheRead":0,"cacheWrite":0}"#,
                      #"{"input":-1,"output":2,"cacheRead":0,"cacheWrite":0}"#,
                      #"{"input":1,"output":2,"cacheRead":0,"cacheWrite":0,"tiers":{}}"#,
                      #"{"input":1,"output":2,"cacheRead":0,"cacheWrite":0,"tiers":[{}]}"#,
                      #"{"input":1,"output":2,"cacheRead":0,"cacheWrite":0,"tiers":[{"inputTokensAbove":-1,"input":0,"output":0,"cacheRead":0,"cacheWrite":0}]}"#,
                      #"{"input":1,"output":2,"cacheRead":0,"cacheWrite":0,"tiers":[{"inputTokensAbove":1,"input":0,"output":"0","cacheRead":0,"cacheWrite":0}]}"#]),
        ]
        for (field, values) in invalidFields {
            for value in values {
                var bad = document
                bad.providers[0].models[0][keyPath: field].text = value
                XCTAssertThrowsError(try store.save(bad, baseline: reloaded.baseline), value)
                XCTAssertEqual(try Data(contentsOf: file), reloaded.baseline)
            }
        }

        document.providers[0].models[0].reasoning.text = "false"
        document.providers[0].models[0].input.text = "[]"
        document.providers[0].models[0].cost.text = #"{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"tiers":[]}"#
        document.providers[0].models = ModelMerge.merge(document.providers[0].models, importing: [
            ImportChoice(modelID: "m1", entry: nil),
        ])
        let baseline = try store.save(document, baseline: reloaded.baseline)
        let editedModel = try XCTUnwrap(try readJSON()["providers"]?["proxy"]?["models"]?.arrayValue?.first)
        XCTAssertEqual(editedModel["reasoning"], .bool(false))
        XCTAssertEqual(editedModel["input"], .array([]))
        XCTAssertEqual(editedModel["cost"]?["input"], .int(0))

        let entry = try XCTUnwrap(CatalogEntry(provider: "catalog", json: savedModel))
        document.providers[0].models = ModelMerge.merge(document.providers[0].models, importing: [
            ImportChoice(modelID: "m1", entry: entry),
        ])
        let importedBaseline = try store.save(document, baseline: baseline)
        XCTAssertEqual(try readJSON()["providers"]?["proxy"]?["models"]?.arrayValue?.first, savedModel)

        document.providers[0].models[0].reasoning.text = ""
        document.providers[0].models[0].input.text = "  "
        document.providers[0].models[0].cost.text = ""
        try store.save(document, baseline: importedBaseline)
        let cleared = try readJSON()["providers"]?["proxy"]?["models"]?.arrayValue?.first
        XCTAssertNil(cleared?["reasoning"])
        XCTAssertNil(cleared?["input"])
        XCTAssertNil(cleared?["cost"])
        let missing = try store.load().document.providers[0].models[0]
        XCTAssertEqual(missing.reasoning.text, "")
        XCTAssertEqual(missing.input.text, "")
        XCTAssertEqual(missing.cost.text, "")
    }

    func testConfigurationFieldOrder() throws {
        let expected = #"""
        {
          "providers": {
            "CLIProxy": {
              "api": "openai-responses",
              "apiKey": "TEST_KEY",
              "baseUrl": "https://proxy.example/v1",
              "models": [
                {
                  "id": "z-model",
                  "name": "Grok \"quoted\"\n测试",
                  "api": "openai-responses",
                  "baseUrl": "https://model.example/v1",
                  "reasoning": true,
                  "input": [
                    "text",
                    "image"
                  ],
                  "thinkingLevelMap": {
                    "off": null,
                    "minimal": null,
                    "low": "low",
                    "medium": "medium",
                    "high": "high",
                    "xhigh": "xhigh",
                    "max": null
                  },
                  "contextWindow": 500000,
                  "maxTokens": 500000,
                  "cost": {
                    "input": 2,
                    "output": 6,
                    "cacheRead": 0.5,
                    "cacheWrite": 0,
                    "tiers": [
                      {
                        "inputTokensAbove": 200000,
                        "input": 4,
                        "output": 12,
                        "cacheRead": 1,
                        "cacheWrite": 0,
                        "extra": false
                      }
                    ],
                    "future": {
                      "keep": true
                    }
                  },
                  "compat": {
                    "supportsLongCacheRetention": false
                  },
                  "extra": {
                    "cost": {
                      "cacheRead": 0,
                      "input": 2
                    },
                    "quote\"key": "backslash\\slash/path\nnewline"
                  }
                },
                {
                  "id": "a-model",
                  "name": "No overrides",
                  "reasoning": false,
                  "input": [],
                  "thinkingLevelMap": {},
                  "compat": {}
                }
              ],
              "headers": {
                "api": "keep",
                "cost": "keep"
              }
            },
            "Other": {
              "models": []
            }
          },
          "extra": {
            "largeInteger": 9007199254740993
          }
        }
        """# + "\n"
        // Start with the old alphabetical output, not an already ordered file.
        let original = try JSONValue.decode(Data(expected.utf8))
        let unordered = try original.prettyData()
        XCTAssertNotEqual(unordered, Data(expected.utf8))
        try write(String(decoding: unordered, as: UTF8.self))
        let loaded = try store.load()
        let ordered = try store.save(loaded.document, baseline: loaded.baseline)
        XCTAssertEqual(ordered, Data(expected.utf8))
        XCTAssertEqual(try Data(contentsOf: file), Data(expected.utf8))
        XCTAssertEqual(try JSONValue.decode(ordered), original)

        let reloaded = try store.load()
        XCTAssertEqual(try store.save(reloaded.document, baseline: reloaded.baseline), ordered)
        var invalid = reloaded.document
        invalid.top["nonfinite"] = .double(.infinity)
        XCTAssertThrowsError(try store.save(invalid, baseline: ordered))
        XCTAssertEqual(try Data(contentsOf: file), ordered)
    }

    func testProtocolConnections() throws {
        let cases: [(String, String, String)] = [
            ("https://proxy.example", "openai-completions", "https://proxy.example/v1"),
            ("https://proxy.example/v1/", "openai-responses", "https://proxy.example/v1"),
            ("https://proxy.example/v1", "anthropic-messages", "https://proxy.example"),
            ("https://proxy.example/prefix/v1///", "anthropic-messages", "https://proxy.example/prefix"),
            ("https://proxy.example:8443/prefix%2Fpart/v1?key=1#x", "anthropic-messages",
             "https://proxy.example:8443/prefix%2Fpart?key=1#x"),
            ("https://proxy.example/v1beta", "anthropic-messages", "https://proxy.example/v1beta"),
            ("https://proxy.example/v1/", "custom-api", "https://proxy.example/v1/"),
            ("", "openai-responses", ""),
            ("ftp://proxy.example/v1", "anthropic-messages", "ftp://proxy.example/v1"),
        ]
        for (url, api, expected) in cases {
            let normalized = ProviderDraft.normalizedBaseURL(url, api: api)
            XCTAssertEqual(normalized, expected)
            XCTAssertEqual(ProviderDraft.normalizedBaseURL(normalized, api: api), expected)
        }

        try write(sample)
        let loaded = try store.load()
        var document = loaded.document
        document.providers[0].api.text = "openai-responses"
        document.providers[0].baseUrl.text = "https://proxy.example/gateway"
        var baseline = try store.save(document, baseline: loaded.baseline)
        var provider = try XCTUnwrap(try readJSON()["providers"]?["proxy"])
        XCTAssertEqual(provider["baseUrl"], .string("https://proxy.example/gateway/v1"))
        XCTAssertNil(provider["models"]?.arrayValue?.first?["api"])
        XCTAssertNil(provider["models"]?.arrayValue?.first?["baseUrl"])

        document.providers[0].models[0].api.text = "openai-completions"
        XCTAssertEqual(document.providers[0].models[0].resolvedBaseURL(
            providerAPI: "openai-responses", providerBaseURL: "https://proxy.example/gateway/v1"), "")
        document.providers[0].models[0].api.text = "anthropic-messages"
        baseline = try store.save(document, baseline: baseline)
        provider = try XCTUnwrap(try readJSON()["providers"]?["proxy"])
        XCTAssertEqual(provider["baseUrl"], .string("https://proxy.example/gateway/v1"))
        XCTAssertEqual(provider["models"]?.arrayValue?.first?["api"], .string("anthropic-messages"))
        XCTAssertEqual(provider["models"]?.arrayValue?.first?["baseUrl"], .string("https://proxy.example/gateway"))

        document = try store.load().document
        document.providers[0].models[0].api.text = "openai-completions"
        document.providers[0].normalizeConnections()
        XCTAssertEqual(document.providers[0].models[0].baseUrl.text, "https://proxy.example/gateway/v1")
        baseline = try store.save(document, baseline: baseline)
        document.providers[0].models[0].api.text = ""
        document.providers[0].models[0].baseUrl.text = ""
        baseline = try store.save(document, baseline: baseline)
        provider = try XCTUnwrap(try readJSON()["providers"]?["proxy"])
        XCTAssertNil(provider["models"]?.arrayValue?.first?["api"])
        XCTAssertNil(provider["models"]?.arrayValue?.first?["baseUrl"])

        document.providers[0].api.text = "anthropic-messages"
        document.providers[0].models[0].api.text = "openai-responses"
        document.providers[0].normalizeConnections()
        XCTAssertEqual(document.providers[0].baseUrl.text, "https://proxy.example/gateway")
        XCTAssertEqual(document.providers[0].models[0].baseUrl.text, "https://proxy.example/gateway/v1")
        baseline = try store.save(document, baseline: baseline)

        document.providers[0].models[0].api.text = "anthropic-messages"
        document.providers[0].models[0].baseUrl.text = "https://custom.example/prefix/v1?key=1"
        document.providers[0].normalizeConnections()
        XCTAssertEqual(document.providers[0].models[0].baseUrl.text, "https://custom.example/prefix?key=1")
        baseline = try store.save(document, baseline: baseline)
        document.providers[0].models[0].baseUrl.text = "not a url"
        XCTAssertThrowsError(try store.save(document, baseline: baseline))
        XCTAssertEqual(try Data(contentsOf: file), baseline)
    }

    func testModelUserAgentLifecycle() throws {
        try write(#"{"providers":{"proxy":{"headers":{"User-Agent":"Provider/1.0","X-Provider":"keep"},"models":[{"id":"m","headers":{"X-Model":"keep"},"future":{"keep":true}},{"id":"other","headers":{"User-Agent":"Other/1.0"}}]}}}"#)
        let loaded = try store.load()
        var document = loaded.document
        let providerHeaders = document.providers[0].raw["headers"]
        let otherModel = document.providers[0].models[1].raw
        XCTAssertFalse(document.providers[0].models[0].userAgentEnabled)
        XCTAssertEqual(document.providers[0].models[0].userAgent.text, "")
        XCTAssertEqual(try JSONValue.decode(document.encoded()), try readJSON())

        document.providers[0].models[0].setUserAgentEnabled(true)
        XCTAssertEqual(document.providers[0].models[0].userAgent.text, "claude-cli/2.1.295 (external, cli)")
        try store.save(document, baseline: loaded.baseline)
        let enabled = try store.load()
        document = enabled.document
        XCTAssertTrue(document.providers[0].models[0].userAgentEnabled)
        XCTAssertEqual(document.providers[0].models[0].userAgent.text, ModelDraft.defaultUserAgent)
        var saved = try readJSON()["providers"]?["proxy"]
        XCTAssertEqual(saved?["models"]?.arrayValue?.first?["headers"],
                       .object(["User-Agent": .string(ModelDraft.defaultUserAgent), "X-Model": .string("keep")]))
        XCTAssertEqual(saved?["headers"], providerHeaders)
        XCTAssertEqual(saved?["models"]?.arrayValue?[1], .object(otherModel))

        document.providers[0].models[0].userAgent.text = " Custom/2.0 "
        document.providers[0].models[0].setUserAgentEnabled(false)
        document.providers[0].models[0].setUserAgentEnabled(true)
        XCTAssertEqual(document.providers[0].models[0].userAgent.text, " Custom/2.0 ")
        let entry = try XCTUnwrap(CatalogEntry(provider: "catalog", json: .object([
            "id": .string("m"), "name": .string("Catalog model"),
            "contextWindow": .int(128000), "maxTokens": .int(8192),
            "reasoning": .bool(false), "input": .array([.string("text")]),
            "cost": .object(["input": .int(0), "output": .int(0), "cacheRead": .int(0), "cacheWrite": .int(0)]),
            "headers": .object(["User-Agent": .string("Catalog/1.0")]),
        ])))
        document.providers[0].models = ModelMerge.merge(document.providers[0].models, importing: [
            ImportChoice(modelID: "m", entry: entry),
            ImportChoice(modelID: "new", entry: entry),
        ])
        XCTAssertFalse(document.providers[0].models[2].userAgentEnabled)
        try store.save(document, baseline: enabled.baseline)
        let edited = try store.load()
        document = edited.document
        XCTAssertEqual(document.providers[0].models[0].userAgent.text, "Custom/2.0")
        document.providers[0].models[0].setUserAgentEnabled(false)
        try store.save(document, baseline: edited.baseline)
        saved = try readJSON()["providers"]?["proxy"]
        XCTAssertEqual(saved?["models"]?.arrayValue?.first?["headers"], .object(["X-Model": .string("keep")]))
        XCTAssertEqual(saved?["models"]?.arrayValue?.first?["future"], .object(["keep": .bool(true)]))
        XCTAssertEqual(saved?["headers"], providerHeaders)
        XCTAssertEqual(saved?["models"]?.arrayValue?[1], .object(otherModel))

        let disabled = try store.load()
        document = disabled.document
        XCTAssertFalse(document.providers[0].models[0].userAgentEnabled)
        XCTAssertEqual(document.providers[0].models[0].userAgent.text, "")
        document.providers[0].models[0].setUserAgentEnabled(true)
        XCTAssertEqual(document.providers[0].models[0].userAgent.text, ModelDraft.defaultUserAgent)
        XCTAssertFalse(document.providers[0].models[2].userAgentEnabled)
    }

    func testModelUserAgentHeaderCaseAndRemoval() throws {
        for key in ["User-Agent", "user-agent", "USER-AGENT"] {
            var model = ModelDraft(json: [
                "id": .string("m"),
                "headers": .object([key: .string("Existing/1.0"), "X-Keep": .string("keep")]),
            ])
            XCTAssertTrue(model.userAgentEnabled)
            XCTAssertEqual(model.userAgent.text, "Existing/1.0")
            XCTAssertEqual(try model.build(providerName: "proxy", index: 0), .object(model.raw))
            model.userAgent.text = "Edited/2.0"
            XCTAssertEqual(try model.build(providerName: "proxy", index: 0)["headers"],
                           .object(["User-Agent": .string("Edited/2.0"), "X-Keep": .string("keep")]))
            model.setUserAgentEnabled(false)
            XCTAssertEqual(try model.build(providerName: "proxy", index: 0)["headers"],
                           .object(["X-Keep": .string("keep")]))
        }
        var model = ModelDraft(json: [
            "id": .string("m"),
            "headers": .object(["User-Agent": .string("A"), "user-agent": .string("B")]),
        ])
        model.setUserAgentEnabled(false)
        XCTAssertNil(try model.build(providerName: "proxy", index: 0)["headers"])
        model.setUserAgentEnabled(true)
        model.userAgent.text = "Edited/3.0"
        XCTAssertEqual(try model.build(providerName: "proxy", index: 0)["headers"],
                       .object(["User-Agent": .string("Edited/3.0")]))
    }

    func testModelUserAgentValidationPreservesFile() throws {
        try write(sample)
        let loaded = try store.load()
        for invalid in ["", "   ", "A\r\nX-Injected: yes", "A\n", "\tA", "A\u{0}", "A\u{7F}"] {
            var document = loaded.document
            document.providers[0].models[0].setUserAgentEnabled(true)
            document.providers[0].models[0].userAgent.text = invalid
            XCTAssertThrowsError(try store.save(document, baseline: loaded.baseline), invalid)
            XCTAssertEqual(try Data(contentsOf: file), loaded.baseline)
        }
        for headers in [JSONValue.string("legacy"), .array([]), .null] {
            var document = loaded.document
            document.providers[0].models[0] = ModelDraft(json: ["id": .string("m"), "headers": headers])
            XCTAssertNoThrow(try document.encoded())
            document.providers[0].models[0].setUserAgentEnabled(true)
            XCTAssertThrowsError(try store.save(document, baseline: loaded.baseline))
            XCTAssertEqual(try Data(contentsOf: file), loaded.baseline)
        }
    }

    func testModelJSONFields() throws {
        try write(#"{"providers":{"proxy":{"models":[{"id":"m","thinkingLevelMap":{"high":"high","max":null},"compat":{"supportsStore":false,"extra":{"keep":true}}}]}}}"#)
        let loaded = try store.load()
        var document = loaded.document
        let original = try document.encoded()
        XCTAssertEqual(try JSONValue.decode(Data(document.providers[0].models[0].thinkingLevelMap.text.utf8)),
                       .object(["high": .string("high"), "max": .null]))
        let untouched = try JSONValue.decode(original)["providers"]?["proxy"]?["models"]?.arrayValue?.first
        XCTAssertEqual(untouched?["thinkingLevelMap"], .object(["high": .string("high"), "max": .null]))
        XCTAssertEqual(untouched?["compat"], .object(["supportsStore": .bool(false), "extra": .object(["keep": .bool(true)])]))

        document.providers[0].models[0].thinkingLevelMap.text = #"{"off":null,"high":"medium","max":"max"}"#
        document.providers[0].models[0].compat.text = #"{"supportsStore":true,"extra":{"keep":true},"tiers":[1,2]}"#
        let baseline = try store.save(document, baseline: loaded.baseline)
        let model = try XCTUnwrap(readJSON()["providers"]?["proxy"]?["models"]?.arrayValue?.first)
        XCTAssertEqual(model["thinkingLevelMap"], .object(["off": .null, "high": .string("medium"), "max": .string("max")]))
        XCTAssertEqual(model["compat"]?["supportsStore"], .bool(true))
        XCTAssertEqual(model["compat"]?["extra"], .object(["keep": .bool(true)]))
        XCTAssertEqual(model["compat"]?["tiers"], .array([.int(1), .int(2)]))

        for invalid in ["{", "[]", "null", #"{"high":true}"#, #"{"unknown":"high"}"#] {
            var bad = document
            bad.providers[0].models[0].thinkingLevelMap.text = invalid
            XCTAssertThrowsError(try store.save(bad, baseline: baseline), invalid)
            XCTAssertEqual(try Data(contentsOf: store.resolvedPath), baseline)
        }
        for invalid in ["{", "[]", "null", "42"] {
            var bad = document
            bad.providers[0].models[0].compat.text = invalid
            XCTAssertThrowsError(try store.save(bad, baseline: baseline), invalid)
        }

        document.providers[0].models[0].thinkingLevelMap.text = "  "
        document.providers[0].models[0].compat.text = ""
        try store.save(document, baseline: baseline)
        let cleared = try readJSON()["providers"]?["proxy"]?["models"]?.arrayValue?.first
        XCTAssertNil(cleared?["thinkingLevelMap"])
        XCTAssertNil(cleared?["compat"])
    }

    // 2. Clearing an optional field removes the key.
    func testClearingRemovesKey() throws {
        try write(sample)
        let loaded = try store.load()
        var document = loaded.document
        document.providers[0].apiKey.text = ""
        document.providers[0].models[0].name.text = "  "
        document.providers[0].models[0].maxTokens.text = ""
        try store.save(document, baseline: loaded.baseline)

        let provider = try readJSON()["providers"]?["proxy"]
        XCTAssertNil(provider?["apiKey"])
        let model = provider?["models"]?.arrayValue?.first
        XCTAssertNil(model?["name"])
        XCTAssertNil(model?["maxTokens"])
        XCTAssertEqual(model?["contextWindow"], .int(128000))
    }

    // 3. Invalid input is rejected.
    func testValidationRejectsBadInput() throws {
        try write(sample)
        let base = try store.load().document

        func assertRejected(_ mutate: (inout ConfigDocument) -> Void, file: StaticString = #filePath, line: UInt = #line) {
            var document = base
            mutate(&document)
            XCTAssertThrowsError(try document.encoded(), file: file, line: line)
        }

        assertRejected { $0.providers[0].name = "" }
        assertRejected { $0.providers[0].name = " proxy" }
        assertRejected { $0.providers.append(.new(named: "proxy")) }
        assertRejected { $0.providers[0].baseUrl.text = "ftp://example.com" }
        assertRejected { $0.providers[0].baseUrl.text = "not a url" }
        assertRejected { $0.providers[0].models[0].modelID.text = "   " }
        assertRejected { $0.providers[0].models.append(ModelDraft(json: ["id": .string("m1")])) }
        assertRejected { $0.providers[0].models[0].contextWindow.text = "0" }
        assertRejected { $0.providers[0].models[0].maxTokens.text = "1.5" }

        var ok = base
        ok.providers[0].baseUrl.text = ""
        XCTAssertNoThrow(try ok.encoded())
    }

    // 4. First save creates 0600 file without backup; later saves keep exactly one backup.
    func testCreateAndBackup() throws {
        let loaded = try store.load()
        XCTAssertNil(loaded.baseline)
        var document = loaded.document
        document.providers.append(.new(named: "p"))
        let first = try store.save(document, baseline: nil)

        XCTAssertEqual(try permissions(file), 0o600)
        XCTAssertEqual(try permissions(file.deletingLastPathComponent()), 0o700)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupPath.path))

        document.providers[0].baseUrl.text = "https://a.example.com"
        let second = try store.save(document, baseline: first)
        XCTAssertEqual(try Data(contentsOf: store.backupPath), first)
        XCTAssertEqual(try permissions(store.backupPath), 0o600)

        document.providers[0].api.text = "openai-completions"
        try store.save(document, baseline: second)
        XCTAssertEqual(try Data(contentsOf: store.backupPath), second)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual(Set(leftovers), ["models.json", "models.json.bak"])
    }

    // 5. External modification, deletion, or creation blocks saving.
    func testConflictDetection() throws {
        try write(sample)
        let loaded = try store.load()

        try write(sample + " ")
        XCTAssertThrowsError(try store.save(loaded.document, baseline: loaded.baseline)) {
            XCTAssertEqual($0 as? StoreError, .conflict)
        }

        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try store.save(loaded.document, baseline: loaded.baseline)) {
            XCTAssertEqual($0 as? StoreError, .conflict)
        }

        try write(sample)
        XCTAssertThrowsError(try store.save(loaded.document, baseline: nil)) {
            XCTAssertEqual($0 as? StoreError, .conflict)
        }
    }

    // 6. Corrupt files fail to load and are never touched.
    func testCorruptFileRejected() throws {
        for text in ["{not json", "[]", #"{"providers": []}"#,
                     #"{"providers": {"p": {"models": [{"name": "x"}]}}}"#,
                     #"{"providers": {"p": {"models": [{"id": "a", "contextWindow": 1.5}]}}}"#] {
            try write(text)
            XCTAssertThrowsError(try store.load(), text)
            XCTAssertEqual(try Data(contentsOf: file), Data(text.utf8))
        }

        try write("{}")
        XCTAssertEqual(try store.load().document.providers.count, 0)
    }

    // 7. Symlinked config: the real file is updated and the link survives.
    func testSymlinkWritesRealFile() throws {
        let real = directory.appendingPathComponent("dotfiles/models.json")
        try write(sample, to: real)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: real)

        let loaded = try store.load()
        var document = loaded.document
        document.providers[0].models[0].name.text = "Linked"
        try store.save(document, baseline: loaded.baseline)

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: file.path)
        XCTAssertEqual(URL(fileURLWithPath: destination).standardizedFileURL, real.standardizedFileURL)
        XCTAssertEqual(try readJSON(real)["providers"]?["proxy"]?["models"]?.arrayValue?.first?["name"], .string("Linked"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.appendingPathExtension("bak").path))
    }
}
