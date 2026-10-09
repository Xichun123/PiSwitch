#if canImport(SwiftUI) && canImport(AppKit)
import PiSwitchCore
import SwiftUI

struct ProviderEditorView: View {
    static let apiPresets = ["openai-completions", "openai-responses", "anthropic-messages", "google-generative-ai"]

    let app: AppModel
    @Binding var provider: ProviderDraft

    @State private var showKey = false
    @State private var discovering = false
    @State private var pendingModelDelete: ModelDraft?

    var body: some View {
        Form {
            connectionSection
            modelsHeaderSection
            ForEach($provider.models) { $model in
                ModelSection(model: $model, providerAPI: provider.api.trimmed,
                             providerBaseURL: provider.baseUrl.text) { pendingModelDelete = model }
            }
        }
        .formStyle(.grouped)
        .onChange(of: provider.api.text) { provider.normalizeConnections() }
        .navigationTitle(provider.name.isEmpty ? "（未命名）" : provider.name)
        .sheet(isPresented: $discovering) {
            DiscoverySheet(provider: provider) { choices in
                provider.models = ModelMerge.merge(provider.models, importing: choices)
                app.status = .init(text: "已导入 \(choices.count) 个模型，尚未保存。", isError: false)
            }
        }
        .confirmationDialog(
            "删除模型 “\(pendingModelDelete?.currentID ?? "")”？",
            isPresented: Binding(get: { pendingModelDelete != nil }, set: { if !$0 { pendingModelDelete = nil } }),
            presenting: pendingModelDelete
        ) { model in
            Button("删除", role: .destructive) {
                provider.models.removeAll { $0.id == model.id }
            }
        }
    }

    // MARK: Sections

    private var connectionSection: some View {
        Section {
            if !provider.unmanagedKeys.isEmpty {
                Label(
                    "包含其他字段（\(provider.unmanagedKeys.joined(separator: "、"))），保存时会原样保留",
                    systemImage: "info.circle"
                )
                .foregroundStyle(.secondary)
            }

            TextField("名称", text: $provider.name, prompt: Text("必填，唯一"))

            TextField("地址", text: $provider.baseUrl.text, prompt: Text("https://api.example.com（覆盖内置时可空）"))
                .onSubmit { provider.normalizeConnections() }
            Text("OpenAI 两种格式使用末尾 /v1；Anthropic 使用不带末尾 /v1 的地址。保存和发现模型时自动处理。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if provider.usesInsecureHTTP {
                Label("使用 http://，Key 会以明文在网络上传输", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            LabeledContent("API 类型") {
                HStack(spacing: 4) {
                    TextField("API 类型", text: $provider.api.text, prompt: Text("可空"))
                        .labelsHidden()
                    Menu {
                        ForEach(Self.apiPresets, id: \.self) { preset in
                            Button(preset) { provider.api.text = preset }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("选择常用 API 类型")
                }
            }

            LabeledContent("API Key") {
                HStack(spacing: 4) {
                    Group {
                        if showKey {
                            TextField("API Key", text: $provider.apiKey.text, prompt: Text("留空则删除该字段"))
                        } else {
                            SecureField("API Key", text: $provider.apiKey.text, prompt: Text("留空则删除该字段"))
                        }
                    }
                    .labelsHidden()
                    .font(.body.monospaced())

                    Button {
                        showKey.toggle()
                    } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(showKey ? "隐藏 Key" : "显示 Key")
                    .accessibilityLabel(showKey ? "隐藏 Key" : "显示 Key")
                }
            }
            switch APIKeyKind(provider.apiKey.text) {
            case .command:
                Label("以 ! 开头：pi 会把它当作 shell 命令执行，用输出作为 Key", systemImage: "terminal")
                    .foregroundStyle(.secondary)
            case .environmentVariable:
                Label("形如环境变量名：pi 会读取同名环境变量作为 Key", systemImage: "dollarsign.circle")
                    .foregroundStyle(.secondary)
            case .empty, .literal:
                EmptyView()
            }
        } header: {
            Text("连接")
        } footer: {
            Text("pi 运行时的 --api-key 和 auth.json 优先于这里的 apiKey。models.json 与 .bak 中的 Key 是明文，别提交到 git。")
                .foregroundStyle(.secondary)
        }
    }

    private var modelsHeaderSection: some View {
        Section {
            if provider.models.isEmpty {
                Text("还没有模型。可以从接口发现，或手动添加。")
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("模型 · \(provider.models.count)")
                Spacer()
                Button("手动添加", systemImage: "plus") {
                    provider.models.append(ModelDraft(json: [:]))
                }
                Button("发现模型", systemImage: "sparkle.magnifyingglass") {
                    discovering = true
                }
            }
            .buttonStyle(.borderless)
        }
    }
}

private struct ModelSection: View {
    @Binding var model: ModelDraft
    let providerAPI: String
    let providerBaseURL: String
    let onDelete: () -> Void

    @State private var isExpanded = false

    private var inputValues: [JSONValue] {
        (try? JSONValue.decode(Data(model.input.text.utf8)))?.arrayValue ?? []
    }

    private func inputBinding(for type: String) -> Binding<Bool> {
        Binding(
            get: { inputValues.contains(.string(type)) },
            set: { selected in
                var values = inputValues.filter { $0 != .string(type) }
                if selected { values.append(.string(type)) }
                model.input.text = FieldText(json: .array(values)).text
            }
        )
    }

    var body: some View {
        Section {
            if isExpanded {
                TextField("模型 ID", text: $model.modelID.text, prompt: Text("必填"))
                    .font(.body.monospaced())
                TextField("名称", text: $model.name.text, prompt: Text("可空"))
                LabeledContent("模型 API（api）") {
                    HStack(spacing: 4) {
                        TextField("模型 API（api）", text: $model.api.text, prompt: Text("留空继承 provider"))
                            .labelsHidden()
                            .onChange(of: model.api.text) { _, value in
                                model.baseUrl.text = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? "" : model.resolvedBaseURL(providerAPI: providerAPI, providerBaseURL: providerBaseURL)
                            }
                        Menu {
                            Button("恢复继承（清空 API 和地址）") {
                                model.api.text = ""
                                model.baseUrl.text = ""
                            }
                            Divider()
                            ForEach(ProviderEditorView.apiPresets, id: \.self) { preset in
                                Button(preset) { model.api.text = preset }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("选择模型 API 类型")
                    }
                }
                TextField("模型地址（baseUrl）", text: $model.baseUrl.text, prompt: Text("留空继承 provider"))
                    .onSubmit {
                        model.baseUrl.text = model.resolvedBaseURL(providerAPI: providerAPI, providerBaseURL: providerBaseURL)
                    }
                Text("默认继承 provider，目录导入不修改模型连接。切换协议会自动处理地址末尾 /v1；可在菜单恢复继承。模型覆写优先，请核实自定义地址与兼容选项。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.baseUrl.trimmed.lowercased().hasPrefix("http://") {
                    Label("模型地址使用 http://，Key 会以明文在网络上传输", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Picker("推理（reasoning）", selection: $model.reasoning.text) {
                    Text("未设置").tag("")
                    Text("true").tag("true")
                    Text("false").tag("false")
                }
                LabeledContent("输入类型") {
                    HStack(spacing: 16) {
                        Toggle("文本", isOn: inputBinding(for: "text"))
                            .accessibilityIdentifier("model-input-text")
                        Toggle("图像", isOn: inputBinding(for: "image"))
                            .accessibilityIdentifier("model-input-image")
                    }
                    .toggleStyle(.checkbox)
                    .fixedSize()
                }
                TextField("上下文窗口", text: $model.contextWindow.text, prompt: Text("可空，正整数"))
                TextField("最大输出", text: $model.maxTokens.text, prompt: Text("可空，正整数"))
                VStack(alignment: .leading, spacing: 6) {
                    Text("cost (JSON)")
                    TextField("cost (JSON)", text: $model.cost.text, axis: .vertical)
                        .labelsHidden()
                        .accessibilityLabel("cost (JSON)")
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .lineLimit(2...)
                        .multilineTextAlignment(.leading)
                }
                .help("价格及 tiers 中的价格必须包含 input/output/cacheRead/cacheWrite 四个非负数字，阶梯还需 inputTokensAbove。留空删除，保存后写入 models.json。")
                VStack(alignment: .leading, spacing: 6) {
                    Text("thinkingLevelMap (JSON)")
                    TextField("thinkingLevelMap (JSON)", text: $model.thinkingLevelMap.text, axis: .vertical)
                        .labelsHidden()
                        .accessibilityLabel("thinkingLevelMap (JSON)")
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .lineLimit(2...)
                        .multilineTextAlignment(.leading)
                }
                .help("JSON 对象；off/minimal/low/medium/high/xhigh/max 的值为字符串或 null。留空删除。")
                VStack(alignment: .leading, spacing: 6) {
                    Text("compat (JSON)")
                    TextField("compat (JSON)", text: $model.compat.text, axis: .vertical)
                        .labelsHidden()
                        .accessibilityLabel("compat (JSON)")
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .lineLimit(2...)
                        .multilineTextAlignment(.leading)
                }
                .help("JSON 对象；留空删除。目录导入会更新此字段，请核实是否适用于当前接口。")
            }
        } header: {
            HStack {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        Text(model.currentID.isEmpty ? "新模型" : model.currentID)
                            .font(.body.monospaced())
                            .textCase(nil)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "收起模型详情" : "展开模型详情")
                .accessibilityLabel(model.currentID.isEmpty ? "新模型" : model.currentID)
                .accessibilityValue(isExpanded ? "已展开" : "已折叠")
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除模型")
                .accessibilityLabel("删除模型")
            }
        }
    }
}
#endif
