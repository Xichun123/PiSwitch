#if canImport(SwiftUI) && canImport(AppKit)
import PiSwitchCore
import SwiftUI

struct ContentView: View {
    @Bindable var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView(app: app)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
            } detail: {
                detail
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        app.reload()
                    } label: {
                        Label("重新加载", systemImage: "arrow.clockwise")
                    }
                    .help("重新加载（⌘R）")

                    Button {
                        app.save()
                    } label: {
                        Label("保存", systemImage: "square.and.arrow.down")
                    }
                    .help("保存（⌘S）")
                    .disabled(!app.canSave)
                }
            }

            StatusBar(app: app)
        }
        .background(WindowCloseGuard { app.confirmClose() })
    }

    @ViewBuilder
    private var detail: some View {
        switch app.loadState {
        case .failed(let message):
            LoadErrorView(message: message) { app.reload() }
        case .loaded:
            if let id = app.selection, let index = app.providerIndex(id) {
                ProviderEditorView(app: app, provider: binding(for: id, fallback: app.document.providers[index]))
                    .id(id)
            } else {
                ContentUnavailableView(
                    "未选择 Provider",
                    systemImage: "server.rack",
                    description: Text("在左侧选择一个 Provider，或点击 + 新建。")
                )
            }
        }
    }

    /// Looks up by id on every access so a deleted provider can never be read through a stale index.
    private func binding(for id: ProviderDraft.ID, fallback: ProviderDraft) -> Binding<ProviderDraft> {
        Binding(
            get: { app.providerIndex(id).map { app.document.providers[$0] } ?? fallback },
            set: { newValue in
                if let index = app.providerIndex(id) { app.document.providers[index] = newValue }
            }
        )
    }
}

private struct LoadErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("无法加载配置", systemImage: "exclamationmark.octagon")
        } description: {
            VStack(spacing: 8) {
                Text(message)
                    .textSelection(.enabled)
                Text("为防止覆盖原文件，已禁止编辑和保存。修复文件后重新加载。")
                    .foregroundStyle(.secondary)
            }
        } actions: {
            Button("重新加载", action: retry)
                .keyboardShortcut(.defaultAction)
        }
    }
}
#endif
