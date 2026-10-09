#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import Observation
import PiSwitchCore

@MainActor
@Observable
final class AppModel {
    enum LoadState: Equatable {
        case loaded
        case failed(String)
    }

    struct Status: Equatable {
        var text: String
        var isError: Bool
    }

    let store: ConfigStore
    private(set) var loadState: LoadState = .loaded
    var document: ConfigDocument = .empty
    var selection: ProviderDraft.ID?
    var status: Status?

    private var cleanDocument: ConfigDocument = .empty
    private var baseline: Data?
    private var closeAcknowledged = false

    init(store: ConfigStore = ConfigStore()) {
        self.store = store
        load()
    }

    var isLoaded: Bool { loadState == .loaded }
    var isDirty: Bool { isLoaded && document != cleanDocument }
    var canSave: Bool { isDirty }

    var displayPath: String {
        let path = store.resolvedPath.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    func providerIndex(_ id: ProviderDraft.ID) -> Int? {
        document.providers.firstIndex { $0.id == id }
    }

    // MARK: Load / save

    private func load() {
        let previousName = selection.flatMap(providerIndex).map { document.providers[$0].name }
        do {
            let loaded = try store.load()
            document = loaded.document
            cleanDocument = loaded.document
            baseline = loaded.baseline
            loadState = .loaded
            selection = document.providers.first { $0.name == previousName }?.id ?? document.providers.first?.id
            status = Status(text: loaded.baseline == nil ? "文件不存在，保存时将创建。" : "已加载。", isError: false)
        } catch {
            document = .empty
            cleanDocument = .empty
            baseline = nil
            selection = nil
            loadState = .failed(error.localizedDescription)
            status = Status(text: error.localizedDescription, isError: true)
        }
    }

    func reload() {
        guard confirmDiscardChanges(before: "重新加载") else { return }
        load()
    }

    @discardableResult
    func save() -> Bool {
        guard isLoaded else { return false }
        do {
            for index in document.providers.indices { document.providers[index].normalizeConnections() }
            baseline = try store.save(document, baseline: baseline)
            cleanDocument = document
            status = Status(text: "已保存。在 pi 中执行 /model 重新加载。", isError: false)
            return true
        } catch {
            status = Status(text: error.localizedDescription, isError: true)
            return false
        }
    }

    // MARK: Unsaved-change guards

    /// Returns true when the pending action may proceed.
    func confirmDiscardChanges(before action: String) -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "有未保存的修改"
        alert.informativeText = "\(action)前是否保存修改？"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func confirmClose() -> Bool {
        let proceed = confirmDiscardChanges(before: "关闭窗口")
        // Closing the only window quits the app; don't ask a second time.
        if proceed { closeAcknowledged = true }
        return proceed
    }

    func confirmQuit() -> Bool {
        closeAcknowledged || confirmDiscardChanges(before: "退出")
    }

    // MARK: Editing

    func addProvider() {
        let names = Set(document.providers.map(\.name))
        var number = 1
        while names.contains("provider-\(number)") { number += 1 }
        let provider = ProviderDraft.new(named: "provider-\(number)")
        document.providers.append(provider)
        selection = provider.id
    }

    func deleteProvider(_ id: ProviderDraft.ID) {
        guard let index = providerIndex(id) else { return }
        if selection == id { selection = nil }
        document.providers.remove(at: index)
        if selection == nil {
            selection = document.providers[safe: min(index, document.providers.count - 1)]?.id
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
