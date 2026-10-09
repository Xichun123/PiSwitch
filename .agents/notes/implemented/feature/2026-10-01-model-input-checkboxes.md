# Agent Note: 输入类型使用文本与图像复选框

Status: implemented

## Problem

输入类型只有 text/image 两个选项，JSON 输入框占空间且需要手写数组。用户要求直接勾选文本、图像，并自行检查本次改动。

## Decision

ModelSection 用两个原生 checkbox Toggle 代替 input JSON 文本框，可以同时选中。Binding 直接读写现有 ModelDraft.input 草稿，复用 JSONValue 和 FieldText，不增加第二份状态或修改配置格式。未操作保留原值；取消最后一个选项写入空数组，缺失 input 不自动补造。修改某一项保留数组中其他值和顺序，历史未知值仍由原有保存校验处理。

## Historical audit

- [编辑模型元数据](../../implemented/feature/2026-10-01-edit-model-metadata.md) 部分取代：只有 input 的 JSON 输入和清空删除 UI 被复选框替代；FieldText、目录导入、显式保存、未编辑保留与校验继续成立。
- [模型详情折叠](../../implemented/feature/2026-10-01-collapsible-model-details.md) 部分重叠，折叠政策不变，现有界面检查的文本字段数量随控件替换调整。
- 模型连接覆写的只读 input 展示已经被编辑元数据笔记取代；字段顺序仅约束输出排列；其余成本、连接继承及 thinkingLevelMap/compat 笔记不规定 input 控件，不受影响。

## Alternatives considered

- 保留 JSON 输入：可以直接清空删除键或编辑原始数组，但用户明确要求不展示 JSON，且只有两个常用选项，不采用。
- 单选下拉框：更省空间，但无法同时表达文本和图像；增加组合项会把两个独立能力变成不直观的枚举，不采用。

## Consequences

- 收益：输入类型只显示“文本”“图像”两个独立复选框，可以同时选中，不需要手写 JSON；直接更新已有草稿，不增加同步状态。
- 代价：两个都取消表示显式空数组，不再提供直接删除 input 键的 UI。历史未知输入值不展示为额外选项，用户修改后可能触发原有保存校验。

## Verification

- 按用户要求，本次不执行构建、Core 测试或 GUI 自动化；不声称本次编译或界面验证通过。
- 更新 `Tests/check-model-disclosure.sh`：展开后文本字段预期从 10 改为 9，增加两个复选框初始选中、取消文本不影响图像、收起再展开仍保留选择的断言；用户可自行运行。
- 不读写用户实际配置，不重启应用。

## Integration verification

[Skills 管理](2026-10-08-skill-management.md) 接入时重新运行当前模型界面检查。文本和图像 Toggle 增加稳定辅助功能标识，不改变绑定或配置语义。脚本按 AXIdentifier 找控件，点击后立即结束枚举，避免 SwiftUI 重建控件树后重复点击。预览链接 Yams/CYaml 对象以适配新增 Core 依赖。

`bash Tests/check-model-disclosure.sh` 当前通过：默认折叠、两个输入选项独立、收起再展开保留状态。`swift test` 当前 38 项通过。首次控件替换未验证的记录保留为历史事实，本节记录后续集成验证。
