# Agent Note: 侧边栏切换时工具栏溢出按钮闪现

Status: implemented

## Problem

用户在 v0.2.1 的侧边栏显示/隐藏动画中看到右上角 `»`，动画结束又消失。它是 AppKit 工具栏溢出指示器，不是业务按钮。只检查点击处理时间和最终状态无法覆盖此问题。v0.2.0 与 v0.2.1 的 ContentView、SidebarView 和构建 SDK 相同，不能将现象直接归因于 UA 或编译 SDK。

使用实际 ContentView 和虚构模型的独立 SwiftUI Window，按动画过程检查 `NSToolbarClippedItemsIndicator`。原布局在 12 次切换及 1040/820 宽度检查中观察到短暂指示器；具体出现次数有波动，因此不能把单次零观察当作未发生的证明。

## Decision

在 ContentView 使用本地 NavigationSplitViewVisibility 状态及原生 columnVisibility Binding，移除自动 sidebarToggle，提供固定 navigation 位置的 SwiftUI Button。按钮仍使用 sidebar.left 图标、原生列动画、显式标识和动态辅助功能名称；不访问配置、网络或直接操纵 AppKit split view，不以关闭动画遮住闪现。移除默认侧栏工具栏项后，原本随侧栏变化的工具栏分隔项不再参与布局。保留系统 split view 的列显示、模型草稿和其他工具栏动作。

新增隔离的窗口级检查：从编译后的真实视图触发侧栏按钮，在切换过程中监测溢出指示器，同时验证原生列实际显示/隐藏、文档和选择不变；不以 Core 测试或最终截图代替过程验证。

动画动作路径与实际可读取的动态名称见 [侧栏半程跳变的动画驱动](2026-10-09-sidebar-native-animation.md)。它部分替换直接 Binding 切换的优先路径；本笔记的固定按钮、工具栏布局与草稿保留决定继续适用。窄窗口下的布局约束作用域见 [侧栏展开的列级最小宽度](2026-10-09-sidebar-column-minimum-width.md)；该修复不恢复自动侧栏项。

## Historical audit

- 活跃笔记没有工具栏布局的既有决定。
- [模型默认折叠](../../implemented/feature/2026-10-01-collapsible-model-details.md) 部分重叠：保持模型按需展开与草稿保留，仅新增窗口级切换检查。
- [模型 User-Agent](../../implemented/feature/2026-10-09-model-user-agent.md) 功能和模型配置契约保持不变。本修复不撤销 UA，不宣称 UA 是溢出指示器的根因。
- [Skills 管理](../../implemented/feature/2026-10-08-skill-management.md) 的 Tab、独立存储、启用与安全退出规则保持不变。

## Alternatives considered

- 提高 ToolbarItemGroup 的 visibilityPriority：只有一行，仍由系统决定真正空间不足时的溢出，最少干预；隔离检查仍捕捉到临时指示器，不能解决此次列工具栏变化。
- 把工具栏 modifier 移到外层 VStack：保留默认侧栏按钮，改动集中于视图归属；实际生成的默认侧栏项与分隔项未变，隔离检查仍出现指示器。
- 直接隐藏 AppKit 溢出控件或更换整个导航布局：前者能遮住症状，但会掩盖真正空间不足的操作入口；后者可完全掌握动画，但替换原生导航并引入更多维护。采用公开 SwiftUI 列状态和固定按钮，不接触生产代码中的私有控件。

## Consequences

- 工具栏使用固定的侧栏按钮，不再由自动侧栏项及随列宽变化的分隔项参与布局。刷新、保存、模型表单、Skills 及配置格式保持不变；没有在产品中隐藏溢出控件。
- 增加一个窗口本地列状态和按钮；侧栏显示状态只在窗口生命周期内保存，不新增配置字段。按钮仍可键盘聚焦，并提供动态显示/隐藏名称与帮助。
- 过程检查仅覆盖当前 macOS 27 环境、默认请求宽度 1040 及缩窄到 820，不保证所有系统版本和连续帧无掉帧。宽度由系统布局约束决定，检查实际列折叠变化，不只检查按钮返回成功。
- 测试识别 AppKit 私有指示器类名，产品实现只用公开 SwiftUI API；系统改名时需更新测试观测方式。20 ms 采样不是逐帧证明，不能把零观察泛化为所有环境下不会闪现。

## Verification

- 原布局的独立虚构配置窗口捕捉到临时溢出指示器；提高 priority 和只移动 toolbar 的试验仍观察到它。本记录不把 v0.2.0 没有用户报告解释为它没有潜在布局问题。
- `swift build` 和 `swift test` 通过，42 项 Core 测试零失败。
- `bash Tests/check-sidebar-ui.sh` 通过三轮窗口检查，共 36 次切换。每轮实际原生列折叠变化 12 次，溢出指示器采样为零，模型选择、完整草稿及临时文件不变。检查包含未修改和带名称/UA 未保存草稿的情形。
- 新检查在每轮最后切到 Skills 再回模型页，验证模型的重新加载/保存按钮只在模型页出现。脚本编译真实 ContentView、SidebarView、ProviderEditorView 和 AppModel；Skills 使用临时目录，不访问用户配置或执行真实更新。
- `bash Tests/check-model-disclosure.sh` 通过，UA 默认值、编辑、输入复选框和折叠保留仍有效。笔记树/格式/归档和 diff 检查通过。实现及本地验收阶段未创建提交、推送标签或发布新版本；发行目标为 v0.2.2。
- 按用户要求，用 release 本地构建替换 `/Applications/PiSwitch.app` 并重新打开，不写模型配置。版本元数据仍为 0.2.1；暂存 App 与构建二进制 UUID 一致，安装前后签名验证通过，安装后二进制 SHA256 与暂存 App 一致。旧版备份位于 `.build/install-sidebar-fix.pfsIwB/PiSwitch.previous.app`，实际界面效果留给用户验收。
