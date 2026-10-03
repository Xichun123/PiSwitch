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

产物为 `.build/release-v<版本>/PiSwitch-v<版本>-macos-<架构>.dmg`，只构建当前主机架构，不覆盖已有同名 DMG。脚本自动检查镜像、应用签名、版本和安装链接，也可单独运行 `bash Tests/check-release-dmg.sh <DMG路径> <版本号>`。发布时上传 DMG，校验和可作为独立附件提供。

应用仅使用 ad-hoc 签名，未经过 Apple 公证。首次启动可能需要在「系统设置 → 隐私与安全性」按系统提示允许打开；请勿关闭全局 Gatekeeper。

## 配置安全

启动应用会读取真实的 `~/.pi/agent/models.json`；只有显式保存才写入，原文件备份为 `models.json.bak`。配置及备份中的 API Key 是明文，请勿提交到 Git。仓库忽略这些配置文件、构建产物和本机开发工具状态。

SwiftPM 构建输出为可执行文件，不是打包的 `.app`。可用 `swift build --show-bin-path` 查看输出目录。
