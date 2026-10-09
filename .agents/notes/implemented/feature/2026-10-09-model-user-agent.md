# Agent Note: 模型级 User-Agent 开关与编辑

Status: implemented

## Problem

模型连接表单没有 User-Agent 入口。用户要求在模型地址下方用开关启用指定默认 UA，并可继续编辑；不能把它写成 provider 全局请求头。

## Decision

在 ModelDraft 和 ModelSection 增加 User-Agent 开关及文本，启用时空值填入 `claude-cli/2.1.295 (external, cli)`，非空草稿保留。关闭只移除模型 headers 中大小写不敏感匹配的 User-Agent；保留其他请求头，删除因移除 UA 变空的 headers 对象。草稿中的自定义文本在关闭期间保留，重新开启不重置；关闭后保存重载不另存禁用文本。

复用 FieldText 跟踪文本编辑。已有模型 UA 以开启状态加载；未编辑的历史 headers 原样保留。编辑后统一写 `User-Agent` 键，拒绝开启状态的空值和 HTTP 控制字符，以及无法安全合并的非对象 headers。只写 models 数组中的模型对象，不写 provider headers 或额外启用标记。关闭不屏蔽 provider/运行时自己的 UA。

## Historical audit

- [模型连接覆写](../../implemented/feature/2026-10-01-model-connection-overrides.md) 部分重叠：同一表单增加模型字段，但 api/baseUrl、路由规则和目录 headers 排除政策不变。
- [模型默认继承连接](../../implemented/feature/2026-10-01-inherit-model-connections.md) 与本功能互补，继承和手动连接规则继续成立。
- [配置字段顺序](../../implemented/feature/2026-10-01-config-field-order.md) 保持成立，headers 继续使用已有额外字段排序；不增加全局排序规则。
- 搜索活跃笔记未发现现有 User-Agent 决定。元数据、cost、thinkingLevelMap/compat 的导入和校验规则保持不变。

## Alternatives considered

- 通用 headers JSON 编辑器可以一次支持任意请求头，但需要用户手写 JSON，也不能提供指定 UA 的一键默认值；本次只编辑 UA 并保留其他键。
- 使用独立落盘启用标记可以保存禁用时的自定义文本，但 Pi 不需要该标记，还会增加旁路配置与同步规则；禁用后只保留当前草稿文本。

## Consequences

- 模型地址下方显示开关，首次开启自动填入指定 UA；既有模型 UA 自动加载，输入框可编辑，折叠不丢失状态。保存复用现有备份、冲突检测及显式保存流程。
- 只改模型 `headers.User-Agent`，不影响 provider、其他模型或其他请求头；目录导入不覆盖手动 UA。关闭后保存重载不保留禁用的自定义文本，再次开启使用默认值。
- 未编辑的旧 headers 保留原值与大小写；编辑时统一 UA 键并拒绝空值及控制字符，非对象 headers 拒绝覆盖。现有异常配置不会因无关编辑被静默重写。
- 开关关闭只删除模型覆写，不能保证请求没有 UA。真实 provider 可能再次覆写请求头；本次不发送网络请求验证服务端结果。按用户要求将当前工作区的 release 构建安装到 `/Applications/PiSwitch.app`，保留旧 App 备份并正常退出后重启，不写真实模型配置。

## Verification

- `swift build` 通过；`swift test` 的 42 项测试全部通过，其中新增 3 项 UA 测试。
- `ConfigStoreTests.testModelUserAgentLifecycle` 使用临时文件覆盖默认值、启用/编辑/关闭/重载、草稿重启用保留文本、保存后重新启用默认值、provider/其他模型隔离、其他 headers 与未知字段保留，以及目录导入不引入或覆盖 UA。
- `testModelUserAgentHeaderCaseAndRemoval` 覆盖三种键大小写、未编辑原样保留、编辑规范化、移除所有同名 UA 及清理空 headers；`testModelUserAgentValidationPreservesFile` 覆盖空值、CR/LF/Tab/NUL/DEL 拒绝保存，异常 headers 保留和禁止破坏性覆盖，失败不改原文件。
- `bash Tests/check-model-disclosure.sh` 通过。使用两个虚构模型的实际 ModelSection 检查开关默认关闭、默认 UA、通过辅助功能修改文本、折叠保留状态和编辑、关闭隐藏输入框、再次开启保留当前草稿；沿用名称与输入类型检查。UA 文本通过 AXValue 设置并失焦提交，避免合成按键偶尔未输入的问题。
- `swift build -c release` 通过；本地 App 沿用已安装的 0.2.0 元数据与资源，替换可执行文件后重新 ad-hoc 签名。安装前后签名验证通过，安装后二进制 SHA256 与暂存 App 一致，已确认进程从 `/Applications/PiSwitch.app/Contents/MacOS/PiSwitch` 启动；旧版位于 `.build/install-user-agent.I8A96l/PiSwitch.previous.app`。
- 提交前从项目根目录执行笔记树、格式、归档校验和 `git diff --check`。版本发布沿用标签触发的 DMG 工作流，签名政策保持 ad-hoc，不做 Apple 公证。
