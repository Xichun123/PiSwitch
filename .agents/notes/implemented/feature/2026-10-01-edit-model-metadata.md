# Agent Note: 编辑 reasoning、input 和 cost 并移除重复标签

Status: implemented

## Problem

模型区底部的推理、输入类型和价格标签重复上方字段。用户现在明确要求删除这些标签，并把上方只读元数据改为可修改、可保存。

## Decision

删除 ModelSection 的标签区及唯一使用它的 ModelDraft.metadataTags。reasoning 使用原生三态选择（未设置/true/false），input 使用 JSON 数组输入，cost 使用与其他对象相同的多行 JSON 编辑框；三个字段进入现有 FieldText 草稿、目录导入与保存流程，不直接修改 raw 来掩盖未保存的编辑。

未编辑保持原值（包括历史不完整对象和未知嵌套键），清空删除字段；目录导入更新三个草稿，只有 ID 的导入不清除编辑。复用并扩展现有 JSON 编辑校验：reasoning 为布尔值，input 为 text/image 数组（允许空数组）；cost 的四个基本价格和 tiers 中四个价格必须是有限非负数字，tiers 为数组且 inputTokensAbove 为有限非负数字。保留未知价格字段，不深度重写对象。非法修改在备份/落盘前拒绝，未编辑的旧配置不被新校验破坏。

## Historical audit

- [cost 展示与落盘](../../implemented/feature/2026-10-01-model-cost-display.md) 部分取代：只读 UI 政策及缺失字段不显示改为可编辑空框；完整价格、tiers、未知键落盘和显式保存边界继续成立。旧笔记保留历史只读请求与取舍，不改写成相反决定。
- [模型连接覆写](../../implemented/feature/2026-10-01-model-connection-overrides.md) 部分取代 reasoning/input/cost 的只读展示政策；模型连接、路由警告和目录隔离决定不变。
- [thinkingLevelMap 与 compat](../../implemented/feature/2026-10-01-model-thinking-and-compat.md) 仍成立；复用其 FieldText 和 JSON 校验路径，无需改变两个对象的契约。

## Alternatives considered

- 保留只读展示，仅去掉标签：实现最小且无新增输入风险，但不能满足用户最新的可编辑要求，因此不采用。
- 为价格及 tiers 创建逐项数值控件：更直观且能即时限定类型，但需要额外的阶梯增删 UI 和未知字段保留逻辑；JSON 编辑复用现有模式且完整保留对象，使用保存前校验防止错误落盘。

## Consequences

- 收益：reasoning/input/cost 可修改和清空，保存后重载一致；false、空数组、零价格、阶梯价格及未知键不丢失。标签及其未使用的生成代码删除，避免重复和显示未保存旧值。
- 代价：JSON 编辑比逐项价格控件更需要用户理解格式。修改不完整的历史 cost 时需要补全四个基本价格才能保存；未修改的旧对象保持原样。用户输入的价格只是费用估计，不改变 provider 的实际账单。
- 目录再次导入覆盖三个草稿并保存目录值；仅 ID 导入不清除手动修改。非法 JSON、布尔值、输入类型、价格与 tiers 在落盘前拒绝，原文件不被覆盖。

## Related decisions

[输入类型复选框](2026-10-01-model-input-checkboxes.md) 按用户新要求取代 input 的 JSON 输入与清空删除 UI，其他元数据编辑、草稿、导入和保存校验规则继续成立。

[配置字段顺序](2026-10-01-config-field-order.md) 约束配置文件的保存排列，不改变编辑和校验规则。

[模型详情默认折叠](2026-10-01-collapsible-model-details.md) 将表单改为按需展开；本笔记的字段编辑、导入、校验和保存规则不变。

## Verification

- swift build 与 swift test 通过，19 个测试零失败。
- ConfigStoreTests.testEditableModelMetadata 覆盖历史对象不改写、三个字段的编辑保存/重载、false、空数组、零价和空 tiers、阶梯价格及未知嵌套键、非法值不覆盖原文件、仅 ID 导入保留手动修改、目录重新导入覆盖编辑、清空删除及缺失字段重载。
- ConfigStoreTests.testImportedCostSavedAndRetained 改为核对 cost 草稿而非 raw，继续证明目录导入与完整文件落盘；DiscoveryTests.testMerge 的测试价格补全四个必需价格，与新编辑校验一致。
- 独立虚构配置预览确认 reasoning 为 AXPopUpButton，input/cost 为 AXTextField；实际选择 false 并修改输入数组、价格文本成功，缺失字段模型仍有空编辑入口。标签区不再出现。预览中的额外序列化按钮未能通过辅助功能触发；文件落盘与重载由上述临时文件测试验证，不据此声称完成 GUI 保存测试。
- Serena 删除标签属性命中过期引用，实际源码检索确认无调用后使用精确文本删除；不通过重启用户的应用修复索引。
- 未修改真实 models.json，未强制重启用户现有应用。项目根目录的笔记树、格式、归档校验随交付执行。
