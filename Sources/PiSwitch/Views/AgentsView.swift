#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit
import PiSwitchCore

struct AgentsView: View {
    @Bindable var model: AgentsModel
    let knownProjects: [String]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("管理对象", selection: Binding(get: { model.section }, set: { model.selectSection($0) })) {
                    ForEach(AgentsSection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(maxWidth: 380)
                .accessibilityIdentifier("agents-section")
                Spacer()
                Button("重新加载", action: model.refresh).disabled(model.isBusy)
                    .accessibilityIdentifier("agents-reload")
            }.padding()
            Text("\(model.globalStatus) · 全局位置：\(model.store.globalURL.path)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.bottom, 8)
            Divider()
            if let error = model.loadError {
                ContentUnavailableView("无法加载 AGENTS 记录", systemImage: "exclamationmark.octagon",
                                       description: Text(error + "\n已禁止写入，请修复记录后重新加载。"))
            } else {
                HSplitView {
                    sidebar.frame(minWidth: 200, idealWidth: 240, maxWidth: 340, maxHeight: .infinity)
                    editor.frame(minWidth: 540, maxHeight: .infinity)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                if model.isBusy { ProgressView("正在检查或写入文件…").controlSize(.small) }
                if !model.message.isEmpty { Text(model.message).textSelection(.enabled) }
                ForEach(model.warnings, id: \.self) { Text($0).foregroundStyle(.orange).textSelection(.enabled) }
                Text("实际指令变化后执行 /reload。")
                    .foregroundStyle(.secondary)
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
        .disabled(model.isBusy)
    }

    private var sidebar: some View {
        VStack(spacing: 8) {
            HStack {
                if model.section == .projects {
                    Button("添加项目") { model.chooseProject() }.accessibilityIdentifier("agents-add-project")
                    if !knownProjects.isEmpty {
                        Menu("已有项目") {
                            ForEach(knownProjects, id: \.self) { path in
                                Button(path) { model.chooseProject(URL(fileURLWithPath: path)) }
                            }
                        }
                    }
                } else {
                    Button("新建") { model.create(suggestedName: model.section == .global ? "新版本" : "新模板") }
                        .accessibilityIdentifier("agents-new")
                    Button("导入") { model.importMarkdown() }
                }
            }.padding(.top, 10).disabled(!model.canWrite)
            List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
                if model.section == .projects {
                    ForEach(model.library.projects) { project in
                        VStack(alignment: .leading) {
                            Text(URL(fileURLWithPath: project.path).lastPathComponent)
                            Text(project.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }.tag(project.id)
                    }
                } else {
                    ForEach(model.entries) { entry in
                        HStack {
                            Text(entry.name)
                            if model.section == .global, model.library.activeGlobal?.versionId == entry.id {
                                Image(systemName: "checkmark.circle").help("最近应用的版本；实际文件状态见上方")
                            }
                        }.tag(entry.id)
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: .infinity)
            .accessibilityIdentifier("agents-list")
            if model.section == .global {
                Button("导入现有全局", action: model.importCurrentGlobal).disabled(!model.canWrite)
                    .accessibilityIdentifier("agents-import-global")
                Button("恢复全局文件备份", action: model.restoreGlobalBackup).disabled(!model.canWrite)
                Button("解除全局管理", action: model.detachGlobal)
                    .disabled(!model.canWrite || model.library.activeGlobal == nil)
            }
            Button(model.section == .projects ? "移除项目登记" : "删除所选", action: model.deleteSelection)
                .disabled(!model.canWrite || model.selection == nil)
                .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if model.selection == nil {
            ContentUnavailableView("未选择指令文件", systemImage: "doc.text",
                                   description: Text(model.section == .projects ? "选择项目，编辑现有文件或从模板创建。" : "新建、导入或选择一个版本。保存与应用是两个动作。"))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if model.section == .projects {
                    Text(model.name).font(.headline)
                } else {
                    TextField("名称", text: $model.name).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("agents-name").disabled(model.fileError != nil)
                }
                Text(model.filePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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
                if let error = model.fileError {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    Button("保存") { model.save() }.disabled(!model.canSave)
                        .accessibilityIdentifier("agents-save")
                    if model.section == .global {
                        Button("应用到全局", action: model.applyGlobal)
                            .disabled(!model.canWrite || model.baseline?.data == nil || model.fileError != nil)
                            .accessibilityIdentifier("agents-apply")
                    } else if model.section == .projects {
                        Menu(model.baseline?.data == nil ? "从模板创建" : "用模板替换") {
                            ForEach(model.library.templates) { entry in
                                Button(entry.name) { model.useTemplate(entry.id) }
                            }
                        }.disabled(!model.canWrite || model.library.templates.isEmpty || model.fileError != nil)
                        Button("保存为新模板", action: model.saveProjectAsTemplate)
                            .disabled(!model.canWrite || model.fileError != nil)
                    } else {
                        Button("另存为", action: model.duplicate).disabled(!model.canWrite || model.fileError != nil)
                    }
                    Spacer()
                    Menu("更多") {
                        if model.section == .global { Button("另存为", action: model.duplicate) }
                        Button("导出草稿", action: model.exportDraft)
                        Button("恢复最近备份", action: model.restoreBackup).disabled(!model.hasBackup || !model.canWrite)
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.filePath)])
                        }
                    }
                }
                TextEditor(text: $model.text)
                    .font(.system(.body, design: .monospaced))
                    .border(Color.secondary.opacity(0.3))
                    .disabled(model.fileError != nil)
                    .accessibilityLabel("AGENTS 内容").accessibilityIdentifier("agents-editor")
                if model.isDirty { Text("有未保存的修改").font(.caption).foregroundStyle(.orange) }
                if !model.contexts.isEmpty {
                    DisclosureGroup("按所选启动目录预测的加载链") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.contexts.filter { $0.selectedPath != nil || $0.problem != nil }) { context in
                                Text(context.selectedPath ?? context.problem ?? "")
                                    .font(.caption).textSelection(.enabled)
                                ForEach(context.otherPaths, id: \.self) { Text("未选中：\($0)").font(.caption).foregroundStyle(.secondary) }
                            }
                            Text("全局和祖先目录累加；override 只替代同目录文件。预测未处理嵌套 Git linked worktree 去重，也无法识别 --no-context-files、SDK 或扩展改写。项目指令不依赖项目信任。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.padding()
        }
    }
}
#endif
