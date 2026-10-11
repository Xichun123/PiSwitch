import SwiftUI
import AppKit
@testable import PiSwitchCore

private final class SkillsUIProtocol: URLProtocol {
    static var requests = 0
    static var files: [String: Data] = [:]
    static var entries: [SkillTreeEntry] = []
    static let commit = String(repeating: "b", count: 40)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let url = request.url!
        var status = 200
        let data: Data
        if url.path.contains("blocked/repo") { status = 403; data = Data() }
        else if url.host == "raw.githubusercontent.com" { data = Self.files[String(url.path.dropFirst(("/owner/repo/" + Self.commit + "/skill/").count))]! }
        else if url.path == "/repos/owner/repo" { data = Data("{\"default_branch\":\"main\"}".utf8) }
        else if url.path.contains("/commits/") { data = Data("{\"sha\":\"\(Self.commit)\"}".utf8) }
        else { data = try! JSONSerialization.data(withJSONObject: ["truncated": false, "tree": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.entries))]) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct SkillsUICheck {
    static func download(name: String, repository: String, version: Int) throws -> SkillDownload {
        let description = name == "blocked"
            ? "version \(version) " + String(repeating: "Long fixture description for layout. ", count: 12) + "DESCRIPTION-END"
            : "version \(version)"
        let files = ["SKILL.md": Data("---\nname: \(name)\ndescription: \(description)\n---\n".utf8)]
        let entries = files.map { path, data in SkillTreeEntry(path: "skill/" + path, mode: "100644", type: "blob", sha: SkillSafety.blobSHA(data), size: data.count) }
        let snapshot = SkillRepositorySnapshot(repository: try SkillRepositoryAddress("https://github.com/" + repository), commit: version == 2 ? SkillsUIProtocol.commit : String(repeating: "a", count: 40), entries: entries)
        return SkillDownload(snapshot: snapshot, path: "skill", metadata: try SkillMetadata.parse(files["SKILL.md"]!), files: files)
    }

    @MainActor static func wait(_ model: SkillsModel) async throws {
        let deadline = Date().addingTimeInterval(10)
        while model.isBusy {
            guard Date() < deadline else { throw SkillError("Timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor static func main() async {
        do {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1])
            let store = SkillStore(root: directory.appendingPathComponent("library"), home: directory)
            _ = try await store.install(download(name: "blocked", repository: "blocked/repo", version: 1))
            _ = try await store.install(download(name: "working", repository: "owner/repo", version: 1))
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [SkillsUIProtocol.self]
            let model = SkillsModel(store: store, repository: SkillRepository(fetcher: HTTPFetcher(configuration: config)))
            try await wait(model)
            assert(SkillsUIProtocol.requests == 0, "Startup performed an update request")
            assert(model.loadError == nil)
            let next = try download(name: "working", repository: "owner/repo", version: 2)
            SkillsUIProtocol.files = next.files; SkillsUIProtocol.entries = next.snapshot.entries
            let ids = Set(model.library.skills.map(\.id))
            model.update(ids)
            assert(model.isBusy)
            model.refresh() // Must not reenter a batch.
            try await wait(model)
            assert(model.results.count == 2 && model.results.filter(\.isError).count == 1, "Partial batch did not continue")
            assert(model.library.skills.first(where: { $0.name == "working" })?.commit == next.snapshot.commit)
            assert(model.library.skills.first(where: { $0.name == "blocked" })?.commit == String(repeating: "a", count: 40))
            model.check(ids)
            model.requestStop()
            try await wait(model)
            assert(!model.isBusy, "Safe stop did not release task guard")
            model.parse("https://github.com/owner/repo")
            try await wait(model)
            assert(model.candidates.count == 1 && model.candidateProblems["skill"] != nil)
            model.resetCandidates()
            var sample = model.library.skills.first { $0.name == "working" }!
            assert(SkillCardFilter.all.matches(sample, query: " WORKING "))
            assert(SkillCardFilter.all.matches(sample, query: "VERSION 2"))
            assert(SkillCardFilter.all.matches(sample, query: "owner/repo"))
            assert(SkillCardFilter.all.matches(sample, query: "skill"))
            assert(!SkillCardFilter.all.matches(sample, query: "no such skill"))
            assert(SkillCardFilter.disabled.matches(sample, query: ""))
            sample.description = "中文搜索"
            assert(SkillCardFilter.all.matches(sample, query: "中文"))
            sample.scopes = [directory.appendingPathComponent("project").path]
            assert(SkillCardFilter.projects.matches(sample, query: ""))
            assert(!SkillCardFilter.global.matches(sample, query: ""))
            assert(!SkillCardFilter.disabled.matches(sample, query: ""))
            sample.scopes.append(SkillStore.globalScope)
            assert(SkillCardFilter.global.matches(sample, query: ""))
            assert(!SkillCardFilter.projects.matches(sample, query: ""), "Global scope must take precedence")
            assert(!SkillCardFilter.global.matches(sample, query: "absent"), "Scope filter must combine with search")
            print("PASS: no startup network, batch partial failure, write-task guard, safe stop, candidate duplicate state, search and mutually exclusive scope filters")
            fflush(stdout)
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "SkillsUICheck"
            let invalidConfig = directory.appendingPathComponent("models.json")
            try Data("invalid JSON".utf8).write(to: invalidConfig)
            let appModel = AppModel(store: ConfigStore(path: invalidConfig))
            assert(!appModel.isLoaded && !appModel.canSave)
            let agents = AgentsModel(store: AgentsStore(root: directory.appendingPathComponent("agents-library"), agentDirectory: directory.appendingPathComponent("agent")))
            window.contentView = NSHostingView(rootView: ContentView(app: appModel, skills: model, agents: agents, navigation: AppNavigation()))
            window.center(); window.makeKeyAndOrderFront(nil); app.activate()
            app.run()
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
