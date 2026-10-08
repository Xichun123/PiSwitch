# PiSwitch

用于编辑 `~/.pi/agent/models.json` 的 macOS 原生应用，基于 SwiftUI 和 Swift Package Manager。

- 编辑 provider 连接和模型参数。
- 从接口发现模型，并从目录匹配模型元数据。
- 模型 `api` / `baseUrl` 默认继承 provider，不从目录自动填充；支持手动覆写。
- 保存前校验配置，保留未知字段，备份原文件并检测外部修改冲突。

## 环境要求

- macOS 27 或更高版本（以 `Package.swift` 为准）。
- 支持 Swift tools 6.0 的 Xcode / Swift 工具链。

## 开发

在项目根目录执行：

```sh
swift build
swift test
swift run PiSwitch
```

如当前开发者目录指向 Command Line Tools，可在命令前加：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run PiSwitch
```

可选 UI 检查：`bash Tests/check-model-disclosure.sh`。需要授予终端 System Events 辅助功能权限；脚本使用虚构配置，不修改真实配置。

## 安装与发布

从 [GitHub Releases](https://github.com/Xichun123/PiSwitch/releases/latest) 下载 DMG，打开后将 `PiSwitch.app` 拖到 `Applications`。当前提供 Apple Silicon（arm64）版本，要求 macOS 27.0+。

后续版本的应用安装包**只发布 DMG，不再发布 ZIP**；v0.1.0 的原 ZIP 作为历史附件保留。GitHub 自动生成的源码 ZIP/tar.gz 不属于应用安装包。

在 macOS 上打包（版本号也可带 `v` 前缀）：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/package-release.sh 0.1.0
```

产物为 `.build/release-v<版本>/PiSwitch-v<版本>-macos-<架构>.dmg`，只构建当前主机架构，不覆盖已有同名 DMG。脚本自动检查镜像、应用图标、签名、版本和安装链接，也可单独运行 `bash Tests/check-release-dmg.sh <DMG路径> <版本号>`。

向仓库推送 `v<三段数字版本号>` 标签（如 `v0.1.1`）会触发 GitHub Actions 自动构建、打包并发布 Release（含 DMG 与 `SHA256SUMS.txt`）。`v*` 标签会进入工作流，但不符合版本格式的标签会被拒绝；也可在本地手动打包发布。

在 Actions 的 Release 工作流中手动运行时，`tag` 可填写 `v0.1.1` 或 `0.1.1`，两者都指向**已经推送的 `v0.1.1` 标签**。例如：

```sh
gh workflow run release.yml --ref main -f tag=v0.1.1
```

`--ref main` 选择工作流定义，不决定打包源码。工作流先解析目标标签，再按确定的提交 SHA 检出、测试和打包；缺失标签不会被自动创建，标签在构建期间移动或删除会使发布失败。同一版本的发布任务串行执行；重新运行会替换该 Release 的同名 DMG 和校验文件，但只允许从目标标签对应的提交构建。历史标签若不含打包脚本或无法通过当前 runner 的测试，任务会失败，不会退回 `main` 构建。

发布流程回归检查可在项目根目录运行 `ruby Tests/check-release-workflow.rb`，只使用本地模拟命令，不访问网络或修改 Release。工作流在发布前也运行这项检查。

应用仅使用 ad-hoc 签名，未经过 Apple 公证。首次启动可能需要在「系统设置 → 隐私与安全性」按系统提示允许打开；请勿关闭全局 Gatekeeper。

## 配置安全

启动应用会读取真实的 `~/.pi/agent/models.json`；只有显式保存才写入，原文件备份为 `models.json.bak`。配置及备份中的 API Key 是明文，请勿提交到 Git。仓库忽略这些配置文件、构建产物和本机开发工具状态。

SwiftPM 构建输出为可执行文件，不是打包的 `.app`。可用 `swift build --show-bin-path` 查看输出目录。
