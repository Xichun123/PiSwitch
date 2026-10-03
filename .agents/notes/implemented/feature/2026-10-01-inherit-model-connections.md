# Agent Note: 模型默认继承连接并按协议处理 v1

Status: implemented

## Problem

目录导入把官方 api/baseUrl 写成活动模型覆写，导致模型绕过代理。用户现在要求这两项默认留空；provider 的 OpenAI 协议使用带 /v1 的代理地址，单模型切到 Anthropic 时需要同一代理的不带 /v1 版本。

## Decision

新模型目录导入不填 api/baseUrl，已有模型再次导入不覆盖显式连接；目录条目仍可保留这两项来源信息，但不写入活动覆写。已有配置的覆写继续显示并保留，提供“恢复继承”入口同时清空两个字段，避免无法判断来源时误删手动连接。

复用 ProviderDraft 增加协议地址归一化：openai-completions/openai-responses 保留或补齐末尾 /v1，anthropic-messages 仅移除末尾 /v1；用 URLComponents 操作 percentEncodedPath，保留主机、其他路径、编码、端口、query/fragment。不认识的协议和无效/空地址不猜测，错误输入由现有保存校验处理。

模型显式地址以其有效协议（模型 api 或 provider api）归一化。仅设置模型 api 且没有地址时，若按该协议处理 provider 地址得到不同 URL，就生成模型地址覆写；地址相同则继续继承。协议切换立即更新草稿地址，清空协议或恢复继承同时清空地址。已有自定义主机不被替换成目录或 provider 主机，只处理末尾版本路径。provider 协议变更/地址提交、保存、模型发现共用同一归一化函数；保存前同步草稿，Core 单独保存也遵守规则。发现请求对两种协议最终都使用 /v1/models。

## Historical audit

- [模型连接覆写](../../implemented/feature/2026-10-01-model-connection-overrides.md) 部分取代：目录复制活动连接政策被新继承政策取代；原生字段、编辑、清空、验证、路由优先级继续成立。旧笔记保留之前明确要求复制的理由，不改写成反面。
- [配置字段顺序](../../implemented/feature/2026-10-01-config-field-order.md) 仍成立，显式覆写继续在 name 后，继承时不写空字符串。
- 当前元数据编辑、cost、thinkingLevelMap/compat 笔记与此无冲突，不改变价格和可选对象的导入政策；目录 compat 仍需核实实际代理是否支持。

## Alternatives considered

- 永远让用户手动删除/追加 /v1：无 URL 自动化风险且适合异形端点，但不满足用户要求的协议切换联动；只对三种已知协议的末尾版本段进行有限处理。
- 加载时清空所有已有覆写：立即让旧目录模型恢复代理，但无法区分此前的目录覆写与用户手动配置，会丢失自定义主机；保留既有值并提供明确恢复继承操作。

## Consequences

- 收益：新导入两项为空、文件中省略，既有手动连接不被元数据覆盖；OpenAI 两种格式的 provider 保存带 /v1，跨协议模型可自动得到同代理的地址。恢复继承同时删除两个模型键，避免遗留地址继续覆写代理。
- 代价：规则只适用于用户描述的常规代理路径，不自动猜测自定义完整请求端点。生成的模型地址是实际覆写，保存后独立于 provider；以后修改 provider 主机时需调整或恢复这些显式地址。
- provider 地址本身缺失时无法从运行时内置目录推导，跨协议模型需手动给地址。已有目录导入产生的历史连接不被静默清空，需使用恢复继承；保存之前均只是草稿修改。
- 地址的 host、端口、前缀路径、编码、query/fragment 保留。未知协议和空/非法地址不猜测；后者继续接受现有保存边界的验证。

## Verification

- swift build 与 swift test 通过，21 个测试零失败。
- ConfigStoreTests.testProtocolConnections 覆盖两种 OpenAI 和 Anthropic 的正反归一化、幂等性、前缀/端口/编码/query/fragment、v1beta 不误删、未知协议与空地址不改写、provider 保存、模型默认省略键、只改协议的地址生成、同类 OpenAI 不生成冗余地址、重载后反向切换、恢复继承、自定义主机保留、非法编辑不覆盖文件。
- DiscoveryTests.testModelsURL 覆盖 OpenAI 根地址与 Anthropic 路由统一到 /v1/models，并保留编码/query/fragment。原 HTTP stub 分页、请求头和错误测试继续通过。
- DiscoveryTests.testMerge 验证新导入连接空且保存省略，已有自定义连接不被目录覆盖；ConfigStoreTests.testFullModelMetadataAndConnectionOverrides 改为核对除目录连接以外的完整元数据及后续手动覆写。
- 独立虚构配置预览使用实际 ModelSection 和 API 预设：初始模型 API/地址为空，输入 anthropic-messages 后地址变为 https://proxy.example；通过菜单的恢复继承操作后两个字段重新为空。第二个自定义模型保持 https://custom.example/v1，不随第一模型变更而修改。预览不访问网络或真实配置。
- 保存、UI、发现的实际调用已核对共用归一化函数；既有精确字段顺序、价格编辑、备份与冲突测试继续通过。未修改真实 models.json 或强制重启用户现有应用。项目根目录笔记树、格式、归档校验随交付执行。
