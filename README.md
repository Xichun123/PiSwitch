# PiSwitch

用于编辑 Pi 模型配置、管理 Skills 和 AGENTS.md 的 macOS 原生应用，基于 SwiftUI 和 Swift Package Manager。模型配置位于 `~/.pi/agent/models.json`。

- 编辑 provider 连接和模型参数。
- 从接口发现模型，并从目录匹配模型元数据。
- 模型 `api` / `baseUrl` 默认继承 provider，不从目录自动填充；支持手动覆写。
- 模型地址下方可开启 `User-Agent` 覆写，默认填入 `claude-cli/2.1.295 (external, cli)`，支持编辑；关闭仅移除当前模型的 UA，保留其他请求头。
- 保存前校验配置，保留未知字段，备份原文件并检测外部修改冲突。

## Skills 管理

在独立的 Skills 页粘贴公开 GitHub 仓库首页地址，解析默认分支中的 skills，勾选后添加。完整文件统一保存到 `~/PiSwitch/skills/`，添加后默认未启用。

- 在「全局」视图启用后，所有项目生效；项目页标注全局生效，不重复勾选。
- 在「项目」视图添加项目目录，将未全局启用的 skills 分配给一个或多个项目。
- 全局入口为 `~/.pi/agent/skills/`，项目入口为 `<项目目录>/.pi/skills/`，入口是软链接，不复制多份文件。
- 支持单个、多选及全部手动检查，以及单个和批量更新。启动和定时均不检查更新。
- 本地新增、删除、内容及执行权限变化会使更新跳过，并显示变化文件；仅排除 Finder 的 `.DS_Store` 普通文件，不自动合并或强制覆盖。
- 每个 skill 只保留最近一次成功更新前的一份旧版，位于 `~/PiSwitch/backups/`。更新成功后自动清理更旧备份；清理失败明确报告并在后续操作重试。
- 同名来源或入口占用会阻止添加或启用，不覆盖外部目录、文件或链接。取消启用只删除 App 的预期链接。
- 批量操作逐项处理，一项失败不阻止其他项。安全停止取消下载或后续项目，不中断正在执行的文件替换；任务完成前不关闭窗口或退出。

更新共享库会影响所有已启用项目，在正在运行的 Pi 中执行 `/reload` 生效。项目级加载仍需要 Pi 的项目信任，App 不自动授予信任。

首版不接管已有 skills，不支持私有仓库、指定分支、仓库内符号链接或子模块，也不处理上游改名。每个 skill 最多 1,000 个文件、单文件 10 MiB、总大小 50 MiB；`SKILL.md` 最多 256 KiB、候选最多 100 个。缺失文件、树截断或内容校验失败不安装。仓库外的依赖不自动下载，第三方脚本不执行；启用前请审查内容。

安装记录位于 `~/PiSwitch/skills-state.json`，暂存位于 `~/PiSwitch/staging/`。记录损坏时停止写入；崩溃后遗留的未知操作目录只提示检查，不自动删除。正常失败恢复不代表断电或外部并发写入的完整事务保证。默认全局入口不自动跟随自定义 `PI_CODING_AGENT_DIR`。

## AGENTS.md 管理

独立的 AGENTS 页分为「全局版本」「项目模板」「项目文件」。全局版本和模板保存在 `~/PiSwitch/agents/`，名称、来源和应用记录位于 `~/PiSwitch/agents-state.json`。启动只读取，不自动导入或部署。

- 全局可以保存多个命名版本。「保存」只修改库内容；「应用到全局」经内容对照确认后，复制到 `~/.pi/agent/AGENTS.md`，不创建软链接。可以导入现有全局文件，导入不改原文件。
- 全局文件被外部修改时，可另存为新版本、明确备份后覆盖或取消；不会自动回写原版本。解除管理保留真实文件，不等于禁用指令。
- 项目通过文件夹选择或已有 Skills 项目路径登记。模板复制到 `<项目目录>/AGENTS.md`，之后独立编辑。修改或删除模板不传播到项目；项目内容也可以保存为新模板。已有文件使用模板时必须确认替换。
- 每个写入对象保留最近一次旧内容，支持恢复；实际全局文件与库版本分别备份。文件内容、身份、时间或权限变化会阻止写入。损坏记录、备份篡改、链接、硬链接、特殊权限／属性／ACL 不会被静默覆盖；超过 2 MiB、非 UTF-8 或含 NUL 的文件不接管。
- 未保存保护覆盖对象、分区、Tab 切换和关闭退出。`⌘S` 只保存当前编辑对象，不自动应用版本；Skills 页不执行文档保存。

Pi 会累加全局和启动目录祖先链的指令。同目录优先选择 `AGENTS.override.md`，再选 `AGENTS.md`／`AGENTS.MD`、`CLAUDE.md`／`CLAUDE.MD`。override 遮蔽普通文件时拒绝部署，但仍可明确编辑底层文件；在只有 CLAUDE 的项目创建 AGENTS 前提示加载来源变化。项目指令不依赖 Pi 项目信任。

实际指令文件变化后，在运行中的 Pi 执行 `/reload`；差异较大时建议另开会话。磁盘一致不表示现有会话已经重载。加载链是按所选启动目录的预测，未处理嵌套 linked worktree 去重，也不能识别 `--no-context-files`、SDK 或扩展改写。默认全局位置不自动跟随自定义 `PI_CODING_AGENT_DIR`。

复制只带 Markdown 内容，不复制附件、改写相对路径或替换变量。App 不执行指令里的命令、不上传内容、不修改项目 `.gitignore`。备份位于 `~/PiSwitch/agents/backups/`，未知暂存位于 `~/PiSwitch/agents/staging/`，只提示检查，不自动删除。正常失败恢复不承诺断电或外部并发写入下的完整事务。

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

可选 UI 检查：`bash Tests/check-agents-ui.sh`、`bash Tests/check-skills-ui.sh`、`bash Tests/check-model-disclosure.sh` 和 `bash Tests/check-sidebar-ui.sh`。需要终端已有 System Events 辅助功能权限；脚本使用临时技能库及虚构模型，不修改真实配置。Skills 检查同时覆盖启动不请求网络、批量部分失败继续、安全停止和写任务不重入。Yams 负责 YAML frontmatter，CryptoKit 负责指纹，当前 Skills Core 需要 Apple 平台。

### 本机更新并重启

已有 `/Applications/PiSwitch.app` 时执行：

```sh
bash scripts/install-local.sh
```

脚本构建 Release、准备并签名新包，正常退出 PiSwitch 后替换安装并重新打开。不生成 DMG，不运行测试、验证套件或哈希检查，也不修改 Pi 配置和指令库。旧安装保留在 `.build/install-local.<随机值>/PiSwitch.previous.app`。

如果有未保存修改，在软件中选择保存或放弃；取消退出或退出未完成时，脚本停止，不强杀进程。该快捷脚本复用已安装包的版本号和最低系统版本，不支持首次安装或包元数据变更；正式打包仍使用下方的发行脚本。

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
