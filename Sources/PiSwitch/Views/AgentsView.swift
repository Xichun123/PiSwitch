#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit
import PiSwitchCore

struct AgentsView: View {
    @Bindable var model: AgentsModel
    let knownProjects: [String]
    @State private var search = ""

    private var filteredEntries: [AgentEntry] { model.entries.filter { search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.name.localizedStandardContains(search.trimmingCharacters(in: .whitespacesAndNewlines)) } }
    private var filteredProjects: [AgentProject] { model.library.projects.filter { search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.path.localizedStandardContains(search.trimmingCharacters(in: .whitespacesAndNewlines)) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 196)
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if let error = model.loadError {
                        ContentUnavailableView("无法加载 AGENTS 记录", systemImage: "exclamationmark.octagon",
                                               description: Text(error + "\n已禁止写入，请修复记录后重新加载。"))
                    } else {
                        ManagementSearchField(prompt: model.section == .projects ? "搜索项目路径" : "搜索版本或模板", text: $search, identifier: "agents-search")
                            .frame(maxWidth: 350)
                        objectCards
                        editor
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                if model.isBusy { ProgressView("正在检查或写入文件…").controlSize(.small) }
                if !model.message.isEmpty { Text(model.message).textSelection(.enabled) }
                if !model.warnings.isEmpty {
                    DisclosureGroup("存储提示（\(model.warnings.count)）") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(model.warnings, id: \.self) { Text($0).foregroundStyle(.orange).textSelection(.enabled) }
                            }
                        }.frame(maxHeight: 100)
                    }
                }
                Text("实际指令变化后执行 /reload。").foregroundStyle(.secondary)
            }
            .font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(ManagementStyle.surface)
        }
        .background(ManagementStyle.background)
        .tint(ManagementStyle.tint)
        .disabled(model.isBusy)
        .onChange(of: model.section) { search = "" }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("AGENTS 指令").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                VStack(spacing: 4) {
                    ForEach(AgentsSection.allCases) { section in
                        ManagementNavigationButton(title: section.rawValue,
                                                   symbol: section == .global ? "globe" : section == .templates ? "doc.on.doc" : "folder",
                                                   selected: model.section == section) { model.selectSection(section) }
                            .accessibilityIdentifier("agents-section-\(section == .global ? "global" : section == .templates ? "templates" : "projects")")
                    }
                }
                Divider()
                Text("实际全局状态").font(.caption).foregroundStyle(.secondary)
                Text(model.globalStatus).font(.callout).textSelection(.enabled)
                Text(model.store.globalURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("保存版本不会自动应用到全局。项目模板复制后独立编辑。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.section == .global {
                    Button("导入现有全局", action: model.importCurrentGlobal).disabled(!model.canWrite)
                        .accessibilityIdentifier("agents-import-global")
                    Menu("全局管理") {
                        Button("恢复全局文件备份", action: model.restoreGlobalBackup).disabled(!model.canWrite)
                        Button("解除全局管理", action: model.detachGlobal)
                            .disabled(!model.canWrite || model.library.activeGlobal == nil)
                    }
                }
                Button(model.section == .projects ? "移除项目登记" : "删除所选", role: .destructive, action: model.deleteSelection)
                    .disabled(!model.canWrite || model.selection == nil)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(ManagementStyle.sidebar)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.section.rawValue).font(.title2.weight(.semibold))
                Text(model.section == .global ? "保存到版本库，再单独应用到实际 AGENTS.md" : model.section == .templates ? "模板复制到项目后独立编辑，不会自动同步" : "编辑项目文件，或从模板创建")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel("重新加载").help("重新加载").accessibilityIdentifier("agents-reload")
            if model.section == .projects {
                Button("添加项目") { model.chooseProject() }.buttonStyle(.borderedProminent).tint(ManagementStyle.actionTint)
                    .disabled(!model.canWrite).accessibilityIdentifier("agents-add-project")
                if !knownProjects.isEmpty {
                    Menu("已有项目") {
                        ForEach(knownProjects, id: \.self) { path in Button(path) { model.chooseProject(URL(fileURLWithPath: path)) } }
                    }.disabled(!model.canWrite)
                }
            } else {
                Button(model.section == .global ? "新建版本" : "新建模板") {
                    model.create(suggestedName: model.section == .global ? "新版本" : "新模板")
                }
                .buttonStyle(.borderedProminent).tint(ManagementStyle.actionTint).disabled(!model.canWrite).accessibilityIdentifier("agents-new")
                Menu("导入") {
                    Button("导入 Markdown") { model.importMarkdown() }
                }.disabled(!model.canWrite)
            }
        }
    }

    private var objectCards: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                if model.section == .projects {
                    ForEach(filteredProjects) { project in
                        objectCard(id: project.id, title: URL(fileURLWithPath: project.path).lastPathComponent, subtitle: project.path)
                    }
                } else {
                    ForEach(filteredEntries) { entry in
                        objectCard(id: entry.id, title: entry.name,
                                   subtitle: model.section == .templates ? "复制到项目后独立编辑" : model.library.activeGlobal?.versionId == entry.id ? "最近应用 · 实际状态见左侧" : "仅保存在版本库")
                    }
                }
                if (model.section == .projects ? filteredProjects.isEmpty : filteredEntries.isEmpty) {
                    Text(search.isEmpty ? "尚无对象，请新建、导入或添加项目。" : "没有匹配项；当前编辑内容仍保留。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.padding(1)
        }
        .frame(height: 100)
        .accessibilityIdentifier("agents-list")
    }

    private func objectCard(id: UUID, title: String, subtitle: String) -> some View {
        Button { model.select(id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).foregroundStyle(model.selection == id ? ManagementStyle.accentText : Color.primary)
                    .lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(width: 192, height: 62, alignment: .leading).padding(12)
            .managementCard(selected: model.selection == id)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain).help(title + "\n" + subtitle)
        .accessibilityLabel(title).accessibilityValue(model.selection == id ? "已选择" : "未选择")
        .accessibilityAddTraits(model.selection == id ? .isSelected : [])
        .accessibilityIdentifier("agents-entry-\(id.uuidString)")
    }

    @ViewBuilder
    private var editor: some View {
        if model.selection == nil {
            ContentUnavailableView("未选择指令文件", systemImage: "doc.text",
                                   description: Text(model.section == .projects ? "选择项目，编辑现有文件或从模板创建。" : "新建、导入或选择一个版本。保存与应用是两个动作。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity).managementCard()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if model.section == .projects {
                        Text(model.name).font(.headline)
                    } else {
                        TextField("名称", text: $model.name).textFieldStyle(.plain).font(.headline)
                            .accessibilityIdentifier("agents-name").disabled(model.fileError != nil)
                    }
                    Spacer(minLength: 8)
                    Text(model.isDirty ? "有未保存的修改" : "无未保存修改")
                        .font(.caption).foregroundStyle(model.isDirty ? Color.orange : Color.secondary)
                }
                Text(model.filePath).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(model.filePath).textSelection(.enabled)
                if let context = model.contexts.first(where: { $0.directory == (model.project?.path ?? model.store.agentDirectory.path) }),
                   context.selectedPath?.hasSuffix("AGENTS.override.md") == true {
                    Text("当前编辑的是被 override 遮蔽的底层文件；保存不代表 Pi 会选用它。应用和模板部署会被拒绝。")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let origin = model.project?.origin {
                    let customized = model.baseline?.hash != origin.createdFromHash || model.isDirty
                    Text("来自模板「\(origin.templateName)」\(customized ? "，已独立定制" : "，创建内容未变")；不会自动同步。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.fileError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                TextEditor(text: $model.text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(ManagementStyle.background, in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1) }
                    .frame(minHeight: 80)
                    .disabled(model.fileError != nil)
                    .accessibilityLabel("AGENTS 内容").accessibilityIdentifier("agents-editor")
                editorActions
                if !model.contexts.isEmpty {
                    DisclosureGroup("按所选启动目录预测的加载链") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(model.contexts.filter { $0.selectedPath != nil || $0.problem != nil }) { context in
                                    Text(context.selectedPath ?? context.problem ?? "").font(.caption).textSelection(.enabled)
                                    ForEach(context.otherPaths, id: \.self) { Text("未选中：\($0)").font(.caption).foregroundStyle(.secondary) }
                                }
                                Text("全局和祖先目录累加；override 只替代同目录文件。预测未处理嵌套 Git linked worktree 去重，也无法识别 --no-context-files、SDK 或扩展改写。项目指令不依赖项目信任。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 100)
                    }.font(.caption)
                }
            }
            .padding(16).managementCard()
        }
    }

    private var editorActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack { saveHint; Spacer(); saveActions }
            VStack(alignment: .leading, spacing: 8) { saveHint; saveActions }
        }
    }

    private var saveHint: some View {
        Text(model.section == .global ? "保存只修改库内容，不会自动应用" : model.section == .templates ? "保存模板不影响已有项目" : "保存当前项目文件")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var saveActions: some View {
        HStack {
            Button(model.section == .global ? "保存版本" : "保存") { model.save() }.disabled(!model.canSave)
                .accessibilityIdentifier("agents-save")
            if model.section == .global {
                Button("应用到全局", action: model.applyGlobal)
                    .buttonStyle(.borderedProminent).tint(ManagementStyle.actionTint)
                    .disabled(!model.canWrite || model.baseline?.data == nil || model.fileError != nil)
                    .accessibilityIdentifier("agents-apply")
            } else if model.section == .projects {
                Menu(model.baseline?.data == nil ? "从模板创建" : "用模板替换") {
                    ForEach(model.library.templates) { entry in Button(entry.name) { model.useTemplate(entry.id) } }
                }.disabled(!model.canWrite || model.library.templates.isEmpty || model.fileError != nil)
            } else {
                Button("另存为", action: model.duplicate).disabled(!model.canWrite || model.fileError != nil)
            }
            Menu("更多") {
                if model.section == .global {
                    Button("另存为", action: model.duplicate).disabled(!model.canWrite || model.fileError != nil)
                }
                if model.section == .projects {
                    Button("保存为新模板", action: model.saveProjectAsTemplate).disabled(!model.canWrite || model.fileError != nil)
                }
                Button("导出草稿", action: model.exportDraft)
                Button("恢复最近备份", action: model.restoreBackup).disabled(!model.hasBackup || !model.canWrite)
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.filePath)]) }
            }
        }
    }
}
#endif
