# 引擎性能基线（2026-10-03）—— 只测性能，未改任何引擎代码

**方法：** 新增只读基准工具（Mac `Core/Sources/dz-bench`、Windows `Windows/tests/DraftZero.Bench`），
全部调用**生产 API**（E5EmbeddingEngine / E5OnnxEmbedder / SemanticIndexStore / CandidateEngine），
引擎源码零改动。合成语料由冻结 30 份集派生（每篇 = 种子段落 + 本文唯一收尾句，指纹唯一），
规模 30/100/300/1000 稿，平均 516 B/篇，与真实集篇幅同量级。
**机器：** Apple M5，macOS 26.6.2，同机跑双端；C# 用仓库内 .NET 10.0.401 + ONNX Runtime 1.30.0 CPU。

> 如实说明：合成语料由 30 个种子派生，共享段落使「可能重复」远多于真实工作区
> （n=1000 时 dups=4273）。这对**计时偏保守**（候选量更大、写入更多），但重复/线索
> 计数本身不代表真实分布；n≥100 时 leads=0 亦为语料伪影。

## 1. 推理微基准（每切片延迟，n=30，预热后）

| 文本桶 | Mac 生产 CoreML（int8, cpuOnly） | C# ONNX fp32 | C# ONNX int8 |
| --- | --- | --- | --- |
| zh 50 字（~26 tok） | 1654 ms | 5.6 ms | 3.3 ms |
| zh 200 字（~67 tok） | 3237 ms | 7.2 ms | 6.5 ms |
| zh 600 字（~391 tok） | 21017 ms | 38.7 ms | 34.2 ms |
| en 40 字符（~14 tok） | 1450 ms | 3.1 ms | 2.0 ms |
| en 600 字符（~118 tok） | 5032 ms | 9.2 ms | 9.7 ms |
| **批量 300 切片** | **972 s（0.3 切片/s）** | **3.3 s（90 切片/s）** | **3.3 s（90 切片/s）** |

**差距约 300-600 倍。** 变体诊断（`dz-bench variant`，~200 tok 输入）：

| 模型 × 计算单元 | 均值 |
| --- | --- |
| 生产 e5_small.mlmodelc + cpuOnly（=生产路径） | 2879 ms |
| 生产 e5_small.mlmodelc + cpuAndGPU | 14463 ms |
| 生产 e5_small.mlmodelc + all（含 ANE） | 13863 ms |

**根因指向动态 shape：** 模型按动态序列长度导出（诊断中出现
`Espresso exception: "Invalid blob shape": Data-dependent shapes were disabled: embedding - [?, 384]`）。
动态 shape 使 ANE/GPU 无法Specialize（反而更慢），CPU 路径对 int8 权重量化 mlprogram 亦病态。
对照：同一台机器上 ONNX Runtime（CPU EP，10 线程）同为逐条推理只需毫秒级。

## 2. 规模曲线（全新库：切片+索引 与 候选生成分相计时）

| 平台/模型 | n | 切片 | 索引耗时 | ms/切片 | 候选生成 | 第二遍 |
| --- | --- | --- | --- | --- | --- | --- |
| Mac CoreML（生产） | 30 | 90 | 331.8 s | 3687 | 21.9 s | 22.8 s |
| Mac CoreML（生产） | 100 | 316 | 785.5 s | 2486 | **192.3 s** | 196.4 s |
| C# ONNX fp32 | 30 | 90 | 0.67 s | 7.4 | 0.028 s | 0.021 s |
| C# ONNX fp32 | 100 | 316 | 1.34 s | 4.3 | 0.118 s | 0.111 s |
| C# ONNX fp32 | 300 | 908 | 3.91 s | 4.3 | 0.409 s | 0.448 s |
| C# ONNX fp32 | 1000 | 3044 | 13.6 s | 4.5 | 3.53 s | 5.52 s |
| C# ONNX int8 | 1000 | 3044 | 18.0 s | 5.9 | 3.78 s | 6.47 s |

## 3. Mac 候选生成慢的归因（`dz-bench regen` 分相复刻，n=30，与引擎同循环形状）

| 相 | 耗时 | 结论 |
| --- | --- | --- |
| chunksByDraft（DB 读+blob 解码） | 255 ms | 非瓶颈 |
| 对循环复刻（3904 次标量余弦） | 1.16 s | 非瓶颈（常量级） |
| **逐对存在性 SELECT（435 条）** | **15.3 s（~35 ms/条）** | **主要瓶颈之一** |
| **SELECT 1 ×100（常数基线）** | **1.88 s（~19 ms/条）** | GRDB 异步往返常数高 |
| 字面信号（基准自设的每对重分词） | 47.2 s（~54 ms/次分词） | 引擎按稿预计算不成立此项，但暴露 NSRegularExpression 每次调用内编译（~54 ms/篇 × n 稿）|

归因链：候选数 ∝ n → 存在性 SELECT 次数 ∝ n²，每次 ~19-35 ms 的 DB 往返常数 →
n=100 时 regenerate 192 s（实测），n=1000 外推 **数小时级**。C# 同逻辑每对 <1 ms
（同事务内语句准备便宜），n=1000 仅 3.5-5.5 s。

> 复现注意：`regen` 子命令须先跑 `scale --sizes 30 --db <dir>` 填库，再用
> `--db-path <dir>/bench-30.sqlite` 分相计时；它读取库内已持久化草稿与切片。

## 4. 外推（按实测斜率，供路线图引用）

| 工作区 | C#（现状可跑） | Mac（现状） | Mac（若索引换 ONNX 级引擎 + 评分去 O(n²) 往返） |
| --- | --- | --- | --- |
| 100 稿 | ~1.5 s + 0.1 s | ~13 min + ~3 min | 亚秒 + 亚秒 |
| 1000 稿 | ~14 s + 4-6 s | ~2-4 h（外推） | ~15 s + <1 s |
| 10000 稿 | 需两阶段预筛（对循环 O(n²) 余弦开始成为主导） | 不可用 | 需两阶段预筛（同左） |

## 5. 结论与建议排序（本报告只测不改；修复见调研报告）

1. **Mac 推理换栈是第一优先**：动态 shape CoreML 在所有计算单元上都是 2.8-14.5 s/切片；
   同机 ONNX 4-40 ms。可选项：ONNX Runtime（osx-arm64 原生库已在 NuGet 依赖内）或
   重新导出**固定/枚举 shape** 的 CoreML 模型解锁 ANE。此项完成后 Mac 索引速度约 = Windows。
2. **Mac 评分去逐对 DB 往返**：存在性检查改为一次批量读取 + 内存比对（引擎代码改动，另行评审）。
3. **NSRegularExpression 移出 `tokens()` 成为静态缓存**（每次调用内编译 ~54 ms）。
4. Windows 安装包换 int8 ONNX 已再次确认无速度代价（fp32/int8 同级）。
5. 千稿以上规模：两阶段预筛（文档均值向量粗筛 + SIMD 精算）在两端都是下一步。

**产物：** `/tmp/dzbench/{mac-scale,win-fp32-scale,win-int8-scale}.json`、
合成语料生成脚本会话记录；基准工具随本仓库提交（`dz-bench`、`DraftZero.Bench`）。
