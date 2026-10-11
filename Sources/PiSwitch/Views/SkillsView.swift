#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit
import PiSwitchCore

struct SkillsView: View {
    @Bindable var model: SkillsModel
    @State private var scope = "library"
    @State private var project: String?
    @State private var selection = Set<String>()
    @State private var showsAdd = false
    @State private var search = ""
    @State private var filter = SkillCardFilter.all

    private var allIDs: Set<String> { Set(model.library.skills.map(\.id)) }
    private var visibleSkills: [InstalledSkill] { model.library.skills.filter { filter.matches($0, query: search) } }
    private var visibleIDs: Set<String> { Set(visibleSkills.map(\.id)) }
    private var selectedIDs: Set<String> { selection.intersection(visibleIDs) }
    private var title: String { scope == "library" ? "技能库" : scope == "global" ? "全局启用" : project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "项目启用" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 196)
                VStack(alignment: .leading, spacing: 16) {
                    header
                    searchAndActions
                    filters
                    if let error = model.loadError {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if !model.warnings.isEmpty {
                        DisclosureGroup("存储提示（\(model.warnings.count)）") {
                            ForEach(model.warnings, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                        }
                    }
                    if model.library.skills.isEmpty {
                        ContentUnavailableView("技能库为空", systemImage: "books.vertical", description: Text("粘贴 GitHub 仓库地址，确认所需 skills 后添加。"))
                    } else if visibleSkills.isEmpty {
                        ContentUnavailableView("没有匹配的 Skills", systemImage: "magnifyingglass", description: Text("调整搜索内容或选择「全部」。"))
                    } else {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                                ForEach(visibleSkills) { skill in skillCard(skill) }
                            }
                            .padding(1)
                        }
                        .accessibilityIdentifier("skills-grid")
                    }
                    if model.isBusy {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(model.progress).font(.callout)
                            Spacer()
                            Button("安全停止") { model.requestStop() }
                        }
                    }
                    if !model.results.isEmpty {
                        DisclosureGroup("操作结果（\(model.results.count)）") {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(model.results) { result in
                                        Text("\(result.name)：\(result.message)")
                                            .foregroundStyle(result.isError ? Color.red : Color.primary)
                                            .font(.callout).textSelection(.enabled)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 120)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            Text("文件库：~/PiSwitch/skills/ · 更改启用或更新后，在 Pi 中执行 /reload。")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(ManagementStyle.surface)
        }
        .background(ManagementStyle.background)
        .tint(ManagementStyle.tint)
        .sheet(isPresented: $showsAdd) { AddSkillsSheet(model: model) }
        .onChange(of: search) { selection.removeAll() }
        .onChange(of: filter) { selection.removeAll() }
        .onChange(of: scope) { selection.removeAll() }
        .onChange(of: project) { selection.removeAll() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SKILLS 管理").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ManagementNavigationButton(title: "技能库", symbol: "books.vertical", selected: scope == "library") { scope = "library" }
                .accessibilityIdentifier("skills-scope-library")
            ManagementNavigationButton(title: "全局启用", symbol: "globe", selected: scope == "global") { scope = "global" }
                .accessibilityIdentifier("skills-scope-global")
            ManagementNavigationButton(title: "项目", symbol: "folder", selected: scope == "project" && project == nil) { scope = "project"; project = nil }
                .accessibilityIdentifier("skills-scope-project")
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.library.projects, id: \.self) { path in
                        ManagementNavigationButton(title: URL(fileURLWithPath: path).lastPathComponent, symbol: "folder", selected: scope == "project" && project == path) {
                            scope = "project"; project = path
                        }.help(path)
                    }
                }
            }
            Button("添加项目…") { model.chooseProject() }
                .disabled(model.isBusy || model.loadError != nil)
            VStack(alignment: .leading, spacing: 6) {
                Text("安装与启用分开").font(.callout.weight(.medium))
                Text("新添加的 Skills 默认不启用。全局启用后所有项目生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16).frame(maxHeight: .infinity, alignment: .topLeading)
        .background(ManagementStyle.sidebar)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title2.weight(.semibold))
                Text("\(model.library.skills.count) 个 Skills · \(model.updateAvailable.count) 项可更新")
                    .font(.caption).foregroundStyle(.secondary)
                if scope == "project" {
                    Text(project ?? "在左侧选择项目，或添加项目目录。")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .disabled(model.isBusy).accessibilityLabel("刷新").help("重新读取本地技能库，不检查更新")
            Button { model.resetCandidates(); showsAdd = true } label: { Label("添加 Skills", systemImage: "plus") }
                .buttonStyle(.borderedProminent).tint(ManagementStyle.actionTint)
                .disabled(model.isBusy || model.loadError != nil)
                .accessibilityLabel("添加 Skills").accessibilityIdentifier("skills-add")
        }
    }

    private var searchAndActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ManagementSearchField(prompt: "搜索名称或说明", text: $search, identifier: "skills-search")
                    .frame(maxWidth: 350)
                Spacer(minLength: 8)
                Menu("批量操作") {
                    Button("检查全部（\(allIDs.count)）") { model.check(allIDs) }.disabled(allIDs.isEmpty)
                    Button("更新全部可更新项（\(model.updateAvailable.count)）") { confirmUpdate(model.updateAvailable) }
                        .disabled(model.updateAvailable.isEmpty)
                }
                .help("检查和更新整个技能库，包括筛选隐藏的条目")
                .disabled(model.isBusy || model.loadError != nil)
            }
            HStack {
                Button(selectedIDs == visibleIDs && !visibleIDs.isEmpty ? "取消全选" : "全选可见项") {
                    selection = selectedIDs == visibleIDs ? [] : visibleIDs
                }
                .accessibilityLabel(selectedIDs == visibleIDs && !visibleIDs.isEmpty ? "取消全选" : "全选可见项")
                .accessibilityIdentifier("skills-select-all")
                .disabled(visibleIDs.isEmpty)
                if !selectedIDs.isEmpty {
                    Text("已选 \(selectedIDs.count) 项").font(.caption).foregroundStyle(.secondary)
                    Button("检查所选") { model.check(selectedIDs) }
                    Button("更新所选") { confirmUpdate(selectedIDs) }
                }
            }
            .disabled(model.isBusy || model.loadError != nil)
        }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SkillCardFilter.allCases) { item in
                    Button {
                        filter = item
                    } label: {
                        Text("\(item.rawValue) · \(model.library.skills.filter { item.matches($0, query: "") }.count)")
                            .font(.caption.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(filter == item ? ManagementStyle.accentText : Color.primary)
                            .managementCard(selected: filter == item)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.rawValue) · \(model.library.skills.filter { item.matches($0, query: "") }.count)")
                    .accessibilityIdentifier("skills-filter-\(item.id)")
                    .accessibilityAddTraits(filter == item ? .isSelected : [])
                }
            }.padding(1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func skillCard(_ skill: InstalledSkill) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Toggle("选择 \(skill.name)", isOn: Binding(get: { selectedIDs.contains(skill.id) }, set: {
                    if $0 { selection.insert(skill.id) } else { selection.remove(skill.id) }
                }))
                .labelsHidden().toggleStyle(.checkbox).tint(ManagementStyle.actionTint).accessibilityLabel("选择 \(skill.name)").disabled(model.isBusy)
                Text(skill.name).font(.headline).textSelection(.enabled)
                Spacer(minLength: 0)
            }
            Text(skill.description).font(.callout).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .top) {
                Text(scopeLabel(skill)).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                updateBadge(skill)
            }
            if let problems = model.scopeProblems[skill.id], !problems.isEmpty {
                ForEach(problems.keys.sorted(), id: \.self) { key in
                    Text(problems[key] ?? "").font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            if let changes = model.localChanges[skill.id], !changes.isEmpty {
                DisclosureGroup("本地修改：更新会跳过（\(changes.count) 项）") {
                    ForEach(changes, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                }.font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup("查看详情") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.description).font(.callout)
                    Text("\(skill.repository.url) · \(skill.sourcePath.isEmpty ? "." : skill.sourcePath)")
                    Text("安装提交 \(skill.commit.prefix(8))")
                    if let message = model.checkMessages[skill.id] { Text(message) }
                }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }.font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("skill-details-\(skill.id)")
            Divider()
            HStack {
                scopeControl(skill)
                Spacer(minLength: 4)
                Button("检查") { model.check([skill.id]) }.accessibilityLabel("检查 \(skill.name)")
                Button("更新") { confirmUpdate([skill.id]) }.accessibilityLabel("更新 \(skill.name)")
            }
            .disabled(model.isBusy || model.loadError != nil)
        }
        .padding(16)
        .managementCard(selected: selectedIDs.contains(skill.id))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skill-card-\(skill.id)")
    }

    private func scopeLabel(_ skill: InstalledSkill) -> String {
        if !(model.scopeProblems[skill.id] ?? [:]).isEmpty { return "启用入口异常" }
        if skill.scopes.contains(SkillStore.globalScope) { return "全局生效" }
        return skill.scopes.isEmpty ? "未启用" : "\(skill.scopes.count) 个项目"
    }

    @ViewBuilder
    private func updateBadge(_ skill: InstalledSkill) -> some View {
        if !(model.localChanges[skill.id] ?? []).isEmpty {
            Text("本地已修改").foregroundStyle(.orange)
        } else if model.updateAvailable.contains(skill.id) {
            Text("可更新").foregroundStyle(.orange)
        } else if let message = model.checkMessages[skill.id] {
            if message.hasPrefix("检查或更新失败") { Text("检查失败").foregroundStyle(.red) }
            else if message == "已是最新" { Text("已是最新").foregroundStyle(.green) }
            else { Text("已检查").foregroundStyle(.secondary) }
        } else {
            Text("未检查").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func scopeControl(_ skill: InstalledSkill) -> some View {
        if scope == "global" {
            Toggle("全局启用", isOn: Binding(get: { skill.scopes.contains(SkillStore.globalScope) }, set: { model.toggle(skill, scope: SkillStore.globalScope, enabled: $0) }))
                .toggleStyle(.switch).tint(ManagementStyle.actionTint).controlSize(.small).accessibilityLabel("\(skill.name) 全局启用")
        } else if scope == "project", let project {
            if skill.scopes.contains(SkillStore.globalScope) {
                Text(model.scopeProblems[skill.id]?[SkillStore.globalScope] == nil ? "全局生效" : "全局入口异常").font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("项目启用", isOn: Binding(get: { skill.scopes.contains(project) }, set: { model.toggle(skill, scope: project, enabled: $0) }))
                    .toggleStyle(.switch).tint(ManagementStyle.actionTint).controlSize(.small).accessibilityLabel("\(skill.name) 项目启用")
            }
        }
    }

    private func confirmUpdate(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "更新 \(ids.count) 个 skills？"
        alert.informativeText = "更新共享技能库会影响所有已启用的项目。本地修改默认跳过；成功后只保留一份旧版备份，更旧备份自动删除。"
        alert.addButton(withTitle: "更新"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { model.update(ids) }
    }
}

enum SkillCardFilter: String, CaseIterable, Identifiable {
    case all = "全部", global = "全局启用", projects = "项目启用", disabled = "未启用"
    var id: Self { self }

    func matches(_ skill: InstalledSkill, query: String) -> Bool {
        let scopeMatches: Bool
        switch self {
        case .all: scopeMatches = true
        case .global: scopeMatches = skill.scopes.contains(SkillStore.globalScope)
        case .projects: scopeMatches = !skill.scopes.isEmpty && !skill.scopes.contains(SkillStore.globalScope)
        case .disabled: scopeMatches = skill.scopes.isEmpty
        }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return scopeMatches && (query.isEmpty || [skill.name, skill.description, skill.repository.url, skill.sourcePath].contains { $0.localizedStandardContains(query) })
    }
}
#endif
