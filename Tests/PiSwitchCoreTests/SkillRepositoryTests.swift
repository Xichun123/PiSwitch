import XCTest
@testable import PiSwitchCore

private final class SkillHTTPStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class SkillRepositoryTests: XCTestCase {
    private func client() -> SkillRepository {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SkillHTTPStub.self]
        return SkillRepository(fetcher: HTTPFetcher(configuration: config))
    }

    override func tearDown() { SkillHTTPStub.handler = nil; super.tearDown() }

    func testMultipleCandidatesAndFixedCommitDownload() async throws {
        let commit = String(repeating: "a", count: 40)
        let good = Data("---\nname: good\ndescription: 'Quoted: value'\n---\n".utf8)
        let bad = Data("---\nname: bad\n---\n".utf8)
        let script = Data("#!/bin/sh\necho ok\n".utf8)
        let files = ["skills/good/SKILL.md": good, "skills/bad/SKILL.md": bad, "skills/good/scripts/run.sh": script]
        let entries = files.map { path, data in
            SkillTreeEntry(path: path, mode: path.hasSuffix(".sh") ? "100755" : "100644", type: "blob", sha: SkillSafety.blobSHA(data), size: data.count)
        }
        var requested: [String] = []
        SkillHTTPStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "PiSwitch")
            let url = request.url!
            requested.append(url.absoluteString)
            if url.host == "api.github.com" {
                if url.path == "/repos/owner/repo" { return (200, Data("{\"default_branch\":\"main\"}".utf8)) }
                if url.path == "/repos/owner/repo/commits/main" { return (200, Data("{\"sha\":\"\(commit)\"}".utf8)) }
                XCTAssertEqual(url.path, "/repos/owner/repo/git/trees/" + commit)
                XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "1")
                return (200, try JSONSerialization.data(withJSONObject: ["truncated": false, "tree": try JSONSerialization.jsonObject(with: JSONEncoder().encode(entries))]))
            }
            XCTAssertEqual(url.host, "raw.githubusercontent.com")
            let prefix = "/owner/repo/" + commit + "/"
            XCTAssertTrue(url.path.hasPrefix(prefix))
            return (200, files[String(url.path.dropFirst(prefix.count))]!)
        }
        let repository = client()
        let snapshot = try await repository.snapshot(SkillRepositoryAddress("https://github.com/owner/repo"))
        let candidates = try await repository.candidates(in: snapshot)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertNotNil(candidates.first(where: { $0.path == "skills/bad" })?.problem)
        XCTAssertEqual(candidates.first(where: { $0.path == "skills/good" })?.metadata?.description, "Quoted: value")
        let download = try await repository.download("skills/good", in: snapshot)
        XCTAssertEqual(download.files.count, 2)
        XCTAssertEqual(download.files["scripts/run.sh"], script)
        XCTAssertFalse(requested.contains(where: { $0.contains("raw.githubusercontent.com/owner/repo/main/") }))
    }

    func testTruncationNoSkillAndHTTPFailures() async throws {
        let commit = String(repeating: "a", count: 40)
        let repository = client()
        let address = try SkillRepositoryAddress("https://github.com/owner/repo")
        SkillHTTPStub.handler = { request in
            let path = request.url!.path
            if path == "/repos/owner/repo" { return (200, Data("{\"default_branch\":\"main\"}".utf8)) }
            if path.contains("/commits/") { return (200, Data("{\"sha\":\"\(commit)\"}".utf8)) }
            return (200, Data("{\"tree\":[],\"truncated\":true}".utf8))
        }
        do { _ = try await repository.snapshot(address); XCTFail("Accepted truncated tree") } catch { XCTAssertTrue(error.localizedDescription.contains("截断")) }
        let empty = SkillRepositorySnapshot(repository: address, commit: commit, entries: [])
        do { _ = try await repository.candidates(in: empty); XCTFail("Accepted no skills") } catch { XCTAssertTrue(error.localizedDescription.contains("没有")) }
        for status in [403, 404, 429, 500] {
            SkillHTTPStub.handler = { _ in (status, Data()) }
            do { _ = try await repository.snapshot(address); XCTFail("Accepted HTTP error") } catch { XCTAssertTrue(error.localizedDescription.contains(String(status))) }
        }
    }

    func testDownloadRejectsMissingOrTamperedContent() async throws {
        let data = Data("---\nname: good\ndescription: good\n---\n".utf8)
        let entry = SkillTreeEntry(path: "SKILL.md", mode: "100644", type: "blob", sha: SkillSafety.blobSHA(data), size: data.count)
        let snapshot = SkillRepositorySnapshot(repository: try SkillRepositoryAddress("https://github.com/owner/repo"), commit: String(repeating: "a", count: 40), entries: [entry])
        SkillHTTPStub.handler = { _ in (200, Data(repeating: 120, count: data.count)) }
        do { _ = try await client().download("", in: snapshot); XCTFail("Accepted tampered download") } catch { XCTAssertTrue(error.localizedDescription.contains("不一致")) }
        SkillHTTPStub.handler = { _ in (404, Data()) }
        do { _ = try await client().download("", in: snapshot); XCTFail("Accepted missing file") } catch {}
    }
}
