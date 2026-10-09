#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import PiSwitchCore

struct AddSkillsSheet: View {
    @Bindable var model: SkillsModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var selected = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("从 GitHub 添加 Skills").font(.title2)
            Text("仅支持公开仓库默认分支。下载不会执行脚本；启用前请审查第三方内容。")
                .foregroundStyle(.secondary)
            HStack {
                TextField("https://github.com/owner/repo", text: $address)
                    .textFieldStyle(.roundedBorder).disabled(model.isBusy)
                Button("解析") { selected = []; model.parse(address) }
                    .disabled(model.isBusy || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = model.parseError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let snapshot = model.parsedSnapshot {
                Text("\(snapshot.repository.url) · 提交 \(snapshot.commit.prefix(8))").font(.caption).textSelection(.enabled)
                List(model.candidates) { candidate in
                    let problem = candidate.problem ?? model.candidateProblems[candidate.id]
                    Toggle(isOn: Binding(get: { selected.contains(candidate.id) && problem == nil }, set: { if $0 { selected.insert(candidate.id) } else { selected.remove(candidate.id) } })) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.metadata?.name ?? "无法添加").font(.headline)
                            Text(candidate.metadata?.description ?? "").font(.callout).foregroundStyle(.secondary)
                            Text(candidate.path.isEmpty ? "仓库根目录" : candidate.path).font(.caption).textSelection(.enabled)
                            if let problem { Text(problem).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                    }
                    .toggleStyle(.checkbox).disabled(model.isBusy || problem != nil)
                }
            } else {
                Spacer()
                Text("解析后列出候选，由你勾选。即使只有一个 skill，也不会自动添加。")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if model.isBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.progress)
                    Button("安全停止") { model.requestStop() }
                }
            }
            if !model.results.isEmpty {
                DisclosureGroup("添加结果（\(model.results.count)）") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.results) { result in
                                Text("\(result.name)：\(result.message)").font(.caption)
                                    .foregroundStyle(result.isError ? Color.red : Color.primary).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 100)
                }
            }
            HStack {
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isBusy)
                Spacer()
                Button("添加所选") { model.install(selected) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || model.loadError != nil || !model.candidates.contains(where: { selected.contains($0.id) && $0.metadata != nil && model.candidateProblems[$0.id] == nil }))
            }
        }
        .padding(20).frame(width: 680, height: 540)
        .interactiveDismissDisabled(model.isBusy)
    }
}
#endif
