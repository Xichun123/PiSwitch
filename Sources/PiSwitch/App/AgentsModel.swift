#if canImport(SwiftUI) && canImport(AppKit)
import Foundation
import Observation
import AppKit
import PiSwitchCore

enum AppPage: Hashable { case models, skills, agents }

@Observable
@MainActor
final class AppNavigation {
    var page: AppPage = .models

    func canSave(app: AppModel, agents: AgentsModel) -> Bool {
        switch page {
        case .models: return app.canSave
        case .agents: return agents.canSave
        case .skills: return false
        }
    }

    func save(app: AppModel, agents: AgentsModel) {
        switch page {
        case .models: app.save()
        case .agents: agents.save()
        case .skills: break
        }
    }
}

enum AgentsSection: String, CaseIterable, Identifiable {
    case global = "全局版本", templates = "项目模板", projects = "项目文件"
    var id: String { rawValue }
    var collection: AgentsCollection { self == .global ? .global : .templates }
}

@Observable
@MainActor
final class AgentsModel {
    let store: AgentsStore
    var library = AgentsState()
    var section: AgentsSection = .global
    var selection: UUID?
    var name = ""
    var text = ""
    var filePath = ""
    var loadError: String?
    var fileError: String?
    var message = ""
    var warnings: [String] = []
    var contexts: [AgentContext] = []
    var globalStatus = "尚未检查全局文件"
    var hasBackup = false
    var isBusy = false
    var revision: AgentFileSnapshot?
    var baseline: AgentFileSnapshot?
    private var savedName = ""
    private var savedText = ""
    private var loadedSelection: AgentTarget?

    var target: AgentTarget? {
        guard let selection else { return nil }
        return section == .projects ? .project(selection) : .entry(section.collection, selection)
    }
    var isDirty: Bool { baseline != nil && (text != savedText || name != savedName) }
    var canSave: Bool { !isBusy && loadError == nil && fileError == nil && isDirty }
    var canWrite: Bool { !isBusy && loadError == nil && revision != nil }
    var entries: [AgentEntry] { library.entries(section.collection) }
    var project: AgentProject? { library.projects.first { $0.id == selection } }

    init(store: AgentsStore = AgentsStore()) {
        self.store = store
        refresh()
    }

    func refresh() {
        guard !isBusy else { return }
        leave { self.message = ""; self.run { } }
    }

    func selectSection(_ value: AgentsSection) {
        guard value != section else { return }
        leave { self.section = value; self.selection = nil; self.run { } }
    }

    func select(_ id: UUID?) {
        guard selection != id else { return }
        leave { self.selection = id; self.run { } }
    }

    func save(then continuation: (() -> Void)? = nil) {
        guard canSave, let target = loadedSelection, let baseline, let revision else { return }
        let data = text == savedText ? baseline.data ?? Data() : Data(text.utf8)
        let name = self.name
        run(then: continuation) {
            if case .project = target, baseline.data == nil {
                let context = self.contexts.first { $0.directory == self.project?.path }
                let notice = self.candidateNotice(context: context, current: baseline)
                guard self.confirm("创建项目 AGENTS.md？", message: "\(notice)\n写入：\(self.filePath)") else {
                    throw AgentsError("已取消创建；草稿保留。")
                }
            }
            try await self.store.save(target, data: data, name: name, baseline: baseline, expected: revision)
            self.message = self.section == .projects ? "项目文件已保存；在 Pi 中执行 /reload。" : "库内容已保存；不会自动更新已部署文件。"
        }
    }

    func create(data: Data = Data(), suggestedName: String = "新版本") {
        guard canWrite, section != .projects else { return }
        leave {
            guard let name = self.askName(suggestedName), let revision = self.revision else { return }
            let collection = self.section.collection
            self.run {
                self.selection = try await self.store.create(collection, name: name, data: data, expected: revision)
                self.message = "已保存到本地库，尚未应用。"
            }
        }
    }

    func duplicate() {
        guard canWrite, baseline != nil, section != .projects else { return }
        leave {
            guard let baseline = self.baseline, let revision = self.revision,
                  let name = self.askName(self.name + " 副本") else { return }
            let collection = self.section.collection
            self.run {
                self.selection = try await self.store.create(collection, name: name, data: baseline.data ?? Data(), expected: revision)
                self.message = "已另存；尚未部署。"
            }
        }
    }

    func importMarkdown() {
        guard canWrite, section != .projects else { return }
        leave {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            panel.message = "选择 UTF-8 Markdown 文件。只导入内容，不复制附件或改写相对路径。"
            guard panel.runModal() == .OK, let url = panel.url, let revision = self.revision,
                  let name = self.askName(url.deletingPathExtension().lastPathComponent) else { return }
            let collection = self.section.collection
            self.run {
                let imported = try await self.store.importFile(url)
                guard let data = imported.data else { throw AgentsError("导入文件已不存在。") }
                self.selection = try await self.store.create(collection, name: name, data: data, expected: revision)
                self.message = "已导入；部署后的相对路径需自行检查。"
            }
        }
    }

    func importCurrentGlobal() {
        guard canWrite else { return }
        leave {
            guard let name = self.askName("现有全局"), let revision = self.revision else { return }
            self.run {
                let current = try await self.store.read(.global)
                self.selection = try await self.store.importGlobal(name: name, baseline: current, expected: revision)
                self.section = .global
                self.message = "已导入现有全局文件；原文件未改动。"
            }
        }
    }

    func deleteSelection() {
        guard canWrite, let id = selection else { return }
        leave {
            guard let revision = self.revision else { return }
            let baseline = self.baseline
            let message = self.section == .projects ? "只移除登记，保留项目 AGENTS.md。" : "删除库中的内容；已生成的项目文件不会改变。"
            guard self.confirm("移除「\(self.name)」？", message: message) else { return }
            let section = self.section
            self.run {
                if section == .projects { try await self.store.removeProject(id, expected: revision) }
                else {
                    guard let baseline else { throw AgentsError("无法核对库文件，不能安全删除。") }
                    try await self.store.deleteEntry(section.collection, id: id, baseline: baseline, expected: revision)
                }
                self.selection = nil
                self.message = "已移除；没有删除实际全局或项目文件。"
            }
        }
    }

    func detachGlobal() {
        guard canWrite else { return }
        leave {
            guard let revision = self.revision else { return }
            guard self.confirm("解除全局版本管理？", message: "保留实际全局文件，不删除或禁用任何 Pi 指令。") else { return }
            self.run { try await self.store.detachGlobal(expected: revision) }
        }
    }

    func chooseProject(_ url: URL? = nil) {
        guard canWrite else { return }
        leave {
            let chosen: URL
            if let url { chosen = url } else {
                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                panel.allowsMultipleSelection = false; panel.message = "项目文件写入所选目录的 AGENTS.md。"
                guard panel.runModal() == .OK, let url = panel.url else { return }; chosen = url
            }
            guard let revision = self.revision else { return }
            self.run {
                self.selection = try await self.store.addProject(chosen, expected: revision)
                self.section = .projects
            }
        }
    }

    func exportDraft() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "AGENTS-draft.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard !FileManager.default.fileExists(atPath: url.path) else { throw AgentsError("请选择未被占用的导出路径。") }
            try Data(text.utf8).write(to: url, options: .withoutOverwriting)
            message = "草稿已导出：\(url.path)"
        } catch { message = error.localizedDescription }
    }

    func saveProjectAsTemplate() {
        guard canWrite, section == .projects, baseline != nil else { return }
        leave {
            guard let baseline = self.baseline, let name = self.askName("项目模板"), let revision = self.revision else { return }
            let data = baseline.data ?? Data()
            self.run {
                self.selection = try await self.store.create(.templates, name: name, data: data, expected: revision)
                self.section = .templates
                self.message = "已保存为新模板；项目文件不变。"
            }
        }
    }

    func applyGlobal() {
        guard canWrite, section == .global, let id = selection else { return }
        leave { self.prepareApplication(id) }
    }

    private func prepareApplication(_ id: UUID) {
        guard let revision, let source = baseline else { return }
        run(reloadEditor: false) {
            let current = try await self.store.read(.global)
            let external = self.library.activeGlobal.map { current.hash != $0.appliedHash } ?? false
            var allowExternal = false
            if external {
                let alert = NSAlert(); alert.messageText = "全局文件被外部修改"
                alert.informativeText = "建议先将当前内容另存为版本。不会自动回写原版本。"
                alert.addButton(withTitle: "另存当前内容为版本"); alert.addButton(withTitle: "备份后覆盖"); alert.addButton(withTitle: "取消")
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    guard current.data != nil, let name = self.askName("全局外部修改") else { return }
                    _ = try await self.store.importGlobal(name: name, baseline: current, expected: revision)
                    self.message = "当前内容已保留为新版本；请重新选择并应用目标版本。"
                    return
                case .alertSecondButtonReturn: allowExternal = true
                default: return
                }
            }
            let context = await self.store.contextChain(cwd: self.store.agentDirectory).first { $0.directory == self.store.agentDirectory.path }
            let notice = self.candidateNotice(context: context, current: current)
            guard self.confirmReplacement(title: "应用「\(self.name)」到全局？", before: current, after: source,
                                          notice: "影响使用此 agent 目录的所有项目。\n\(notice)") else { return }
            try await self.store.applyGlobal(id, source: source, baseline: current, expected: revision, allowExternal: allowExternal)
            self.message = "全局文件已更新；运行中的 Pi 需 /reload。规则差异较大时请另开会话。"
        }
    }

    func useTemplate(_ id: UUID) {
        guard canWrite, section == .projects, let projectId = selection else { return }
        leave {
            guard let revision = self.revision, let current = self.baseline else { return }
            self.run {
                let source = try await self.store.read(.entry(.templates, id))
                let title = current.data == nil ? "从模板创建项目文件？" : "用模板替换项目文件？"
                let context = self.contexts.first { $0.directory == self.project?.path }
                let notice = self.candidateNotice(context: context, current: current)
                guard self.confirmReplacement(title: title, before: current, after: source,
                                              notice: "生成普通文件，以后独立修改；不会与模板同步。\n相对路径和附件需自行检查。\n\(notice)") else { return }
                try await self.store.useTemplate(id, projectId: projectId, source: source, baseline: current, expected: revision)
                self.message = "项目文件已生成；可继续定制。在 Pi 中执行 /reload。"
            }
        }
    }

    func restoreBackup() {
        guard canWrite, let target else { return }
        leave {
            guard let baseline = self.baseline, let revision = self.revision else { return }
            self.run {
                guard let backup = try await self.store.backup(target) else { throw AgentsError("没有备份。") }
                guard self.confirmReplacement(title: "恢复最近备份？", before: baseline, after: backup,
                                              notice: "当前内容先备份；全局恢复后会解除版本关联，不会禁用文件。") else { return }
                try await self.store.restore(target, baseline: baseline, expected: revision)
                self.message = "已恢复备份；实际指令文件变化后请在 Pi 中 /reload。"
            }
        }
    }

    func restoreGlobalBackup() {
        guard canWrite else { return }
        leave {
            guard let revision = self.revision else { return }
            self.run {
                let current = try await self.store.read(.global)
                guard let backup = try await self.store.backup(.global) else { throw AgentsError("没有全局文件备份。") }
                guard self.confirmReplacement(title: "恢复实际全局文件的最近备份？", before: current, after: backup,
                                              notice: "影响此 agent 目录的所有项目。当前内容先备份；恢复后解除版本关联。") else { return }
                try await self.store.restore(.global, baseline: current, expected: revision)
                self.message = "全局文件已恢复；请在 Pi 中 /reload。实际文件保留，版本关联已解除。"
            }
        }
    }

    func confirmLeave(then continuation: @escaping () -> Void) -> Bool {
        guard !isBusy else {
            let alert = NSAlert(); alert.messageText = "AGENTS 操作尚未完成"
            alert.informativeText = "请等待文件写入或恢复完成。"; alert.addButton(withTitle: "继续等待"); alert.runModal()
            return false
        }
        guard isDirty else { return true }
        let alert = NSAlert(); alert.messageText = "有未保存的 AGENTS 修改"
        alert.addButton(withTitle: "保存并继续"); alert.addButton(withTitle: "放弃修改"); alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn: save(then: continuation); return false
        case .alertSecondButtonReturn: text = savedText; name = savedName; return true
        default: return false
        }
    }

    private func leave(_ continuation: @escaping () -> Void) {
        if confirmLeave(then: continuation) { continuation() }
    }

    private func run(reloadEditor: Bool = true, then continuation: (() -> Void)? = nil,
                     _ work: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            var succeeded = false
            do { try await work(); succeeded = true }
            catch { message = error.localizedDescription }
            do {
                let inspection = try await store.inspect()
                library = inspection.state; revision = inspection.revision; warnings = inspection.warnings; loadError = nil
                await updateGlobalStatus()
                if succeeded && reloadEditor { await loadEditor() }
                else if succeeded && !isDirty { await loadEditor() }
            } catch { loadError = error.localizedDescription }
            isBusy = false
            if succeeded && loadError == nil { continuation?() }
        }
    }

    private func loadEditor() async {
        baseline = nil; fileError = nil; hasBackup = false; loadedSelection = nil
        text = ""; name = ""; savedText = ""; savedName = ""; filePath = ""; contexts = []
        guard let target else { return }
        do {
            name = section == .projects ? project.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "" : entries.first { $0.id == selection }?.name ?? ""
            filePath = try await store.path(target).path
            let file = try await store.read(target)
            baseline = file; loadedSelection = target; text = file.text; savedText = text; savedName = name
            if section != .projects && file.data == nil { throw AgentsError("库文件缺失：\(filePath)") }
            hasBackup = try await store.backup(target) != nil
        } catch { fileError = error.localizedDescription }
        if let project { contexts = await store.contextChain(cwd: URL(fileURLWithPath: project.path)) }
        else if section == .global { contexts = await store.contextChain(cwd: store.agentDirectory).filter { $0.directory == store.agentDirectory.path } }
    }

    private func updateGlobalStatus() async {
        do {
            let current = try await store.read(.global)
            if let active = library.activeGlobal {
                let version = try await store.read(.entry(.global, active.versionId))
                let title = library.globals.first { $0.id == active.versionId }?.name ?? ""
                if current.data == nil { globalStatus = "全局文件缺失（记录：\(title)）" }
                else if current.hash != active.appliedHash { globalStatus = "全局文件被外部修改（记录：\(title)）" }
                else if version.data == nil { globalStatus = "已应用「\(title)」，磁盘一致；关联库文件缺失" }
                else if version.hash != active.appliedHash { globalStatus = "已应用「\(title)」；版本有新内容待应用" }
                else { globalStatus = "已应用「\(title)」，磁盘文件一致" }
            } else { globalStatus = current.data == nil ? "尚无全局 AGENTS.md" : "现有全局文件未关联版本，可导入" }
            let context = await store.contextChain(cwd: store.agentDirectory).first { $0.directory == store.agentDirectory.path }
            if context?.selectedPath?.hasSuffix("AGENTS.override.md") == true { globalStatus += "；被 override 遮蔽" }
        } catch { globalStatus = error.localizedDescription }
    }

    private func askName(_ initial: String) -> String? {
        let alert = NSAlert(); alert.messageText = "名称"
        let field = NSTextField(string: initial); field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func confirm(_ title: String, message: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "确认"); alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func candidateNotice(context: AgentContext?, current: AgentFileSnapshot) -> String {
        guard let path = context?.selectedPath else { return "" }
        if path.hasSuffix("AGENTS.override.md") { return "注意：AGENTS.override.md 遮蔽普通文件，应用将被拒绝。" }
        if current.data == nil, URL(fileURLWithPath: path).lastPathComponent.uppercased() == "CLAUDE.MD" {
            return "注意：创建 AGENTS.md 后，同目录 CLAUDE.md 将不再被选中。"
        }
        return ""
    }

    private func confirmReplacement(title: String, before: AgentFileSnapshot, after: AgentFileSnapshot, notice: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = notice + "\n左侧为当前内容，右侧为将写入的内容；已有文件先备份。"
        let stack = NSStackView(); stack.orientation = .horizontal; stack.spacing = 12
        for text in [before.data == nil ? "（文件不存在）" : before.text, after.text] {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 330, height: 280))
            scroll.hasVerticalScroller = true
            scroll.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([scroll.widthAnchor.constraint(equalToConstant: 330), scroll.heightAnchor.constraint(equalToConstant: 280)])
            let view = NSTextView(frame: scroll.bounds); view.string = text; view.isEditable = false
            view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            view.isVerticallyResizable = true; view.autoresizingMask = [.width]
            scroll.documentView = view; stack.addArrangedSubview(scroll)
        }
        alert.accessoryView = stack; alert.addButton(withTitle: "确认写入"); alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
#endif
