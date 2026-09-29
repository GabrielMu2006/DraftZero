# 第三方组件与许可声明（THIRD-PARTY NOTICES）

本文件说明 Draft Zero V0.1.0 发行包中随包分发的第三方组件及其许可。
各组件的完整许可文本随源码保存在 `docs/licenses/`；引用摘录仅供快速阅读，
以 `docs/licenses/` 中的完整文本为准。

Draft Zero 项目本身的许可由产品所有者另行决定；本文件不构成对项目源码的任何许可证授予。

## 随包开源依赖

| 组件 | 版本 | 许可 | 用途 | 来源 |
| --- | --- | --- | --- | --- |
| GRDB.swift | 7.11.1 | MIT | 本机 SQLite 存储（草稿、版本、项目、关系） | <https://github.com/groue/GRDB.swift> |
| swift-transformers | 0.1.24 | Apache License 2.0 | 本机分词（multilingual-e5-small tokenizer） | <https://github.com/huggingface/swift-transformers> |
| Jinja | 1.3.0 | MIT | swift-transformers 的模板依赖（聊天模板；本应用未直接调用） | <https://github.com/johnmai-dev/Jinja> |
| swift-argument-parser | 1.4.0 | Apache License 2.0 | swift-transformers 的传递依赖（Hub CLI；本应用未直接调用） | <https://github.com/apple/swift-argument-parser> |
| swift-collections | 1.7.1 | Apache License 2.0 | 传递依赖 | <https://github.com/apple/swift-collections> |

以上组件按原样分发，其版权与担保条款见各自完整许可文本。锁定版本的提交哈希见 `Core/Package.resolved`。

## 随包模型

### multilingual-e5-small（CoreML 转换版）

- 原始模型：[intfloat/multilingual-e5-small](https://huggingface.co/intfloat/multilingual-e5-small)，Apache License 2.0（模型卡与许可原文见 `docs/licenses/e5-MODEL-LICENSE.md`）。
- 转换：2026-09 由本仓库 `t011-spike/convert_coreml.py` 从原始权重转换为 CoreML（`e5_small.mlmodelc`），随应用离线分发；转换只改格式，不改权重。
- 用途：本机语义向量（R-004 归类建议），完全离线运行，不外发任何内容。

## 运行环境声明

- 应用本体与桌面组件使用 macOS 系统框架（SwiftUI、WidgetKit、GRDB 之外的系统库），版权归 Apple，随 macOS 分发，本文件不重复其条款。
- 应用未内嵌任何遥测或统计 SDK。

## 更新方法

依赖版本变化时：更新 `Core/Package.swift` 精确版本与 `Core/Package.resolved`，把新组件的完整许可文本放入 `docs/licenses/`，并同步本表。
