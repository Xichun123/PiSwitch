# Agent Note: 导入与编辑模型级 api 和 baseUrl 覆写

Status: implemented

## Problem

pi.dev/api/models 的模型对象含 api 和 baseUrl，但 CatalogEntry.fields 过滤这两个键。用户要求所列模型字段完整导入，并保留 api/baseUrl 以便单模型协议覆写。已有配置可以保留 raw 中的字段，但界面没有模型级连接入口。

## Decision

在 CatalogEntry 与 ModelDraft 增加可选 api/baseUrl，模型界面提供协议和地址覆写入口；留空删除键并继承 provider 默认值。目录导入新模型和更新已有模型时复制目录实际提供的两个模型级值，目录缺失及仅 ID 导入不清除现有覆写。校验目录值为非空字符串，baseUrl 为带主机的 HTTP/HTTPS URL；编辑后的地址复用现有 ProviderDraft.isValidBaseURL 校验。未知协议名称保留，以兼容扩展。

reasoning/input 提供显式只读展示；id、name、contextWindow、maxTokens、thinkingLevelMap、compat 和 cost 沿用现有导入/保存路径。cost 仍完整只读，不引入价格编辑。模型字段不写到 provider，不复制目录 provider/type 或 headers，不改现有 API Key、provider 默认连接、保存时机。

## Runtime precedence and safety

Pi 当前 modelFromJson 使用 definition.api/baseUrl → providerConfig.api/baseUrl → catalog defaults 的优先级。因此保存目录官方地址会直接覆盖当前代理路由，不是停用的元数据。模型界面明确提示实际优先级、目录导入覆盖与 HTTP 明文风险；用户已明确要求保留模型连接字段，实施前在会话中告知该路由影响。真实配置不用于测试或自动写入。

## Historical audit

- [thinkingLevelMap 与 compat](../../implemented/feature/2026-10-01-model-thinking-and-compat.md) 部分重叠：两个对象的可编辑与保留规则继续成立，provider 连接与 headers 仍隔离；旧测试对目录模型 api/baseUrl 的排除约束由本决定部分取代。旧笔记核心决定不改成反面。
- [cost 只读展示](../../implemented/feature/2026-10-01-model-cost-display.md) 部分重叠于导入路径和只读展示；cost 决定不变，互链保留。

## Alternatives considered

- 继续排除目录连接、仅手动添加模型覆写：最能避免官方地址绕过代理，但会再次丢失用户明确要求保留的两个模型字段，因此采用复制并显示路由提醒。
- 把目录地址存在不生效的旁路元数据：能保留信息而不改变当前路由，但不是 Pi 的 api/baseUrl 配置语义，还需额外的启用状态与格式；用户要求的模型级覆写直接使用 Pi 原生字段。

## Consequences

- 收益：新模型和已有模型目录导入、保存、重载后含全部用户列出的模型字段，包括 null、false、缓存价格和 tiers；模型 api/baseUrl 可编辑、清空恢复继承；provider 默认连接与 key 不变。
- 代价：目录导入会覆盖已有模型连接，可能把现有 provider 的 Key 发送到不同官方端点，且官方 compat 不一定适合中转协议。UI 和会话均提醒用户核实、必要时清空/调整模型覆写再保存；不假设协议名或目录信息保证实际接口兼容。
- 目录缺失与仅 ID 导入保留历史覆写；无效目录连接拒绝导入、无效编辑不覆盖文件。不支持一套旁路连接元数据，因其不符合 Pi 原生优先级；若未来要求导入不生效，需另行明确启用/保留契约。

## Related decisions

[模型默认继承连接](2026-10-01-inherit-model-connections.md) 按用户新要求取代目录 api/baseUrl 自动复制政策，并增加协议对应的 v1 路径处理；原生覆写字段、优先级和手动编辑规则仍成立。


[配置字段顺序](2026-10-01-config-field-order.md) 将模型 api/baseUrl 放在 name 后，不改变其优先级和路由行为。


[编辑模型元数据](2026-10-01-edit-model-metadata.md) 按用户新要求取代 reasoning/input/cost 的只读展示政策；连接覆写与风险提示决定保持成立。

## Verification

- swift build 和 swift test 通过，18 个测试零失败。
- ConfigStoreTests.testFullModelMetadataAndConnectionOverrides 使用用户示例的模型元数据（不含真实 Key），覆盖目录解析、新模型与已有模型导入、文件保存与重载、完整对象比较、未知扩展协议、无效 URL 不覆盖文件、清空恢复继承，以及 provider 默认连接/测试 Key 隔离。
- DiscoveryTests.testMerge 覆盖模型连接复制、别名 ID、目录缺失与仅 ID 导入保留、无效 api/baseUrl 拒绝，继续排除 headers。既有成本与未知字段保留测试继续通过。
- 独立预览复用修改后的 ModelSection 和实际 API 预设，辅助功能检查确认 api/baseUrl 为可编辑字段、reasoning 的 true/false 与 input 显式展示、完整 cost 为只读文本、thinkingLevelMap 的 null 和 compat 的 false 保留。修改预览地址为 http:// 后出现明文传输警告；缺失连接的虚构模型显示空字段并有继承提示。
- 未修改真实 models.json，未重启用户可能有未保存修改的现有 PiSwitch 进程。项目根目录的笔记树、格式、归档校验随交付执行。
