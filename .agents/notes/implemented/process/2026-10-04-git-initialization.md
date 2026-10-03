# Agent Note: Git 初始化与发布边界

Status: implemented

## Problem

项目需要建立 Git 仓库，让用户将源码推送到 GitHub。本地构建产物、开发工具状态和可能含 Key 的配置不能进入初始提交。

## Decision

项目使用 main 分支，初始提交包含源码、测试、Package.swift、README 和现有决策笔记。.gitignore 排除 Swift 构建产物、.DS_Store、.serena 本机状态、models.json 及其备份、auth.json 和 .env 文件。初始提交前核对暂存文件和常见凭据模式，执行现有测试及笔记校验。不自动创建远程仓库或推送；远程地址由用户指定。

## Alternatives considered

- 连同 .serena 配置一起提交：其他开发者可以复用语言服务设置，但当前目录还含本机覆盖和会话记忆；初始发布不依赖 Serena，因此整体忽略，未来需要共享时再显式挑选项目级配置。
- 只初始化空仓库、不准备首个提交：副作用最少，但无法直接推送 main；本次同时准备 README 和初始提交，让用户只需绑定远程即可推送。

## Consequences

- 仓库可直接绑定远程并推送；README 描述当前环境要求、运行方式和配置安全边界。
- .gitignore 不是凭据扫描器，其他文件名中的秘密仍需人工检查。当前检查仅匹配常见凭据模式，不保证识别所有秘密格式。
- Serena 设置不随仓库发布，新开发者按需自行配置。现有功能笔记仍保留，不改变其决定。
- 本次不安装新依赖或加入 CI，也不修改真实配置；UI 检查脚本保持可选，不自动申请辅助功能权限。

## Verification

- swift test：21 个测试全部通过。
- git check-ignore 验证构建目录、本机状态及敏感配置名称均被排除。
- 初始提交前运行笔记树、格式及归档校验，检查 git diff --cached 和暂存文件清单；凭据模式检查只命中字段名称及测试占位 Key。
