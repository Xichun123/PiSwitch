#if canImport(SwiftUI) && canImport(AppKit)
import PiSwitchCore
import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var app: AppModel
    @Bindable var skills: SkillsModel
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        TabView {
            modelsContent.tabItem { Label("模型", systemImage: "server.rack") }
            SkillsView(model: skills).frame(minWidth: 820).tabItem { Label("Skills", systemImage: "books.vertical") }
        }
        .background(WindowCloseGuard { skills.confirmIdle() && app.confirmClose() })
    }

    private var modelsContent: some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView(app: app)
                    .toolbar(removing: .sidebarToggle)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
            } detail: {
                // Scope the default 820-point minimum to its columns: 590 detail + 230 sidebar.
                detail.frame(minWidth: 590)
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        // Let AppKit own the split-view animation, not a window-wide SwiftUI transaction.
                        if !NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil) {
                            withAnimation {
                                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                            }
                        }
                    } label: {
                        Label(columnVisibility == .detailOnly ? "显示侧边栏" : "隐藏侧边栏", systemImage: "sidebar.left")
                    }
                    .accessibilityIdentifier("sidebar-toggle")
                    .help(columnVisibility == .detailOnly ? "显示侧边栏" : "隐藏侧边栏")
                }
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
