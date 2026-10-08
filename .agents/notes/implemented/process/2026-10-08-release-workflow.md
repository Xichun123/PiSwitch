# Agent Note: GitHub Actions 自动发布 CI

Status: implemented

## Problem

本地手工打包并创建 Release 容易遗漏附件或校验文件，需要将版本标签与打包发布绑定。手动发布若只使用输入标签命名产物、却检出工作流所在分支，会把其他提交构建的 DMG 上传到该标签的 Release；将输入直接拼进 shell 还会执行输入中的命令替换。

## Decision

.github/workflows/release.yml 在推送 v* 标签或手动 workflow_dispatch 时执行。自动发布只接受 v 前缀加三段数字版本号；手动输入可省略 v，但统一解析为已经存在的 v<版本> 标签，不创建缺失标签。

prepare 任务只有 contents: read 权限。它先检出工作流源码，运行 Tests/check-release-workflow.rb，再通过 GitHub 的 commits/refs/tags/<标签> API 获取目标提交 SHA。该接口返回提交，而不是 annotated tag 对象。推送事件还要求解析结果与触发事件的 SHA 一致，避免排队期间标签移动后构建其他提交。版本、标签和 SHA 通过任务 outputs 传递。

release 任务具有 contents: write 权限，以规范化后的标签为 concurrency group 串行执行，不中断正在发布的任务。它执行：

1. 按解析出的提交 SHA 检出，不持久化 checkout 凭据，并核对 HEAD；
2. 选择 Xcode，运行 swift test；
3. 调用目标提交中的 scripts/package-release.sh，生成带图标、版本号及 ad-hoc 签名的 DMG 并执行结构校验；
4. 计算 SHA256SUMS.txt，通过 outputs 返回附件路径；
5. 发布前再次核对 HEAD、远程标签指向和附件校验和，再查询 Release 列表。查询失败直接终止，不能当作 Release 不存在；
6. 对已有 Release 上传并替换同名附件；创建新 Release 时同时使用 --verify-tag 和 --target <已解析SHA>，禁止 gh 隐式从默认分支创建标签。

所有动态值通过步骤或任务 env 进入 shell，run 脚本不直接插入 GitHub 表达式。版本校验在首次目标 API 查询前完成；命令替换、引号、换行和路径输入按普通文本拒绝。准备阶段的回归检查从工作流源码运行，不要求旧目标标签包含新增测试文件。

本地 package-release.sh 与 Tests/check-release-dmg.sh 保持独立入口。签名政策保持 ad-hoc，不引入 Apple 公证凭据。

## Historical audit

[DMG 发行包](2026-10-04-dmg-releases.md) 原规定远程上传为显式操作、不加入自动发布 CI；本篇接管自动发布约束，保持仅发布 DMG 和不公证的政策。本篇原有自动发布决定仍成立，标签解析、凭据边界和回归检查在此同步，不另建重复笔记。

## Alternatives considered

- 每次向 main 分支 push 均发布：能立即交付最新修复，但频繁生成未定型版本，不能表达维护者选定的版本边界，因此保留标签或手动触发。
- 使用第三方 GitHub Release Action：可以减少上传代码，但 runner 已提供 gh CLI，新增外部发布依赖没有必要，因此直接调用 gh。
- 直接按输入标签检出：代码更少，通常能构建正确源码，但标签可以在解析、排队和检出之间移动；先解析提交 SHA 再检出可固定构建对象，并允许发布前检测移动。
- 保留 main 构建并只增加 --verify-tag：可以阻止 gh 自动创建缺失标签，但无法修复已有旧标签与附件源码不一致的问题，因此不采用。
- 将发布 shell 抽成独立脚本：便于直接调用和测试，但手动发布旧标签时该脚本可能不存在；保留工作流中的编排，用测试读取并执行真实 run 段，避免复制生产逻辑。

## Consequences

- 推送版本标签即可发布；手动输入带 v 或不带 v 的版本都构建同一个已有标签，不受工作流运行分支影响。
- 非法输入、缺失标签、API 失败、标签移动、源码不匹配或附件校验失败均阻止发布，不回退到 main。
- 同一规范化标签的发布任务串行执行，避免本工作流的并发上传交错。重新运行仍会替换同名附件；GitHub 的多附件上传不是事务，上传中途失败时需要重跑完成修复。
- 分离准备和构建增加一个只读任务；回归检查依赖 runner 自带的 Ruby 标准库，不新增项目依赖。
- 旧目标标签必须包含可运行的打包脚本并能通过 runner 测试，否则发布失败。修复后的工作流不能改变旧提交保存的工作流；重发旧版本需从包含修复的 main 手动运行。
- 发布前检查与远程上传不是原子操作。需用 GitHub 标签规则禁止版本标签更新和删除，才能约束外部管理员或其他发布流程在最后一次检查后移动标签；本次不修改仓库远程规则。
- DMG 保持 ad-hoc 签名且未公证，不解决首次打开时的 Gatekeeper 提示。

## Verification

- ruby Tests/check-release-workflow.rb 的 38 项检查通过。测试直接读取 workflow YAML，执行真实 shell 段，通过本地 git/gh 模拟覆盖版本规范化、旧标签解析、注入输入、非法 SHA、标签移动、检出核对、打包失败、创建和重发 Release、API 与上传错误，以及缺失或损坏的附件校验文件。
- 测试同时检查 SHA checkout、任务 outputs/env 连接、最小权限、规范化标签并发组、步骤执行顺序，以及所有 run 段不含表达式插值。该检查接入 prepare 任务。
- actionlint 1.7.12 与 ShellCheck 0.11.0 检查通过；测试对各 run 段执行的 bash -n 与 Ruby 语法检查通过。swift test 的 21 个核心测试全部通过；笔记树、格式、归档和 git diff --check 校验通过。
- 新工作流尚未推送或触发真实发布，远程创建和上传由本地模拟验证；不为验证覆盖现有 Release 附件。
