#if canImport(SwiftUI) && canImport(AppKit)
import PiSwitchCore
import SwiftUI

struct SidebarView: View {
    @Bindable var app: AppModel
    @State private var pendingDelete: ProviderDraft?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $app.selection) {
                ForEach(app.document.providers) { provider in
                    HStack {
                        Text(provider.name.isEmpty ? "（未命名）" : provider.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("\(provider.models.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(provider.models.count) 个模型")
                    }
                    .tag(provider.id)
                }
            }

            Divider()
            HStack(spacing: 2) {
                Button {
                    app.addProvider()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 22)
                }
                .help("新建 Provider")
                .accessibilityLabel("新建 Provider")

                Button {
                    pendingDelete = app.selection.flatMap(app.providerIndex).map { app.document.providers[$0] }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 22, height: 22)
                }
                .help("删除 Provider")
                .accessibilityLabel("删除 Provider")
                .disabled(app.selection == nil)

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .disabled(!app.isLoaded)
        .confirmationDialog(
            "删除 Provider “\(pendingDelete?.name ?? "")”？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { provider in
            Button("删除", role: .destructive) { app.deleteProvider(provider.id) }
        } message: { _ in
            Text("将同时删除其下所有模型和其他字段。保存前仍可通过重新加载撤销。")
        }
    }
}
#endif
