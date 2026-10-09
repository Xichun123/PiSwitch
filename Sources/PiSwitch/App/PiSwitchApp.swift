#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI

@main
struct PiSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        let model = appDelegate.model
        Window("Pi Switch", id: "main") {
            ContentView(app: model, skills: appDelegate.skills)
                .frame(minHeight: 520)
        }
        .defaultSize(width: 1040, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .saveItem) {
                Button("保存") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.canSave)
                Button("重新加载") { model.reload() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let skills = SkillsModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched via `swift run` without an app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        skills.confirmIdle() && model.confirmQuit() ? .terminateNow : .terminateCancel
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
