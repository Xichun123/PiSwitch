#if canImport(SwiftUI) && canImport(AppKit)
import PiSwitchCore
import SwiftUI

/// Manual metadata match for aliased IDs (e.g. a proxy calling `claude-opus-4-5` "opus-4.5").
struct CatalogPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    let modelID: String
    let catalog: [CatalogEntry]
    let current: CatalogEntry?
    let onPick: (CatalogEntry?) -> Void

    private var filtered: [CatalogEntry] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return catalog }
        return catalog.filter {
            $0.modelID.lowercased().contains(query) || $0.name.lowercased().contains(query)
        }
    }

    var body: some View {
        let groups = Dictionary(grouping: filtered, by: \.provider)

        VStack(alignment: .leading, spacing: 12) {
            Text("为 \(modelID) 选择元数据")
                .font(.headline)
            TextField("按 ID 或名称搜索", text: $search)
                .textFieldStyle(.roundedBorder)

            List {
                pickRow(entry: nil)
                ForEach(groups.keys.sorted(), id: \.self) { provider in
                    Section(provider) {
                        ForEach(groups[provider] ?? []) { entry in
                            pickRow(entry: entry)
                        }
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 560, height: 520)
    }

    private func pickRow(entry: CatalogEntry?) -> some View {
        Button {
            onPick(entry)
            dismiss()
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    if let entry {
                        Text(entry.name)
                        Text("\(entry.provider) · \(entry.modelID)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(entry.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("无（仅导入 ID）")
                    }
                }
                Spacer()
                if current?.id == entry?.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("当前选择")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
