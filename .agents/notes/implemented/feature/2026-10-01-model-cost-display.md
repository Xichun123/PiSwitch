# Agent Note: 模型 cost 只读展示与完整落盘

Status: implemented

## Problem

模型编辑界面只用标签展示 cost.input/output，无法核对缓存价格及 tiers。用户要求 cost 只展示、不可编辑，并确保价格数据进入配置文件而不是仅留在界面。

## Decision

在模型区展示 raw.cost 的完整只读 JSON，复用 FieldText 的格式化，不新增可编辑草稿或第二份价格状态。缺失 cost 不补造默认价格。目录导入沿用 CatalogEntry → ModelMerge → ModelDraft.raw → ConfigStore 的现有路径，保存按现有显式保存规则落盘，不自动写入用户配置。

## Historical audit

[thinkingLevelMap 与 compat](../../implemented/feature/2026-10-01-model-thinking-and-compat.md) 部分重叠于模型界面和目录导入，但其可编辑对象决定仍成立；本笔记仅定义 cost 的只读展示与保存验证，不取代旧决定。

## Alternatives considered

- 可编辑 cost JSON：能手动修正中转价格且复用现有文本框，但用户明确只要展示，因此不添加编辑状态与校验。
- 按价格键逐项展示：常见价格更易读，但 tiers 与未知键仍需额外布局；完整 JSON 可直接核对文件，且不复制定价 schema，因此先不采用逐项布局。

## Consequences

- 收益：cost 存在时完整展示且可选择复制，没有编辑入口；缓存价格、tiers 和未知键不遗漏，与保存的数据同源。
- 代价：完整 JSON 比摘要占更多界面空间。仅导入 ID 无价格来源时保持缺失；目录价格不保证等于代理实际账单，只有明确保存后才落盘。
- 不修改现有价格导入或存储契约，不直接写用户真实 models.json，也不自动重启可能有未保存修改的应用。逐项价格布局只有用户需要更易读的展示时再引入。

## Related decisions

[编辑模型元数据](2026-10-01-edit-model-metadata.md) 按用户新要求取代此处只读 UI 政策及缺失字段不展示规则；完整价格落盘和显式保存规则继续成立。本笔记保留此前请求的理由与验证，不把旧决定改写为相反结论。


[模型级 api/baseUrl 覆写](2026-10-01-model-connection-overrides.md) 扩展同一目录导入路径，cost 的只读与完整落盘决定不变。

## Verification

- swift build 与 swift test 通过，17 个测试零失败。
- ConfigStoreTests.testImportedCostSavedAndRetained 在 UUID 临时目录覆盖目录导入新模型和更新已有模型、完整 cost 保存、重载、仅 ID 导入与修改其他字段后的保留；包含缓存价、tiers 和未知嵌套键。
- 独立预览直接使用修改后的 ModelSection 与虚构模型。macOS 辅助功能检查确认 cost 内容为 AXStaticText，而非 AXTextField；完整显示 cacheRead/cacheWrite 和 tiers；缺失 cost 的模型没有虚构价格块。未操作真实配置或重启用户现有进程。
- 交付时在项目根目录运行笔记树、格式、归档校验。
