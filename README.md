# Draft Zero —— 无限草稿室

面向独立创作者的 macOS 应用：收纳未完成的想法，把它们归类成可继续推进的项目。
产品与验收规格见 [SPEC.md](SPEC.md)；实施计划与进度见 [IMPLEMENTATION.md](IMPLEMENTATION.md)。
「索引档案」UI 已于 2026-09-29 全量实施：逐屏方案见 [UI-REDESIGN-PLAN.md](UI-REDESIGN-PLAN.md)，逐项实机验收与[截图](ui-acceptance/)见 [UI-ACCEPTANCE.md](UI-ACCEPTANCE.md)；[概念图](design-concepts/)保留作视觉出处。
当前 V1 收尾的执行范围、质量门槛与待验事项见 [RELEASE-CLOSURE-PLAN.md](RELEASE-CLOSURE-PLAN.md)。
GitHub V0.1.0 预览版的发布准备、放行条件和后续工作见 [V0.1.0-RELEASE-PLAN.md](V0.1.0-RELEASE-PLAN.md)。
工作目录的本机整理和实验模型恢复方法见 [WORKSPACE-CLEANUP.md](WORKSPACE-CLEANUP.md)。桌面组件源码与扩展已存在；最终安装包上桌面的实机验收见 [RELEASE-NOTES-v0.1.0.md](RELEASE-NOTES-v0.1.0.md) 的如实记录。

## 系统要求

- **Apple Silicon Mac，macOS 26 或更高**（V0.1.0 只含 arm64 切片，不支持 Intel，也不承诺旧系统）。
- V0.1.0 为**未签 Developer ID、未公证**的预览版：首次打开需在「系统设置 → 隐私与安全性」点「仍要打开」，步骤见发布说明。无自动更新。
- 完全离线可用；可选的 DeepSeek 分析默认关闭，仅在用户主动填 Key 启用后发送所选文本（见 [PRIVACY.md](PRIVACY.md)）。

## 安装与数据

1. 下载 `DraftZero-v0.1.0-arm64.zip`，核对 [SHA256SUMS](dist/SHA256SUMS) 中的 SHA-256。
2. 双击解压，把 `DraftZero.app` 拖入「应用程序」。
3. 首次打开：右键点应用 →「打开」；若弹 Gatekeeper 提示，到「系统设置 → 隐私与安全性」点「仍要打开」。这是未公证应用的 Apple 官方流程，不要删除 quarantine 属性。
4. 备份：完全退出应用后，整体拷贝数据目录即为完整备份（含 SQLite 库、WAL 与 PDF 快照）：

数据位置（本机，无账号无云；主应用与桌面组件共享）：
`~/Library/Application Support/DraftZero/`（SQLite 库 + PDF 快照目录）

恢复：退出应用后把备份目录原样拷回即可。不要只拷单个 `.sqlite` 文件。

桌面组件与主应用读写同一份数据；组件条目上的一键状态修改即时写入本机库。桌面组件按 macOS 要求沙盒运行，经精确的文件访问授权只读写上述数据目录。

## 深链（draftzero://）与快捷指令

组件「新建草稿」与只读导航深链直接执行；**创建草稿、导入、改项目状态等写入型深链在正式构建中会先弹应用内确认**，拒绝或忽略都不会修改数据。QA 隔离环境变量 `DZ_WORKSPACE_DIR` 仅用于测试：如界面顶部出现「QA 隔离工作区」横幅，说明有遗留设置，运行 `launchctl unsetenv DZ_WORKSPACE_DIR` 并重启应用即可回到日常数据。

## 仓库结构

```
DraftZero/
├── SPEC.md               # 产品、归类与 UI 规格（产品所有者维护）
├── IMPLEMENTATION.md     # 实施计划、T-011 验证记录、进度
├── RELEASE-CLOSURE-PLAN.md          # V1 收尾执行方案和放行关口
├── V0.1.0-RELEASE-PLAN.md          # GitHub 预览版发布与后续计划
├── WORKSPACE-CLEANUP.md             # 本机实验归档和恢复记录
├── RELEASE-NOTES-v0.1.0.md         # V0.1.0 发布说明（含待验项如实清单）
├── PRIVACY.md                       # 本机存储与可选出站说明
├── THIRD-PARTY-NOTICES.md           # 第三方组件与模型许可
├── UI-REDESIGN-PLAN.md   # 索引档案 UI 逐屏方案与验收矩阵
├── UI-ACCEPTANCE.md      # UI 改版逐项验收记录与截图索引
├── project.yml           # XcodeGen 工程定义
├── App/                  # 主应用（SwiftUI；Theme.swift 为设计令牌，Views/ArchiveComponents.swift 为组件库）
├── Widget/               # 桌面组件（与主应用同档案主题）
├── Core/                 # DraftZeroCore 本地包：模型、存储、导入、版本
├── docs/licenses/        # 第三方与模型许可原文存档
├── ui-acceptance/        # 实机验收截图
├── design-concepts/      # 视觉概念图
├── t011-spike/           # 本机语义模型验证脚本、测试集、标注与结果；大模型实验文件已本机归档
└── tools/                # 本地工具（XcodeGen 便携版、发布构建脚本）
```

## 开发

依赖：Xcode 27（Swift 6.4）。XcodeGen 用仓库内便携版，无需安装 Homebrew；Git LFS 需自行安装（仓库内 113 MB 运行时模型权重经 LFS 分发，见 `.gitattributes`）。

```bash
# 生成 Xcode 工程
tools/xcodegen/bin/xcodegen generate

# 打开工程
open DraftZero.xcodeproj

# 命令行构建 / 运行核心测试
xcodebuild -project DraftZero.xcodeproj -scheme DraftZero build
cd Core && swift test

# 发布构建（两次全新 DerivedData + 校验 + ZIP + SHA256）
tools/release/build-release.sh
```

依赖版本以 `Core/Package.swift` 精确锁定 + `Core/Package.resolved` 为准；不要把本机 `Core/.build` 缓存当作依赖来源（2026-09-29 曾发现该缓存被伪造快照污染，已清除并以真实上游重锁，详见 `Core/Package.swift` 注释）。
