import SwiftUI
import AppKit
import PiSwitchCore

@main
struct AgentsUICheck {
    @MainActor static func wait(_ model: AgentsModel) async throws {
        let deadline = Date().addingTimeInterval(10)
        while model.isBusy {
            guard Date() < deadline else { throw AgentsError("UI task timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor static func answer(_ response: NSApplication.ModalResponse, text: String? = nil) {
        let timer = Timer(timeInterval: 0.08, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let window = NSApp.modalWindow else { fatalError("Expected modal confirmation") }
                if let text {
                    let field = window.contentView?.subviews.compactMap { $0 as? NSTextField }.first
                    field?.stringValue = text
                }
                func buttons(_ view: NSView) -> [NSButton] {
                    (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
                }
                let controls = window.contentView.map(buttons) ?? []
                let title: String?
                switch response {
                case .alertSecondButtonReturn: title = "放弃修改"
                case .alertThirdButtonReturn: title = "取消"
                default: title = nil
                }
                let button = controls.first { $0.tag == response.rawValue }
                    ?? controls.first { title == nil ? $0.keyEquivalent == "\r" : $0.title == title }
                guard let button else { fatalError("Missing modal button: \(controls.map(\.title))") }
                button.performClick(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        RunLoop.main.add(timer, forMode: .common)
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { await check() }
        app.run()
    }

    @MainActor static func check() async {
        do {
            let app = NSApplication.shared; app.setActivationPolicy(.regular)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "AgentsBehaviorCheck"
            window.contentView = NSHostingView(rootView: Text("正在验证隔离文件与编辑器行为…"))
            window.center(); window.makeKeyAndOrderFront(nil); app.activate()
            let directory = URL(fileURLWithPath: CommandLine.arguments[1])
            let store = AgentsStore(root: directory.appendingPathComponent("library"), agentDirectory: directory.appendingPathComponent("agent"))
            let initial = try await store.inspect()
            let id = try await store.create(.global, name: "通用", data: Data("global v1".utf8), expected: initial.revision)
            for name in ["备用全局一", "备用全局二"] {
                let revision = try await store.inspect().revision
                _ = try await store.create(.global, name: name, data: Data("alternate global".utf8), expected: revision)
            }
            let revision = try await store.inspect().revision
            let template = try await store.create(.templates, name: "项目起点", data: Data("project template".utf8), expected: revision)
            let projectURL = directory.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
            let projectRevision = try await store.inspect().revision
            let projectId = try await store.addProject(projectURL, expected: projectRevision)
            let model = AgentsModel(store: store)
            try await wait(model)
            assert(!model.isBusy && model.loadError == nil)
            model.select(id); try await wait(model)
            assert(model.text == "global v1")
            model.text = "edited library"
            let modelFile = directory.appendingPathComponent("models.json")
            let modelBytes = Data("invalid JSON".utf8)
            try modelBytes.write(to: modelFile)
            let appModel = AppModel(store: ConfigStore(path: modelFile))
            let navigation = AppNavigation(); navigation.page = .agents
            assert(!appModel.isLoaded)
            navigation.save(app: appModel, agents: model)
            assert(model.isBusy)
            model.refresh() // Must not reenter a running save.
            try await wait(model)
            let global = try await store.read(.global)
            assert(global.data == nil, "Saving a library version deployed it")
            assert(model.text == "edited library" && !model.isDirty)
            let afterLibrarySave = try Data(contentsOf: modelFile)
            assert(afterLibrarySave == modelBytes, "AGENTS save changed model configuration")
            navigation.page = .skills
            model.text = "draft"
            navigation.save(app: appModel, agents: model)
            assert(model.isDirty && !model.isBusy)
            answer(.alertThirdButtonReturn)
            model.selectSection(.templates)
            assert(model.section == .global && model.isDirty, "Cancel did not preserve draft: \(model.section) dirty=\(model.isDirty), text=\(model.text)")
            answer(.alertFirstButtonReturn)
            model.selectSection(.templates)
            try await wait(model)
            assert(model.section == .templates && !model.isDirty, "Save-and-continue did not change section")
            let saved = try await store.read(.entry(.global, id))
            assert(saved.text == "draft")
            model.select(template); try await wait(model)
            model.text = "discard this"
            answer(.alertSecondButtonReturn)
            model.selectSection(.projects); try await wait(model)
            let original = try await store.read(.entry(.templates, template))
            assert(original.text == "project template", "Discard saved changes")
            model.select(projectId); try await wait(model)
            answer(.alertFirstButtonReturn)
            model.useTemplate(template); try await wait(model)
            assert(model.text == "project template" && model.project?.origin?.templateId == template)
            model.text = "project customization"
            model.save(); try await wait(model)
            assert(model.text == "project customization")
            let afterProjectSave = try Data(contentsOf: modelFile)
            assert(afterProjectSave == modelBytes)
            model.selectSection(.global); try await wait(model)
            model.select(id); try await wait(model)
            answer(.alertFirstButtonReturn)
            model.applyGlobal(); try await wait(model)
            let applied = try await store.read(.global)
            assert(applied.text == "draft")
            assert(model.globalStatus.contains("一致"))
            model.text = "unsaved at close"
            answer(.alertThirdButtonReturn)
            assert(!model.confirmLeave(then: {}), "Closing discarded a draft")
            assert(model.isDirty)
            answer(.alertSecondButtonReturn)
            assert(model.confirmLeave(then: {}))
            assert(!model.isDirty)
            model.selectSection(.projects); try await wait(model)
            model.select(projectId); try await wait(model)
            try FileManager.default.removeItem(at: projectURL)
            model.refresh(); try await wait(model)
            assert(model.fileError != nil)
            answer(.alertFirstButtonReturn)
            model.deleteSelection(); try await wait(model)
            assert(!model.library.projects.contains { $0.id == projectId }, "Missing project cannot be unregistered")
            model.selectSection(.global); try await wait(model)
            model.select(nil); try await wait(model)
            assert(model.entries.count == 3 && model.selection == nil)
            print("PASS: isolated AGENTS save routing, no automatic deploy, busy guard, save/discard/cancel, independent project creation/edit, explicit global apply, close protection, missing project removal")
            fflush(stdout)
            let skills = SkillsModel(store: SkillStore(root: directory.appendingPathComponent("skills"), home: directory))
            navigation.page = .agents
            window.title = "AgentsUICheck"
            window.contentView = NSHostingView(rootView: ContentView(app: appModel, skills: skills, agents: model, navigation: navigation))
            window.center(); window.makeKeyAndOrderFront(nil); app.activate()
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
