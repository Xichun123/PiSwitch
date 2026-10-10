# Agent Note: 本机安装并重启 PiSwitch

Status: implemented

## Problem

每次本机修复后都要手工构建、替换安装和重启。用户要求把这一流程收成一个脚本，并明确不要哈希检查或验证套件；发布用的 DMG 打包流程包含这些步骤，不适合作为日常本机更新入口。

## Decision

本机更新使用 `scripts/install-local.sh`，从脚本所在项目执行 Release 构建，复用已安装的 `/Applications/PiSwitch.app` 包元数据，将新可执行文件和项目图标放入暂存包并重新 ad-hoc 签名。暂存成功后请求应用正常退出，等待退出完成，再把旧安装移到 `.build/install-local.<随机值>/PiSwitch.previous.app`、安装新包并使用 `open` 重新打开。

安装不生成 DMG，不运行测试、笔记校验或哈希检查，不自动提权，不触碰 Pi 配置或指令库。已有安装必须是普通目录且目标目录可写。退出被取消、超时或进程仍存在时停止，不强杀或绕过草稿保护；新包移动失败时恢复旧安装并报告备份位置。运行时只保留防止覆盖运行中应用和丢失旧安装的必要检查。

## Alternatives considered

- **调用 `package-release.sh` 后挂载 DMG 安装**：可以完全复用发行包生成和版本元数据；但会额外制作镜像、运行验包和输出哈希，违背用户要求的本机快捷流程，因此发布脚本保持原样。
- **抽取共享的 App 打包器再接入安装与发布**：可以统一元数据生成，也支持全新安装；但这次只需要更新现有安装，抽取会改变已有发行流程和测试契约。先复用已安装的包，不添加版本参数或安装目标选项。

## Consequences

一条命令完成本机更新，正式发布的 DMG 和 CI 验证流程不变。新包暂存在 `/Applications` 下，以同一文件系统的移动完成安装；只有构建和签名成功、进程已退出才替换旧安装。暂存可执行文件和已退出进程的运行时检查保留，防止安装不可执行包或绕过草稿保护；不额外运行验证套件。

复用现有包意味着不改变显示版本号或最低系统版本，不支持首次安装。需要改变包元数据或支持首次安装时再抽取共享打包逻辑。签名仍为 ad-hoc，不增加公证。备份不会自动清理；文件移动失败后的恢复不承诺断电或并发安装下的完整事务，不支持同时运行多个安装脚本。

## Verification

从 `/tmp` 执行项目脚本，Release 增量构建、准备新包、ad-hoc 签名、正常退出、替换安装和 `open` 均完成。这次 AGENTS 列表修复已安装，旧 0.3.0 包位于 `.build/install-local.Fd1q0a/PiSwitch.previous.app`。安装没有运行哈希、测试、GUI 或笔记验证，也没有发布或提交。`open` 返回成功不替代应用行为验收；异常退出、移动失败和恢复失败未注入验证。

## Historical audit

已检索活跃笔记。与 [DMG 发行包](../../implemented/process/2026-10-04-dmg-releases.md) 部分重叠于构建和签名，但本机更新不属于发布下载包，既有 DMG 格式与验包流程保持不变。与 [AGENTS 管理](../../implemented/feature/2026-10-09-agents-management.md) 部分重叠于此次列表修复的本机安装，指令存储规则不变。[发布工作流](../../implemented/process/2026-10-08-release-workflow.md) 和 [Git 初始化](../../implemented/process/2026-10-04-git-initialization.md) 保留其发布、提交及配置隔离边界；不取代或归档。
