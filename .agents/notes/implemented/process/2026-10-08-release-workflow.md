# Agent Note: GitHub Actions 自动发布 CI

Status: implemented

## Problem

此前发布流程为本地手工运行 scripts/package-release.sh 打包并通过 gh 手动创建 Release，容易遗漏上传附件或校验文件，且没有将版本标签与打包发布流程绑定。

## Decision

增加 .github/workflows/release.yml，在推送 v* 标签或手动 workflow_dispatch 触发时，在 GitHub-hosted macOS runner 上执行：
1. 运行 swift test 验证核心测试；
2. 运行 scripts/package-release.sh 生成带应用图标、版本号及 ad-hoc 签名的 DMG 安装包并执行结构校验；
3. 计算 DMG 的 SHA256 校验和并输出 SHA256SUMS.txt；
4. 使用系统内置的 gh CLI 创建 GitHub Release 并上传 DMG 与校验文件。

本地 package-release.sh 与 Tests/check-release-dmg.sh 继续作为独立本地打包与校验入口保留。签名政策保持 ad-hoc，不引入 Apple 公证凭据。

## Historical audit

[DMG 发行包](2026-10-04-dmg-releases.md) 原规定远程上传为显式操作、不加入自动发布 CI；本篇更新该约束，由 GitHub Actions 负责发布上传，保持仅发布 DMG 和不公证的原有政策。

## Alternatives considered

- 每次向 main 分支 push 均打包发布：构建与镜像开销大，频繁生成未定型的发布包，违背语义化版本管理。
- 使用第三方 GitHub Release Action：引入额外未锁定的外部 Action 依赖；macOS runner 自带 gh CLI，直接调用最精简且无外部供应链风险。

## Consequences

- 开发者推送版本标签（例如 git tag v0.1.1 && git push origin v0.1.1）即可自动触发打包、校验与 Release 发布。
- 需要 GitHub 仓库默认的 GITHUB_TOKEN 具有 contents: write 权限。
- CI 仅在推送标签或手动触发时执行，常规分支提交不会产生冗余构建。
- DMG 依然是 ad-hoc 签名且未公证，不解决首次打开时的 Gatekeeper 提示。

## Verification

- 验证 workflow YAML 语法合法。
- 确认本地打包脚本在 CI 步骤中以相同逻辑调用，包含 DMG 完整性与图标检查。
- 笔记树与格式校验脚本运行通过。
