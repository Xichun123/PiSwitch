# Agent Note: DMG 发行包

Status: implemented

## Problem

首版以 ZIP 发布，用户要求补一个可拖拽安装的 DMG，并让后续版本只使用 DMG 格式。一次性手工打包无法保证后续版本遵守相同的安装和签名规则。

## Decision

scripts/package-release.sh 接收三段数字版本号（可带 v 前缀），原生 Release 构建后生成 PiSwitch.app，使用 ad-hoc 签名，再用 macOS 27 的 diskutil image create from 创建压缩只读 DMG。镜像包含应用和指向 /Applications 的快捷链接，不打包用户配置。应用图标的资源与声明遵循 [PiSwitch 应用图标](../feature/2026-10-08-app-icon.md)，在签名前复制到应用包。最低系统版本从二进制的部署目标读取，文件名标明构建主机架构，版本号写入 Info.plist；产物位于被忽略的 .build 下，已有同名 DMG 不覆盖。

v0.1.0 使用与现有标签相同的应用源码补充 DMG，不移动标签，不删除既有 ZIP；后续应用下载包只上传 DMG。校验文件可以继续提供，GitHub 自动生成的源码归档不属于应用安装包。README 固定这一发布规则。脚本只打包和校验，远程上传仍是显式操作，不加入自动发布 CI。

用户明确不需要 Apple 公证。后续发布保持 ad-hoc 签名 + DMG，不新增 Apple 公证、凭据收集、提交或 stapling 流程；这不是等待签名凭据的临时缺口。只有用户再次明确要求时，才重新评估签名与公证方案。首次打开可能出现的 Gatekeeper 提示继续如实说明，不建议关闭系统安全检查。

## Historical audit

[Git 初始化与发布边界](2026-10-04-git-initialization.md) 部分重叠于产物和凭据隔离，不规定安装包格式，原决定保留。现有八篇功能笔记不涉及打包，均不被取代。

## Alternatives considered

- 继续 ZIP 或长期同时发布 ZIP/DMG：解压安装简单，用户可选择容器，但违背后续只发布 DMG 的明确要求；ZIP 仅作为 v0.1.0 历史附件保留。
- 引入第三方 DMG 美化工具：可定制背景、图标位置和窗口布局，但当前只需要应用与 Applications 链接；使用系统工具，无额外依赖。
- Developer ID 签名并做 Apple 公证：可提供开发者身份验证，并减少未公证应用的首次启动阻拦，但用户明确不需要公证；保留现有 ad-hoc 发布方式，不引入证书、Apple 凭据和公证服务流程。

## Consequences

- 下载者可从只读镜像直接拖拽安装；后续版本复用同一脚本，版本与最低系统要求不靠手工填入。
- DMG 不解决 Gatekeeper：应用只有 ad-hoc 签名，没有 Developer ID 或 Apple 公证。仅构建当前主机架构，不承诺 Universal。没有自定义 Finder 布局，不影响拖拽安装；DMG 窗口外观仅在有明确需求时扩展，签名与公证仅在用户重新明确要求时评估。
- 已有同名产物必须由操作者明确移走才能重新打包，避免意外覆盖；上传现有发行版的安装包时不使用 clobber，校验清单更新才允许显式替换。
- 完整 GUI 和下载后的 Gatekeeper 验收不在镜像结构检查范围内；不修改真实 models.json，不启动应用。

## Verification

- bash -n 检查两个脚本语法；缺失版本、空版本、路径字符串和预发布后缀均拒绝。重复打包同名版本拒绝，DMG 哈希保持不变。
- Tests/check-release-dmg.sh 在打包后自动执行，也可独立运行：hdiutil 校验通过，diskutil 只读挂载后检查可执行文件、plist 版本、部署目标、bundle ID、签名与 Applications 链接，最后弹出镜像。
- v0.1.0 的 Sources 与 Package.swift 与标签无差异；新增 DMG 和历史 ZIP 的 SHA256SUMS.txt 均核验通过，标签不移动。
- 提交前执行笔记树、格式和归档校验；上传后核对 GitHub 的附件状态与 SHA256，发布说明区分历史 ZIP 和后续仅 DMG 的政策。
