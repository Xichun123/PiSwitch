#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import Observation
import PiSwitchCore

struct SkillOperationResult: Identifiable {
    let id = UUID()
    let name: String
    let message: String
    let isError: Bool
}

@MainActor
@Observable
final class SkillsModel {
    private let store: SkillStore
    private let repository: SkillRepository
    private(set) var library = SkillLibrary()
    private(set) var localChanges: [String: [String]] = [:]
    private(set) var scopeProblems: [String: [String: String]] = [:]
    private(set) var warnings: [String] = []
    private(set) var loadError: String?
    private(set) var isBusy = false
    private(set) var progress = ""
    private(set) var results: [SkillOperationResult] = []
    private(set) var checkMessages: [String: String] = [:]
    private(set) var updateAvailable = Set<String>()
    private(set) var candidates: [SkillCandidate] = []
    private(set) var candidateProblems: [String: String] = [:]
    private(set) var parsedSnapshot: SkillRepositorySnapshot?
    private(set) var parseError: String?
    private var stopRequested = false
    @ObservationIgnored private var task: Task<Void, Never>?

    init(store: SkillStore = SkillStore(), repository: SkillRepository = SkillRepository()) {
        self.store = store
        self.repository = repository
        refresh()
    }

    func refresh() { run("读取技能库") {} }

    func resetCandidates() {
        guard !isBusy else { return }
        candidates = []; candidateProblems = [:]; parsedSnapshot = nil; parseError = nil; results = []
    }

    func parse(_ address: String) {
        run("解析 GitHub 仓库") {
            self.resetParseState()
            do {
                let snapshot = try await self.repository.snapshot(SkillRepositoryAddress(address))
                let candidates = try await self.repository.candidates(in: snapshot)
                for candidate in candidates {
                    if let metadata = candidate.metadata,
                       let problem = try await self.store.additionProblem(name: metadata.name, repository: snapshot.repository, path: candidate.path) {
                        self.candidateProblems[candidate.id] = problem
                    }
                }
                self.parsedSnapshot = snapshot
                self.candidates = candidates
            } catch is CancellationError { self.parseError = "已安全停止解析。" }
            catch { self.parseError = error.localizedDescription }
        }
    }

    func install(_ paths: Set<String>) {
        guard let snapshot = parsedSnapshot else { return }
        let selected = candidates.filter { paths.contains($0.id) && $0.metadata != nil && candidateProblems[$0.id] == nil }
        run("添加 skills") {
            for (index, candidate) in selected.enumerated() {
                if self.stopRequested { break }
                let name = candidate.metadata!.name
                self.progress = "添加 \(index + 1)/\(selected.count)：\(name)"
                do {
                    let download = try await self.repository.download(candidate.path, in: snapshot)
                    let message = try await self.store.install(download)
                    self.candidateProblems[candidate.id] = "已添加"
                    self.results.append(SkillOperationResult(name: name, message: message, isError: false))
                } catch is CancellationError {
                    self.results.append(SkillOperationResult(name: name, message: "已安全停止，未添加。", isError: false))
                    break
                } catch { self.results.append(SkillOperationResult(name: name, message: error.localizedDescription, isError: true)) }
            }
        }
    }

    func check(_ ids: Set<String>) { process(ids, updating: false) }
    func update(_ ids: Set<String>) { process(ids, updating: true) }

    private func process(_ ids: Set<String>, updating: Bool) {
        let selected = library.skills.filter { ids.contains($0.id) }
        guard !selected.isEmpty else { return }
        run(updating ? "更新 skills" : "检查更新") {
            var snapshots: [SkillRepositoryAddress: SkillRepositorySnapshot] = [:]
            var failures: [SkillRepositoryAddress: String] = [:]
            for (index, skill) in selected.enumerated() {
                if self.stopRequested { break }
                self.progress = "\(updating ? "更新" : "检查") \(index + 1)/\(selected.count)：\(skill.name)"
                do {
                    let changes = try await self.store.localChanges(skill)
                    self.localChanges[skill.id] = changes
                    if updating, !changes.isEmpty {
                        self.results.append(SkillOperationResult(name: skill.name, message: "已跳过本地修改：\n" + changes.joined(separator: "\n"), isError: false))
                        continue
                    }
                    if let failure = failures[skill.repository] { throw SkillError(failure) }
                    let snapshot: SkillRepositorySnapshot
                    if let cached = snapshots[skill.repository] { snapshot = cached }
                    else {
                        do {
                            snapshot = try await self.repository.snapshot(skill.repository)
                            snapshots[skill.repository] = snapshot
                        } catch {
                            failures[skill.repository] = error.localizedDescription
                            throw error
                        }
                    }
                    let changed = try snapshot.fingerprint(in: skill.sourcePath) != skill.sourceFingerprint
                    if changed { self.updateAvailable.insert(skill.id) } else { self.updateAvailable.remove(skill.id) }
                    var message = changed ? "有更新" : "已是最新"
                    if updating, changed {
                        let download = try await self.repository.download(skill.sourcePath, in: snapshot)
                        message = try await self.store.update(skill.id, with: download)
                        self.updateAvailable.remove(skill.id)
                    }
                    self.checkMessages[skill.id] = message
                    self.results.append(SkillOperationResult(name: skill.name, message: message, isError: false))
                } catch is CancellationError {
                    self.results.append(SkillOperationResult(name: skill.name, message: "已安全停止，未替换当前文件。", isError: false))
                    break
                } catch {
                    self.updateAvailable.remove(skill.id)
                    self.checkMessages[skill.id] = "检查或更新失败：\(error.localizedDescription)"
                    self.results.append(SkillOperationResult(name: skill.name, message: error.localizedDescription, isError: true))
                }
            }
        }
    }

    func chooseProject() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "添加项目"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run("添加项目") {
            do { try await self.store.addProject(url) }
            catch { self.results.append(SkillOperationResult(name: url.lastPathComponent, message: error.localizedDescription, isError: true)) }
        }
    }

    func toggle(_ skill: InstalledSkill, scope: String, enabled: Bool) {
        guard !isBusy else { return }
        var scopes = skill.scopes
        if enabled {
            if scope == SkillStore.globalScope {
                if !scopes.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = "切换为全局启用？"
                    alert.informativeText = "将移除该 skill 的以下项目入口，并创建全局入口，所有项目都会生效：\n" + scopes.joined(separator: "\n")
                    alert.addButton(withTitle: "切换为全局"); alert.addButton(withTitle: "取消")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
                scopes = [scope]
            } else { scopes.append(scope) }
        } else { scopes.removeAll { $0 == scope } }
        let desired = scopes
        run("调整启用范围") {
            do {
                try await self.store.setScopes(desired, for: skill.id)
                self.results.append(SkillOperationResult(name: skill.name, message: "启用范围已保存。在 Pi 中执行 /reload 生效。", isError: false))
            } catch { self.results.append(SkillOperationResult(name: skill.name, message: error.localizedDescription, isError: true)) }
        }
    }

    func requestStop() {
        stopRequested = true
        task?.cancel()
        progress += "；已请求安全停止"
    }

    func confirmIdle() -> Bool {
        guard isBusy else { return true }
        let alert = NSAlert()
        alert.messageText = "技能任务尚未完成"
        alert.informativeText = "请等待任务完成，或点击“安全停止”。为保护文件，本次不关闭窗口或退出。"
        alert.addButton(withTitle: "继续等待")
        alert.runModal()
        return false
    }

    private func resetParseState() {
        candidates = []; candidateProblems = [:]; parsedSnapshot = nil; parseError = nil
    }

    private func run(_ title: String, work: @escaping @MainActor () async -> Void) {
        guard !isBusy else { return }
        isBusy = true; stopRequested = false; progress = title; results = []
        task = Task {
            await work()
            do {
                let inspection = try await store.inspect()
                library = inspection.library; localChanges = inspection.localChanges
                scopeProblems = inspection.scopeProblems; warnings = inspection.warnings; loadError = nil
            } catch { loadError = error.localizedDescription }
            isBusy = false; progress = ""; task = nil
        }
    }
}
#endif
