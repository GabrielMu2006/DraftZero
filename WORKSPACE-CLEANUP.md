# Draft Zero 工作目录整理记录

**日期：** 2026-09-29  
**原则：** 保留实验模型供以后使用，不上传 GitHub；不移动应用运行时模型、测试集、标注或生成/评分脚本。

| 项目 | 清理前 | 清理后 |
| --- | ---: | ---: |
| DraftZero 工作目录 | 约 3.6 GB | **616 MB** |
| 本机独立归档 | 0 | 约 3.0 GB |
| `t011-spike/` | 约 2.4 GB | 5.7 MB（保留脚本、30 份测试素材、标注和结果） |
| `Core/` | 约 1.2 GB | 577 MB（保留源码、运行时模型与 Swift Package checkouts/repositories） |

独立归档：`~/Documents/DraftZero-experiments-2026-09-29/`。其 `MANIFEST.json` 保存原路径、归档路径、文件数、字节数和 **16 个实验模型文件的 SHA-256**。移动后复算的 16 个哈希与移动前完全一致。

| 原路径 | 归档内路径 | 内容 | 文件数 |
| --- | --- | --- | ---: |
| `t011-spike/models/` | `t011-spike/models/` | ONNX、safetensors 与 CoreML 转换实验 | 16 |
| `t011-spike/.venv/` | `t011-spike/.venv/` | Python 实验环境 | 20,613 |
| `Core/.build/out/` | `Core/.build/out/` | Swift 构建产物与模块缓存 | 6,267 |

应用运行所需的 `Core/Sources/DraftZeroCore/Resources/e5-small-onnx/e5_small.mlmodelc/weights/weight.bin` **仍在原位**，清理后 SHA-256 为 `7397889b9a97ebb83004fab7380c403d7bd4fddb475a952923c3eb21151bf69f`。`t011-spike/testset/` 的 30 份文件仍在原位。工作目录新增 `.gitignore`，默认排除实验目录、缓存、数据库、凭据、原始 QA 证据；必要的 113 MB 运行时模型权重暂时也被忽略，未来发布 agent 配置 Git LFS 或固定哈希下载方案后才能改此规则。

## 恢复与使用

实验脚本如果需要 `t011-spike/models/` 或原 Python 环境，请先将对应目录从归档移回原路径。移动前确保没有正在运行的 Swift/Python 构建或测试，并确认原路径仍为空。对应关系和每个模型哈希见归档中的 `MANIFEST.json`。`Core/.build/out/` 可由构建系统再生；由于当前还有全新环境 Swift Package 解析问题，`Core/.build/checkouts` 与 `Core/.build/repositories` 特意留在项目内供排查。

此归档只是同一台 Mac 上的**本机整理**，不等于异地备份。GitHub 仓库不应包含该归档；以后如果要清理它，先单独确认哪些原始模型仍需保留。
