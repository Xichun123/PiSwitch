# Agent Note: 模型详细配置默认折叠

Status: implemented

## Problem

每个模型的完整表单一直显示，模型较多时挤占界面，难以定位和操作其他模型。

## Decision

ModelSection 的详细字段默认折叠，标题保留模型 ID（空 ID 显示“新模型”）和独立删除按钮。点击标题的箭头或文字展开/收起该模型，使用本地 SwiftUI State；不写入配置，不影响草稿、导入、保存或删除确认。手动添加和发现导入的模型也默认折叠。

## Historical audit

现有六篇活跃笔记均已检索，没有折叠规则。[编辑模型元数据](../../implemented/feature/2026-10-01-edit-model-metadata.md)、[模型继承连接](../../implemented/feature/2026-10-01-inherit-model-connections.md)、[thinkingLevelMap 与 compat](../../implemented/feature/2026-10-01-model-thinking-and-compat.md) 与本改动部分重叠于 ModelSection；字段编辑、连接处理和保留规则继续成立。价格历史展示、模型连接历史覆写与字段输出顺序不规定展开状态，不被取代。

## Alternatives considered

- 折叠整个模型区：只需一个开关，能最快腾出空间；但展开后仍显示所有模型的长表单，无法只查看要操作的一项，因此按模型折叠。
- 将表单包进原生 DisclosureGroup：自带展开交互和辅助功能；但会把原有 grouped Form 的独立字段行嵌入一个控件内容区。采用原生 Button 和条件 Section 内容，保留既有行布局和独立删除操作。

## Consequences

- 收益：多个模型以紧凑标题显示，只展开需要编辑的模型；添加、发现模型和独立删除按钮继续可用，删除仍经原有确认流程。
- 代价：编辑前增加一次点击，手动新建后需展开“新模型”。展开状态不持久化，切换 provider 或重新加载可重置；表单草稿不受收起影响。
- 使用原生按钮保留键盘交互，显式提供模型 ID 的辅助功能标签、展开状态和操作提示；不新增依赖、配置字段或跨模型展开状态管理。

## Related decisions

[输入类型复选框](2026-10-01-model-input-checkboxes.md) 保持默认折叠政策，替换一个文本字段并更新现有界面检查；下面的通过记录对应替换前的版本，本次控件改动由用户自行检查。

## Verification

- swift build 和 swift test 通过，21 项 Core 测试零失败。
- `bash Tests/check-model-disclosure.sh` 编译实际 ModelSection 的独立预览，用两个虚构模型通过 System Events 检查：初始没有编辑字段、两个折叠标题；展开一个后出现 10 个文本字段、另一个仍折叠；输入名称，收起再展开仍保留修改。
- 检查脚本需要 macOS 辅助功能权限，只操作自身进程，退出清理预览；不访问网络或用户真实配置。Core 测试不作为 UI 折叠的证据。
- 未强制重启用户现有应用，重新打开构建后的应用才能在现有窗口看到新行为。
