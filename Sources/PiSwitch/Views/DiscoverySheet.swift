#if canImport(SwiftUI) && canImport(AppKit)
import Observation
import PiSwitchCore
import SwiftUI

@MainActor
@Observable
final class DiscoveryModel {
    enum Phase: Equatable {
        case loading
        case failed(String)
        case ready
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let exists: Bool
        var selected: Bool
        var entry: CatalogEntry?
    }

    let providerName: String
    let requestURL: URL?
    let isInsecure: Bool
    private let baseUrl: String
    private let apiKey: String
    private let kind: DiscoveryProtocol?
    private let existingIDs: Set<String>

    private(set) var phase: Phase = .loading
    private(set) var catalog: [CatalogEntry] = []
    private(set) var catalogError: String?
    var rows: [Row] = []
    var search = ""
    var attempt = 0

    init(provider: ProviderDraft) {
        providerName = provider.name
        baseUrl = provider.baseUrl.text
        apiKey = provider.apiKey.text
        kind = DiscoveryProtocol(api: provider.api.text)
        existingIDs = Set(provider.models.map(\.currentID))
        requestURL = kind.flatMap { try? ModelListClient.modelsURL(baseUrl: provider.baseUrl.text, kind: $0) }
        isInsecure = requestURL?.scheme?.lowercased() == "http"
    }

    var filteredRows: [Row] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return rows }
        return rows.filter {
            $0.id.lowercased().contains(query) || ($0.entry?.name.lowercased().contains(query) ?? false)
        }
    }

    var selectedCount: Int { rows.filter(\.selected).count }

    var choices: [ImportChoice] {
        rows.filter(\.selected).map { ImportChoice(modelID: $0.id, entry: $0.entry) }
    }

    func isSelected(_ id: String) -> Binding<Bool> {
        Binding(
            get: { self.rows.first { $0.id == id }?.selected ?? false },
            set: { value in
                if let index = self.rows.firstIndex(where: { $0.id == id }) { self.rows[index].selected = value }
            }
        )
    }

    func setVisible(selected: Bool) {
        let visible = Set(filteredRows.map(\.id))
        for index in rows.indices where visible.contains(rows[index].id) {
            rows[index].selected = selected
        }
    }

    func setEntry(_ entry: CatalogEntry?, for id: String) {
        if let index = rows.firstIndex(where: { $0.id == id }) { rows[index].entry = entry }
    }

    func run() async {
        phase = .loading
        guard let kind else {
            phase = .failed(DiscoveryError.unsupportedAPI.localizedDescription)
            return
        }

        let fetcher = HTTPFetcher()
        let client = ModelListClient(fetcher: fetcher)
        let baseUrl = baseUrl
        let apiKey = apiKey

        async let idsResult = client.fetchIDs(baseUrl: baseUrl, apiKey: apiKey, kind: kind)
        async let catalogResult = Self.loadCatalog(fetcher)

        do {
            let ids = try await idsResult
            let catalogOutcome = await catalogResult
            try Task.checkCancellation()

            switch catalogOutcome {
            case .success(let entries):
                catalog = entries
                catalogError = nil
            case .failure(let error):
                catalog = []
                catalogError = error.localizedDescription
            }

            let byID = Dictionary(catalog.map { ($0.modelID, $0) }, uniquingKeysWith: { first, _ in first })
            rows = ids.map { id in
                let exists = existingIDs.contains(id)
                return Row(id: id, exists: exists, selected: !exists, entry: byID[id])
            }
            phase = .ready
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private nonisolated static func loadCatalog(_ fetcher: HTTPFetcher) async -> Result<[CatalogEntry], Error> {
        do {
            return .success(try await Catalog.fetch(using: fetcher))
        } catch {
            return .failure(error)
        }
    }
}

struct DiscoverySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: DiscoveryModel
    @State private var picking: PickTarget?
    let onImport: ([ImportChoice]) -> Void

    init(provider: ProviderDraft, onImport: @escaping ([ImportChoice]) -> Void) {
        _model = State(initialValue: DiscoveryModel(provider: provider))
        self.onImport = onImport
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(16)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(16)
        }
        .frame(minWidth: 780, idealWidth: 880, minHeight: 520, idealHeight: 620)
        // Keyed on `attempt` so retries restart it; the task is cancelled when the sheet closes.
        .task(id: model.attempt) { await model.run() }
        .sheet(item: $picking) { target in
            CatalogPickerView(
                modelID: target.id,
                catalog: model.catalog,
                current: model.rows.first { $0.id == target.id }?.entry
            ) { entry in
                model.setEntry(entry, for: target.id)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("发现模型 · \(model.providerName)")
                .font(.headline)
            if let url = model.requestURL {
                Text("GET \(url.absoluteString)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if model.isInsecure {
                Label("使用 http://，Key 会以明文在网络上传输", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let error = model.catalogError, model.phase == .ready {
                Label("元数据不可用，仅导入模型 ID（\(error)）", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if model.phase == .ready, !model.rows.isEmpty {
                HStack {
                    TextField("搜索 ID 或名称", text: $model.search)
                        .textFieldStyle(.roundedBorder)
                    Button("全选") { model.setVisible(selected: true) }
                    Button("全不选") { model.setVisible(selected: false) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("正在请求模型列表和元数据目录…")
        case .failed(let message):
            ContentUnavailableView {
                Label("发现失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message).textSelection(.enabled)
            } actions: {
                Button("重试") { model.attempt += 1 }
            }
        case .ready:
            if model.rows.isEmpty {
                ContentUnavailableView("接口没有返回任何模型", systemImage: "tray")
            } else {
                table
            }
        }
    }

    private var table: some View {
        Table(model.filteredRows) {
            TableColumn("导入") { row in
                Toggle("导入 \(row.id)", isOn: model.isSelected(row.id))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            .width(40)

            TableColumn("模型 ID") { row in
                HStack(spacing: 6) {
                    Text(row.id)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if row.exists {
                        Text("已存在")
                            .font(.caption)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            .width(min: 180, ideal: 260)

            TableColumn("元数据") { row in
                HStack(spacing: 6) {
                    if let entry = row.entry {
                        Text(entry.id)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(entry.id)
                    } else {
                        Text("无元数据").foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button("更换…") { picking = PickTarget(id: row.id) }
                        .buttonStyle(.link)
                        .disabled(model.catalog.isEmpty)
                }
            }
            .width(min: 180, ideal: 240)

            TableColumn("预览") { row in
                Text(row.entry?.summary ?? "—")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(row.entry?.summary ?? "")
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("目录价格是官方价，不代表中转站报价。导入只修改草稿，仍需保存。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("取消", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("导入 \(model.selectedCount) 个模型") {
                onImport(model.choices)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.phase != .ready || model.selectedCount == 0)
        }
    }
}

struct PickTarget: Identifiable {
    let id: String
}
#endif
