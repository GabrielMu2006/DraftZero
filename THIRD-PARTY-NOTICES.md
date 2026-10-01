# 第三方组件与许可声明（THIRD-PARTY NOTICES）

本文件说明 Draft Zero V0.2.0 发行包中随包分发的第三方组件及其许可。
各组件的完整许可文本随源码保存在 `docs/licenses/`；引用摘录仅供快速阅读，
以 `docs/licenses/` 中的完整文本为准。

Draft Zero 项目本身的许可由产品所有者另行决定；本文件不构成对项目源码的任何许可证授予。

## Mac（V0.1.0 起，V0.2.0 继续）

| 组件 | 版本 | 许可 | 用途 | 来源 |
| --- | --- | --- | --- | --- |
| GRDB.swift | 7.11.1 | MIT | 本机 SQLite 存储（草稿、版本、项目、关系） | <https://github.com/groue/GRDB.swift> |
| swift-transformers | 0.1.24 | Apache License 2.0 | 本机分词（multilingual-e5-small tokenizer） | <https://github.com/huggingface/swift-transformers> |
| Jinja | 1.3.0 | MIT | swift-transformers 的模板依赖（聊天模板；本应用未直接调用） | <https://github.com/johnmai-dev/Jinja> |
| swift-argument-parser | 1.4.0 | Apache License 2.0 | swift-transformers 的传递依赖（Hub CLI；本应用未直接调用） | <https://github.com/apple/swift-argument-parser> |
| swift-collections | 1.7.1 | Apache License 2.0 | 传递依赖 | <https://github.com/apple/swift-collections> |

以上组件按原样分发，其版权与担保条款见各自完整许可文本。锁定版本的提交哈希见 `Core/Package.resolved`。

## Windows（V0.2.0 起）

| 组件 | 版本 | 许可 | 用途 | 来源 |
| --- | --- | --- | --- | --- |
| Avalonia | 12.1.3 | MIT | UI 框架（「索引档案」界面） | <https://github.com/AvaloniaUI/Avalonia> |
| Microsoft.ML.OnnxRuntime | 1.30.0 | MIT | 本机 ONNX CPU 推理（语义向量） | <https://github.com/microsoft/onnxruntime> |
| Tokenizers.HuggingFace | 3.23.1 | Apache License 2.0 | tokenizer.json 分词（Rust tokenizers 绑定，Apache-2.0） | <https://github.com/IgnaciodelaTorreArias/Tokenizers.HuggingFace> |
| PdfPig | 0.1.16 | Apache License 2.0 | PDF 文本提取 | <https://github.com/UglyToad/PdfPig> |
| Microsoft.Data.Sqlite | 10.0.12 | MIT | 本机 SQLite（ADO.NET） | <https://github.com/dotnet/efcore> |
| SQLite (e_sqlite3) | 随包 | Public Domain | SQLite 引擎 | <https://www.sqlite.org/> |
| .NET Runtime（self-contained） | 10.0 | MIT | 运行时随安装器分发 | <https://github.com/dotnet/runtime> |
| CommunityToolkit.Mvvm | 8.4.2 | MIT | MVVM 工具（源生成器） | <https://github.com/CommunityToolkit/dotnet> |
| 霞鹜文楷 LXGW WenKai（Regular） | 1.522 | SIL Open Font License 1.1 | 应用界面与正文显示字体（随包嵌入） | <https://github.com/lxgw/LxgwWenKai> |
| Inno Setup | 6.0.5（编译工具，不随包分发） | Inno Setup License | 安装器编译 | <https://jrsoftware.org/> |

说明：

- **PDF 应用内页预览**使用 Windows 系统组件 `Windows.Data.Pdf`（Windows.Data.Pdf API，随 Windows 分发），不引入第三方 PDF 渲染控件。
- **霞鹜文楷**基于 Fontworks Klee One（OFL 1.1）衍生；完整许可文本见 `docs/licenses/LXGW-WENKAI-OFL.txt`，OFL 允许随软件捆绑分发。
- API Key 的用户级受保护存储使用 Windows DPAPI（系统组件）。
- Inno Setup 只用于编译安装器；其许可文本不随应用分发，安装器本身不含 Inno Setup 代码运行时（卸载器除外，按其许可随包）。
- DeepSeek 远程分析为可选云服务（默认关闭），不属于随包组件。

## 随包模型

### multilingual-e5-small

- 原始模型：[intfloat/multilingual-e5-small](https://huggingface.co/intfloat/multilingual-e5-small)，Apache License 2.0（模型卡与许可原文见 `docs/licenses/e5-MODEL-LICENSE.md`）。
- Mac 版：CoreML 转换版（`e5_small.mlmodelc`，2026-09 由本仓库 `t011-spike/convert_coreml.py` 转换；int8 权重量化）。
- Windows 版：官方 fp32 ONNX 导出 `model.onnx`（SHA-256 `ca456c06b3a9505ddfd9131408916dd79290368331e7d76bb621f1cba6bc8665`）+ 官方 `tokenizer.json`（SHA-256 `0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39`），随安装器离线分发，不外发任何内容。
- 两端实现差异与质量口径见 `Windows/evidence/M0-TECHNICAL-GATE.md` 与 `RELEASE-NOTES-v0.2.0.md`。

## 运行环境声明

- Mac 应用本体与桌面组件使用 macOS 系统框架（SwiftUI、WidgetKit 等），版权归 Apple，随 macOS 分发，本文件不重复其条款。
- Windows 应用使用 Windows 系统框架（WinUI 之外的系统库、Windows.Data.Pdf、DPAPI），版权归 Microsoft，随 Windows 分发。
- 应用未内嵌任何遥测或统计 SDK。

## 更新方法

依赖版本变化时：更新 `Core/Package.swift` / `Windows/**/*.csproj` 精确版本与对应锁定文件，把新组件的完整许可文本放入 `docs/licenses/`，并同步本表。
