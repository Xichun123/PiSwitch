# Agent Note: 导入与编辑模型 thinkingLevelMap 和 compat

Status: implemented

## Problem

目录导入只复制基础模型元数据，遗漏 thinkingLevelMap 和 compat；编辑界面也没有这两个对象字段的入口。已有配置虽保留原字段，却无法在界面修改，导入新模型则丢失目录中的推理与兼容配置。

## Decision

按用户确认，CatalogEntry、ModelDraft 和模型编辑界面都支持这两个可选对象。新模型和已有模型导入都复制目录中实际存在的字段，已有模型对应字段按目录值整体替换；目录缺失字段及仅导入 ID 不清除现有值。使用现有 JSONValue 和 FieldText 提供 JSON 编辑，清空删除，未编辑保留原值；校验 JSON 对象及 thinkingLevelMap 的已知层级与 string/null 值，不模拟 Pi 的完整 API-specific compat schema。

不复制 provider-level baseUrl、api 或 headers，也不猜测或补造兼容默认值。

## Historical audit

项目没有既有决定笔记。DiscoveryTests.testMerge 的旧断言禁止目录覆盖 compat，本决定按用户“compat 一起导入”的要求替换该约束，其他连接字段隔离仍保留。

## Alternatives considered

- compat 仅保留并手动编辑：最能避免将官方端点参数套用到代理，但用户明确要求随目录导入，因此不采用；导入后的实际接口兼容性仍需用户核实。
- 为兼容选项逐项创建开关和完整 Pi schema：输入提示与类型约束更强，但 compat 随 API 和 Pi 版本扩展；JSON 对象编辑可保留嵌套与未知键，不引入易过时的并行 schema。

## Consequences

- 收益：新建/更新导入不再遗漏两个对象；可以在模型编辑界面手动修改、清空，未编辑的历史字段保持原值。
- 代价：目录 compat 可能不适合中转端点，并会整体替换已有模型的同名对象。UI 帮助提示要求用户核实；不是对象级深合并。
- compat 只校验对象结构，不校验每个 API 的参数类型或实际行为；Pi 仍负责其完整 schema。thinkingLevelMap 校验当前已知层级及 string/null 值。目录中的非法可选对象使对应条目无效，不导入假值。

## Related decisions

[模型级 api/baseUrl 覆写](2026-10-01-model-connection-overrides.md) 部分取代旧测试对目录模型连接字段的排除约束；本笔记的两个对象决定以及 provider-level 连接和 headers 隔离规则保持成立。


[cost 只读展示与完整落盘](2026-10-01-model-cost-display.md) 复用相同模型界面和目录导入路径，但不改变这两个对象的可编辑行为。

## Verification

- swift build 和 swift test：16 个测试通过。DiscoveryTests.testMerge 覆盖新模型、已有模型替换、目录缺失、仅 ID 导入、别名 ID 与非法目录字段。
- ConfigStoreTests.testModelJSONFields 覆盖加载、编辑保存、null、未知嵌套键、清空和非法输入不覆盖原文件；定向重跑通过。
- 独立 SwiftUI 预览使用虚构模型，辅助功能检查确认两个 JSON 文本字段可加载和编辑。不保存用户真实配置。
- 项目根目录的笔记树、格式、归档校验随本次交付执行。
