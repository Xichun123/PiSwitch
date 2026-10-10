#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI

@main
struct PiSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        let model = appDelegate.model
        Window("Pi Switch", id: "main") {
            ContentView(app: model, skills: appDelegate.skills, agents: appDelegate.agents, navigation: appDelegate.navigation)
                .frame(minHeight: 520)
        }
        .defaultSize(width: 1040, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .saveItem) {
                Button("保存") { appDelegate.navigation.save(app: model, agents: appDelegate.agents) }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!appDelegate.navigation.canSave(app: model, agents: appDelegate.agents))
                Button("重新加载") {
                    switch appDelegate.navigation.page {
                    case .models: model.reload()
                    case .skills: appDelegate.skills.refresh()
                    case .agents: appDelegate.agents.refresh()
                    }
                }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let skills = SkillsModel()
    let agents = AgentsModel()
    let navigation = AppNavigation()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched via `swift run` without an app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        skills.confirmIdle() && agents.confirmLeave(then: { NSApp.terminate(nil) }) && model.confirmQuit()
            ? .terminateNow : .terminateCancel
    }
}
#else
@main
enum PiSwitchApp {
    static func main() {
        print("Pi Switch 的界面只支持 macOS。PiSwitchCore 可在此平台编译与测试。")
    }
}
#endif
