import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PiSwitchCore
import XCTest

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class DiscoveryTests: XCTestCase {
    private func makeClient() -> ModelListClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return ModelListClient(fetcher: HTTPFetcher(configuration: configuration))
    }

    override func setUp() {
        StubProtocol.handler = nil
        StubProtocol.requests = []
    }

    // 8. URL construction.
    func testModelsURL() throws {
        XCTAssertEqual(try ModelListClient.modelsURL(baseUrl: "https://x.com/proxy/v1/", kind: .openAI).absoluteString,
                       "https://x.com/proxy/v1/models")
        XCTAssertEqual(try ModelListClient.modelsURL(baseUrl: "https://x.com/v1", kind: .anthropic).absoluteString,
                       "https://x.com/v1/models")
        XCTAssertEqual(try ModelListClient.modelsURL(baseUrl: "https://x.com/anthropic//", kind: .anthropic).absoluteString,
                       "https://x.com/anthropic/v1/models")
        for kind in [DiscoveryProtocol.openAI, .anthropic] {
            XCTAssertEqual(try ModelListClient.modelsURL(baseUrl: "https://x.com/proxy%2Fprefix?key=1#fragment", kind: kind).absoluteString,
                           "https://x.com/proxy%2Fprefix/v1/models?key=1#fragment")
        }
        XCTAssertThrowsError(try ModelListClient.modelsURL(baseUrl: "", kind: .openAI))
        XCTAssertThrowsError(try ModelListClient.modelsURL(baseUrl: "file:///tmp", kind: .openAI))
        XCTAssertNil(DiscoveryProtocol(api: "google-generative-ai"))
    }

    func testOpenAIRequestHeadersAndDedup() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"data":[{"id":" a "},{"id":"b"},{"id":"a"}]}"#.utf8)) }
        let ids = try await makeClient().fetchIDs(baseUrl: "https://x.com/v1", apiKey: "sk-1", kind: .openAI)
        XCTAssertEqual(ids, ["a", "b"])
        XCTAssertEqual(StubProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-1")
    }

    func testNonLiteralKeyRefused() async {
        for key in ["!op read x", "OPENAI_API_KEY"] {
            do {
                _ = try await makeClient().fetchIDs(baseUrl: "https://x.com", apiKey: key, kind: .openAI)
                XCTFail("expected refusal for \(key)")
            } catch {
                XCTAssertEqual(error as? DiscoveryError, .nonLiteralKey)
            }
        }
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    // 9. Anthropic paging and cursor errors.
    func testAnthropicPaging() async throws {
        StubProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.contains(where: { $0.name == "after_id" && $0.value == "m2" }) {
                return (200, Data(#"{"data":[{"id":"m3"}],"has_more":false}"#.utf8))
            }
            return (200, Data(#"{"data":[{"id":"m1"},{"id":"m2"}],"has_more":true,"last_id":"m2"}"#.utf8))
        }
        let ids = try await makeClient().fetchIDs(baseUrl: "https://x.com", apiKey: "k", kind: .anthropic)
        XCTAssertEqual(ids, ["m1", "m2", "m3"])
        let first = StubProtocol.requests.first
        XCTAssertEqual(first?.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertEqual(first?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testAnthropicRepeatedCursorFails() async {
        StubProtocol.handler = { _ in (200, Data(#"{"data":[{"id":"m1"}],"has_more":true,"last_id":"m1"}"#.utf8)) }
        do {
            _ = try await makeClient().fetchIDs(baseUrl: "https://x.com", apiKey: "k", kind: .anthropic)
            XCTFail("expected pagination error")
        } catch {
            guard case .pagination = error as? DiscoveryError else { return XCTFail("\(error)") }
        }
    }

    func testHTTPErrorAndBadFormat() async {
        StubProtocol.handler = { _ in (401, Data("secret body".utf8)) }
        do {
            _ = try await makeClient().fetchIDs(baseUrl: "https://x.com", apiKey: "k", kind: .openAI)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? DiscoveryError, .http(401))
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }

        StubProtocol.handler = { _ in (200, Data(#"{"models":[]}"#.utf8)) }
        do {
            _ = try await makeClient().fetchIDs(baseUrl: "https://x.com", apiKey: "k", kind: .openAI)
            XCTFail()
        } catch {
            guard case .badFormat = error as? DiscoveryError else { return XCTFail("\(error)") }
        }
    }

    // Catalog: whitelist order wins, bad entries are dropped individually.
    func testCatalogParse() throws {
        let json = """
        {
          "qwen-token-plan-individual": {
            "glm-5.2": {"id":"glm-5.2","name":"Resold","contextWindow":1,"maxTokens":1,"reasoning":true,"input":["text"],"cost":{}}
          },
          "zai": {
            "glm-5.2": {"id":"glm-5.2","name":"GLM 5.2","contextWindow":200000,"maxTokens":64000,"reasoning":true,"input":["text"],"cost":{"input":1,"output":3,"tiers":[{"x":1}]}},
            "broken": {"id":"broken","name":"Broken","contextWindow":0,"maxTokens":1,"reasoning":true,"input":["text"],"cost":{}}
          },
          "not-listed": {
            "other": {"id":"other","name":"Other","contextWindow":1,"maxTokens":1,"reasoning":false,"input":[],"cost":{}}
          }
        }
        """
        let entries = try Catalog.parse(Data(json.utf8))
        XCTAssertEqual(entries.map(\.id), ["zai/glm-5.2"])
        XCTAssertEqual(entries[0].cost["tiers"], .array([.object(["x": .int(1)])]))
    }

    // 10. Merge writes only whitelisted metadata and never removes models or unknown fields.
    func testMerge() throws {
        let existing = ModelDraft(json: [
            "id": .string("glm-5.2"),
            "api": .string("custom-extension-api"),
            "baseUrl": .string("https://custom.example/v1"),
            "compat": .object(["keep": .bool(true)]),
            "contextWindow": .int(1000),
        ])
        let other = ModelDraft(json: ["id": .string("untouched")])
        let entry = try XCTUnwrap(CatalogEntry(provider: "zai", json: .object([
            "id": .string("glm-5.2"), "name": .string("GLM 5.2"),
            "contextWindow": .int(200000), "maxTokens": .int(64000),
            "reasoning": .bool(true), "input": .array([.string("text")]),
            "cost": .object(["input": .int(1), "output": .int(3), "cacheRead": .int(0), "cacheWrite": .int(0)]),
            "baseUrl": .string("https://catalog.example/v1"), "api": .string("openai-responses"),
            "headers": .object([:]), "compat": .object(["overwrite": .bool(true)]),
            "thinkingLevelMap": .object(["high": .string("high"), "max": .null]),
        ])))

        let merged = ModelMerge.merge([existing, other], importing: [
            ImportChoice(modelID: "glm-5.2", entry: entry),
            ImportChoice(modelID: "new-id", entry: nil),
        ])
        XCTAssertEqual(merged.map(\.currentID), ["glm-5.2", "untouched", "new-id"])

        let built = try merged[0].build(providerName: "p", index: 0)
        XCTAssertEqual(built["compat"], .object(["overwrite": .bool(true)]))
        XCTAssertEqual(built["thinkingLevelMap"], .object(["high": .string("high"), "max": .null]))
        XCTAssertEqual(built["contextWindow"], .int(200000))
        XCTAssertEqual(built["maxTokens"], .int(64000))
        XCTAssertEqual(built["name"], .string("GLM 5.2"))
        XCTAssertEqual(built["baseUrl"], .string("https://custom.example/v1"))
        XCTAssertEqual(built["api"], .string("custom-extension-api"))
        XCTAssertNil(built["headers"])

        let fresh = ModelMerge.merge([], importing: [ImportChoice(modelID: "alias", entry: entry)])
        let newModel = try fresh[0].build(providerName: "p", index: 0)
        XCTAssertEqual(newModel["id"], .string("alias"))
        XCTAssertEqual(newModel["thinkingLevelMap"], built["thinkingLevelMap"])
        XCTAssertEqual(newModel["compat"], built["compat"])
        XCTAssertNil(newModel["api"])
        XCTAssertNil(newModel["baseUrl"])
        XCTAssertEqual(fresh[0].api.text, "")
        XCTAssertEqual(fresh[0].baseUrl.text, "")

        var metadata = entry.fields
        metadata["id"] = .string(entry.modelID)
        metadata.removeValue(forKey: "thinkingLevelMap")
        metadata.removeValue(forKey: "compat")
        metadata.removeValue(forKey: "api")
        metadata.removeValue(forKey: "baseUrl")
        let withoutOptions = try XCTUnwrap(CatalogEntry(provider: "zai", json: .object(metadata)))
        var retained = ModelMerge.merge(merged, importing: [ImportChoice(modelID: entry.modelID, entry: withoutOptions)])
        retained = ModelMerge.merge(retained, importing: [ImportChoice(modelID: entry.modelID, entry: nil)])
        let retainedModel = try retained[0].build(providerName: "p", index: 0)
        XCTAssertEqual(retainedModel["thinkingLevelMap"], built["thinkingLevelMap"])
        XCTAssertEqual(retainedModel["compat"], built["compat"])
        XCTAssertEqual(retainedModel["api"], built["api"])
        XCTAssertEqual(retainedModel["baseUrl"], built["baseUrl"])

        metadata["thinkingLevelMap"] = .object(["high": .bool(true)])
        XCTAssertNil(CatalogEntry(provider: "zai", json: .object(metadata)))
        metadata.removeValue(forKey: "thinkingLevelMap")
        metadata["compat"] = .array([])
        XCTAssertNil(CatalogEntry(provider: "zai", json: .object(metadata)))
        metadata.removeValue(forKey: "compat")
        for key in ["api", "baseUrl"] {
            for value in [JSONValue.null, .int(1), .string(""), .string("   ")] {
                var invalid = metadata
                invalid[key] = value
                XCTAssertNil(CatalogEntry(provider: "zai", json: .object(invalid)), "\(key): \(value)")
            }
        }
        for url in ["ftp://example.com", "not a url", "https://"] {
            var invalid = metadata
            invalid["baseUrl"] = .string(url)
            XCTAssertNil(CatalogEntry(provider: "zai", json: .object(invalid)), url)
        }

        // 11. ID-only import.
        XCTAssertEqual(try merged[2].build(providerName: "p", index: 2), .object(["id": .string("new-id")]))
    }
}
