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

    private var allIDs: Set<String> { Set(model.library.skills.map(\.id)) }
    private var selectedIDs: Set<String> { selection.intersection(allIDs) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("启用范围", selection: $scope) {
                    Text("技能库").tag("library")
                    Text("全局").tag("global")
                    Text("项目").tag("project")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 340)
                Spacer()
                Button { model.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(model.isBusy).accessibilityLabel("刷新")
                Button { model.resetCandidates(); showsAdd = true } label: { Label("添加 Skills", systemImage: "plus") }
                    .disabled(model.isBusy || model.loadError != nil)
                    .accessibilityLabel("添加 Skills").accessibilityIdentifier("skills-add")
            }
            if scope == "project" {
                HStack {
                    Picker("项目目录", selection: $project) {
                        Text("请选择项目").tag(Optional<String>.none)
                        ForEach(model.library.projects, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    Button("添加项目…") { model.chooseProject() }.disabled(model.isBusy || model.loadError != nil)
                }
            }
            Text(scope == "library" ? "统一保存；添加后默认未启用。选择全局或项目视图调整启用范围。" : scope == "global" ? "全局启用对所有项目生效。" : "全局 skill 不需要重复勾选；关闭全局后可单独分配项目。")
                .font(.callout).foregroundStyle(.secondary)
            if let error = model.loadError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if !model.warnings.isEmpty {
                DisclosureGroup("存储提示（\(model.warnings.count)）") {
                    ForEach(model.warnings, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                }
            }
            HStack {
                Button(selection == allIDs ? "取消全选" : "全选") { selection = selection == allIDs ? [] : allIDs }
                Button("检查所选（\(selectedIDs.count)）") { model.check(selectedIDs) }.disabled(selectedIDs.isEmpty)
                Button("检查全部") { model.check(allIDs) }.disabled(allIDs.isEmpty)
                Button("更新所选") { confirmUpdate(selectedIDs) }.disabled(selectedIDs.isEmpty)
                Button("更新全部可更新项（\(model.updateAvailable.count)）") { confirmUpdate(model.updateAvailable) }
                    .disabled(model.updateAvailable.isEmpty)
            }
            .disabled(model.isBusy || model.loadError != nil)
            if model.library.skills.isEmpty {
                ContentUnavailableView("技能库为空", systemImage: "books.vertical", description: Text("粘贴 GitHub 仓库地址，确认所需 skills 后添加。"))
            } else {
                List {
                    ForEach(model.library.skills) { skill in
                        let scopeIsBroken = !(model.scopeProblems[skill.id] ?? [:]).isEmpty
                        HStack(alignment: .top, spacing: 12) {
                            Toggle("选择 \(skill.name)", isOn: Binding(get: { selection.contains(skill.id) }, set: { if $0 { selection.insert(skill.id) } else { selection.remove(skill.id) } }))
                                .labelsHidden().toggleStyle(.checkbox).accessibilityLabel("选择 \(skill.name)").disabled(model.isBusy)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(skill.name).font(.headline)
                                Text(skill.description).font(.callout).foregroundStyle(.secondary)
                                Text("\(skill.repository.url) · \(skill.sourcePath.isEmpty ? "." : skill.sourcePath)")
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                Text("安装提交 \(skill.commit.prefix(8)) · \(scopeIsBroken ? "启用入口异常" : skill.scopes.isEmpty ? "未启用" : skill.scopes.contains(SkillStore.globalScope) ? "全局生效" : "\(skill.scopes.count) 个项目")")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let message = model.checkMessages[skill.id] { Text(message).font(.caption).textSelection(.enabled) }
                                if let changes = model.localChanges[skill.id], !changes.isEmpty {
                                    DisclosureGroup("本地修改：更新会跳过（\(changes.count) 项）") {
                                        ForEach(changes, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                                    }
                                }
                                if let problems = model.scopeProblems[skill.id], !problems.isEmpty {
                                    ForEach(problems.keys.sorted(), id: \.self) { key in
                                        Text(problems[key] ?? "").font(.caption).foregroundStyle(.red).textSelection(.enabled)
                                    }
                                }
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 8) {
                                scopeControl(skill)
                                HStack {
                                    Button("检查") { model.check([skill.id]) }
                                    Button("更新") { confirmUpdate([skill.id]) }
                                }
                            }
                            .disabled(model.isBusy || model.loadError != nil)
                        }
                        .padding(.vertical, 5)
                    }
                }
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
                    }.frame(maxHeight: 150)
                }
            }
            Text("文件库：~/PiSwitch/skills/ · 更改启用或更新后，在 Pi 中执行 /reload。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .sheet(isPresented: $showsAdd) { AddSkillsSheet(model: model) }
    }

    @ViewBuilder
    private func scopeControl(_ skill: InstalledSkill) -> some View {
        if scope == "global" {
            Toggle("全局启用", isOn: Binding(get: { skill.scopes.contains(SkillStore.globalScope) }, set: { model.toggle(skill, scope: SkillStore.globalScope, enabled: $0) }))
                .labelsHidden().toggleStyle(.switch).accessibilityLabel("\(skill.name) 全局启用")
        } else if scope == "project", let project {
            if skill.scopes.contains(SkillStore.globalScope) {
                Text(model.scopeProblems[skill.id]?[SkillStore.globalScope] == nil ? "全局生效" : "全局入口异常").foregroundStyle(.secondary)
            }
            else {
                Toggle("项目启用", isOn: Binding(get: { skill.scopes.contains(project) }, set: { model.toggle(skill, scope: project, enabled: $0) }))
                    .labelsHidden().toggleStyle(.switch).accessibilityLabel("\(skill.name) 项目启用")
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
#endif
