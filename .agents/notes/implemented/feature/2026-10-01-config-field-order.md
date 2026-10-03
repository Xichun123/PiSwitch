# Agent Note: 配置按指定字段顺序保存

Status: implemented

## Problem

JSONValue.prettyData 使用 JSONEncoder.sortedKeys，配置按字母顺序显示，无法满足用户给定的分层字段顺序。用户确认模型级 api/baseUrl 紧跟 name。

## Decision

只为 ConfigDocument.encoded 的配置文件输出增加有序格式化，现有 FieldText 的通用 JSON 格式化不变。使用一个递归格式化函数组织对象和数组，键名及标量继续由 JSONEncoder 转义/编码；不依赖 Dictionary 迭代顺序、不手写字符串或数字转义、不新增依赖。

已知键按上下文固定顺序排列，缺失键不补造，额外键放在同层末尾按字母稳定排序。Provider 名称仍按字母排序，models/input/tiers 等数组保持原有顺序。只有实际 schema 路径应用排序，未知对象或 headers 中的同名键不被误判为模型/价格对象。使用两空格缩进、冒号后一个空格、文件结尾一个换行。

## Field order

- 顶层：providers，其余键随后。
- Provider：api、apiKey、baseUrl、models，其余键随后。
- Model：id、name、api、baseUrl、reasoning、input、thinkingLevelMap、contextWindow、maxTokens、cost、compat，其余键随后。
- thinkingLevelMap：off、minimal、low、medium、high、xhigh、max。
- cost：input、output、cacheRead、cacheWrite、tiers。
- tier：inputTokensAbove、input、output、cacheRead、cacheWrite。
- compat 及未指定对象：字母排序，保留完整值。

## Historical audit

既有模型元数据、成本、连接覆写和编辑笔记均部分重叠于 ConfigDocument 的保存边界，但不规定配置对象顺序。新决定仅约束输出顺序，不取代字段编辑、保留、路由或校验决定。与当前 [编辑模型元数据](../../implemented/feature/2026-10-01-edit-model-metadata.md) 和 [模型连接覆写](../../implemented/feature/2026-10-01-model-connection-overrides.md) 互链保留。

## Alternatives considered

- 仅移除 sortedKeys 或按顺序向 Dictionary/Codable 容器插入：改动最少且继续使用完整原生编码，但 JSONEncoder 不承诺任意对象键的输出顺序，无法保证用户要求，因此不采用。
- 用全局字段优先级排序所有对象：实现更短，但 providers 名称、headers 或未知对象可能恰好与 schema 字段同名，导致越界排序；使用实际层级上下文避免这种混淆。

## Consequences

- 收益：配置已知字段及模型覆写位置固定，推理层级、成本和 tiers 按用户示例排列；缺失字段不补造，额外字段完整保留，数组不重排。重载后再次保存字节稳定。
- 代价：需要维护一个配置专用递归格式化函数及上下文顺序表。新增字段若需要特定顺序，必须显式加入对应列表，否则稳定地排在末尾。通用编辑框仍使用现有字母排序格式，不将配置 schema 套用到独立 JSON 对象。
- 只调整文本格式与键顺序，不改变 JSON/Pi 字段语义、配置校验、备份、冲突检测及显式保存时机。

## Related decisions

[模型默认继承连接](2026-10-01-inherit-model-connections.md) 默认省略模型连接键；显式覆写仍按本笔记放在 name 后。

## Verification

- swift build 与 swift test 通过，20 个测试零失败。
- ConfigStoreTests.testConfigurationFieldOrder 从旧字母排序数据开始，使用临时文件逐字节比较整个期望配置，覆盖 provider、model、api/baseUrl 的位置、thinkingLevelMap、cost、tier、未知字段置末、模型数组原顺序、缺失覆写和空对象/数组。
- 同一测试覆盖转义键名、换行/反斜杠/Unicode 字符串、false/null、超过 2^53 的整数、未知对象中同名 cost 的非 schema 排序、解码后的值一致、重载再次保存稳定、非有限数字导致编码失败但不覆盖文件。
- 既有字段编辑、完整导入、备份、冲突和符号链接测试继续通过。此改动不改变 GUI 控件，文件格式的验收使用实际保存字节而非界面截图。
- 未修改用户真实 models.json；重启 rebuilt 应用后显式保存才应用新格式。交付时在项目根目录运行笔记树、格式、归档校验。
