# Agent Note: 侧栏半程跳变的动画驱动

Status: implemented

## Problem

用户提供的 60 fps 录屏显示侧栏展开过程中的半程跳变。按空白内容区的背景边缘观察，0.7167–0.7500 s 的边缘位于视频横坐标约 852 px，0.7667 s 跳到约 1001 px；这是画面中的空间跳变，不能用主线程没有长时间阻塞来排除。

隔离窗口中的真实 ContentView、虚构配置及名称选中状态没有稳定复现这个跳变。其窗口级录像包含完整展开过程。诊断时的安装版与改动前 release 二进制的 Mach-O UUID 相同，不能归因为用户仍运行另一版源码。上述观察不足以证明具体的系统布局根因。

## Decision

固定的侧栏按钮优先发送公开的 NSSplitViewController.toggleSidebar 系统动作，由 AppKit 驱动原生分栏动画，不由按钮额外创建覆盖窗口的 SwiftUI withAnimation 事务。NavigationSplitView 的 columnVisibility Binding 继续接收系统回写并驱动按钮名称。系统动作没有接收者时，保留原来的 Binding 与 withAnimation 路径，避免后台窗口的程序化点击变成无效操作。

原生动作路由继续保留，但单独改变路由没有解决窄窗口跳变。用户反馈横向拉宽后问题消失，后续隔离录像在 820/940 点复现了相同现象。[列级最小宽度](2026-10-09-sidebar-column-minimum-width.md) 补充布局约束作用域的修复；不能把本笔记的功能测试通过解释为旧候选已经解决卡顿。保留原生 NavigationSplitView、动画、分栏宽度范围和关闭保护。

侧栏 UI 检查像产品启动一样激活测试应用，并检查每次切换后的按钮名称与实际列状态。按钮的 Label 文本直接绑定列状态：本机工具栏辅助功能探测读取原 Label 的“侧边栏”，没有使用 Button 上的 accessibilityLabel 覆写；改为动态 Label 后，显示/隐藏名称可被实际探测到。工具栏仍显示原来的图标。

## Historical audit

- [工具栏溢出修复](2026-10-09-sidebar-toolbar-overflow.md) 部分重叠：固定按钮、移除自动 sidebarToggle、工具栏位置及草稿保留继续适用；本笔记替换优先使用的动画动作路径并补充实际可读取的名称。不撤销原工具栏修复，也不归档该笔记。
- [模型默认折叠](../../implemented/feature/2026-10-01-collapsible-model-details.md)、[模型 User-Agent](../../implemented/feature/2026-10-09-model-user-agent.md) 和 [Skills 管理](../../implemented/feature/2026-10-08-skill-management.md) 的行为与存储契约保持不变。

## Alternatives considered

- 只调整 withAnimation 的曲线：改动最小，仍保留 SwiftUI 公共 Binding；隔离比较中原生分栏的宽度变化序列未因此改变，不能针对录屏中的半程跳变提供依据。
- 直接移除 withAnimation：减少外围动画事务且没有 AppKit 动作路由；隔离测试只观察到列状态切换，没有连续展开宽度，等于去掉用户需要的展开动画，不采用。
- 固定侧栏内容最小宽度或设置 balanced 样式：保持 SwiftUI 实现，可能避免中间宽度下的内容布局变化；隔离窗口中的列表原本就保持完整宽度，样式试验也没有改变观察到的分栏结构，不继续叠加无依据的布局约束。

## Consequences

- 优先使用系统动作，没有增加依赖、导航容器或配置字段。保留原路径作为无接收者时的回退，因此该情形可能仍出现原来的跳变。
- 动态 Label 使实际辅助功能名称随系统回写变化；UI 检查覆盖这项状态同步，而不是只检查点击返回成功。
- 当前产品只有一个主窗口；增加多个分栏窗口时，需要重新核对动作目标，不应默认切换另一个窗口的分栏。
- 用户对本笔记安装版的检查确认：窄窗口问题仍在，拉宽后消失。后续列级约束修复有同宽度的修复前/后录像，但本笔记安装的原生动作候选版不能声称消除了跳变。
- 安装版的辅助功能探测没有找到预期的侧栏控件；临时 bundle 的前台激活与辅助功能探测也未能作为可靠验证。它们不作为卡顿根因的证据。
- 原生动作候选版的本地安装不写用户模型配置，不更改关闭保护。该次安装没有创建提交或发布版本，版本元数据为 0.2.1；用户在替换后的窗口验收后确认窄窗口问题仍在。

## Verification

- 从用户录屏逐帧确认边缘半程后跳到完整宽度。隔离比较覆盖原路径、原生系统动作、曲线调整及布局约束；隔离窗口未稳定复现用户画面中的跳变，不能据此确认候选修复有效。
- `swift build`、`swift build -c release` 和 `swift test` 通过；42 项 Core 测试零失败。
- `bash Tests/check-sidebar-ui.sh` 通过三轮，共 36 次切换。每轮实际列状态变化 12 次，工具栏溢出采样为零，全部显示/隐藏名称正确，完整草稿、选择和临时文件不变；包含未修改和未保存草稿。
- `bash Tests/check-model-disclosure.sh` 通过，默认折叠、输入复选框、UA 开关/默认值/编辑及草稿保留有效。
- 原按钮的静态 Label 未满足新增名称检查；动态 Label 满足检查。笔记树、格式、归档和 diff 检查通过。
- 按用户要求，正常退出旧进程后用 release 构建替换 /Applications/PiSwitch.app 并重新打开。没有强制结束进程或代用户选择保存/不保存。暂存、备份及安装后签名检查通过，安装后二进制 SHA256 与暂存包一致，Mach-O UUID 为 FD27A167-DCFA-3498-AFF9-757388C91505，新进程从安装路径启动。整个安装前后 models.json 的内容哈希不变。旧版备份位于 `.build/install-sidebar-native.LElvOJ/PiSwitch.previous.app`。
