import SwiftUI
import AppKit
import ApplicationServices
import PiSwitchCore

@MainActor
final class SidebarCheckDelegate: NSObject, NSApplicationDelegate {
    let directory: URL
    let model: AppModel
    let skills: SkillsModel
    let initialData: Data
    let draft: ConfigDocument
    let selection: ProviderDraft.ID?
    var timer: Timer?
    var tick = 0
    var overflowSamples = 0
    var previousCollapsed: Bool?
    var columnChanges = 0
    var sawCollapsedMinimum = false

    override init() {
        guard let root = ProcessInfo.processInfo.environment["PISWITCH_UI_TEST_ROOT"] else {
            fatalError("PISWITCH_UI_TEST_ROOT is required")
        }
        directory = URL(fileURLWithPath: root)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        initialData = Data(#"{"providers":{"Fixture":{"baseUrl":"https://proxy.example/v1","api":"openai-responses","apiKey":"sk-test","models":[{"id":"alpha"},{"id":"beta"}]}}}"#.utf8)
        let file = directory.appendingPathComponent("models.json")
        try! initialData.write(to: file)
        model = AppModel(store: ConfigStore(path: file))
        if CommandLine.arguments.contains("--dirty") {
            model.document.providers[0].models[0].name.text = "Unsaved name"
            model.document.providers[0].models[0].setUserAgentEnabled(true)
            model.document.providers[0].models[0].userAgent.text = "Unsaved/1.0"
        }
        draft = model.document
        selection = model.selection
        skills = SkillsModel(store: SkillStore(root: directory.appendingPathComponent("skills"), home: directory))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [self] _ in
            MainActor.assumeIsolated { step() }
        }
    }

    func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func step() {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let root = window.contentView?.superview else { return }
        tick += 1
        if tick == 1 {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        let views = descendants(root)
        if let split = views.compactMap({ $0 as? NSSplitView }).first,
           let sidebar = split.arrangedSubviews.first {
            let collapsed = split.isSubviewCollapsed(sidebar)
            if collapsed && window.minSize.width <= 590 { sawCollapsedMinimum = true }
            if let previousCollapsed, previousCollapsed != collapsed { columnChanges += 1 }
            previousCollapsed = collapsed
        }
        // ponytail: AppKit indicator names are verified on macOS 27; update this probe if they change.
        if tick >= 100, views.contains(where: {
            let name = String(describing: type(of: $0))
            return (name.contains("ClippedItems") || name.contains("Overflow")) &&
                !$0.isHiddenOrHasHiddenAncestor && $0.alphaValue > 0 && !$0.visibleRect.isEmpty
        }) {
            overflowSamples += 1
        }
        if tick == 380 {
            var frame = window.frame
            frame.size.width = 820
            window.setFrame(frame, display: true)
        }
        if tick == 800 {
            let unchanged = model.document == draft && model.selection == selection &&
                (try! Data(contentsOf: directory.appendingPathComponent("models.json"))) == initialData
            print("RESULT: column_changes=\(columnChanges), overflow_samples=\(overflowSamples), collapsed_minimum=\(sawCollapsedMinimum), draft_and_file_unchanged=\(unchanged)")
            timer?.invalidate()
            fflush(stdout)
            exit(columnChanges == 12 && previousCollapsed == false && overflowSamples == 0 && sawCollapsedMinimum && unchanged ? 0 : 1)
        }
    }
}

struct SidebarCheckApp: App {
    @NSApplicationDelegateAdaptor(SidebarCheckDelegate.self) var delegate
    var body: some Scene {
        Window("SidebarUICheck", id: "check") {
            ContentView(app: delegate.model, skills: delegate.skills)
                .frame(minHeight: 520)
        }
        .defaultSize(width: 1040, height: 700)
    }
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func findElement(_ root: AXUIElement, depth: Int = 0, matching predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    guard depth < 12 else { return nil }
    if predicate(root) { return root }
    for child in attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let found = findElement(child, depth: depth + 1, matching: predicate) { return found }
    }
    return nil
}

func namedControl(_ root: AXUIElement, _ title: String) -> AXUIElement? {
    findElement(root) {
        let role = attribute($0, kAXRoleAttribute) as? String
        return (role == kAXButtonRole || role == kAXRadioButtonRole) &&
            (attribute($0, kAXTitleAttribute) as? String == title || attribute($0, kAXDescriptionAttribute) as? String == title)
    }
}

func press(_ element: AXUIElement?) {
    guard let element, AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
        fatalError("UI control missing or press failed")
    }
}

@main
@MainActor
enum SidebarUICheck {
    static func main() {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--probe",
              let pid = Int32(CommandLine.arguments[2]) else {
            SidebarCheckApp.main()
            return
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 5)
        Thread.sleep(forTimeInterval: 1)
        let sidebarButton = findElement(app) {
            attribute($0, kAXRoleAttribute) as? String == kAXButtonRole &&
                attribute($0, kAXIdentifierAttribute) as? String == "sidebar-toggle"
        }
        precondition(attribute(app, kAXFrontmostAttribute) as? Bool == true)
        precondition(namedControl(app, "隐藏侧边栏") != nil,
            "Sidebar label missing: title=\(String(describing: sidebarButton.flatMap { attribute($0, kAXTitleAttribute) })), description=\(String(describing: sidebarButton.flatMap { attribute($0, kAXDescriptionAttribute) }))")
        for index in 0..<12 {
            press(sidebarButton)
            Thread.sleep(forTimeInterval: 0.8)
            precondition(namedControl(app, index.isMultiple(of: 2) ? "显示侧边栏" : "隐藏侧边栏") != nil,
                "Sidebar label did not follow the native column state")
        }
        precondition(namedControl(app, "重新加载") != nil && namedControl(app, "保存") != nil)
        press(namedControl(app, "Skills"))
        Thread.sleep(forTimeInterval: 0.4)
        precondition(namedControl(app, "重新加载") == nil && namedControl(app, "保存") == nil)
        press(namedControl(app, "模型"))
        Thread.sleep(forTimeInterval: 0.4)
        precondition(namedControl(app, "重新加载") != nil && namedControl(app, "保存") != nil)
        print("PASS: 12 sidebar presses and model/Skills toolbar scoping")
    }
}
