# 引擎性能基线与换栈（2026-10-03/04，勘误版）

**本文档取代 2026-10-03 版本的数据结论（原文数值单位有误，见 §5 勘误）。**
**性质：** 只读基准 + 引擎换栈实施记录；质量关口全部重验。

## 0. 换栈摘要（2026-10-04 批次）

Mac 生产推理从 **CoreML（动态 shape int8 mlprogram）** 换为 **ONNX Runtime（int8 `model_quantized.onnx`，经 OrtBridge 纯 C 桥）**，同时修复两处历史偏差：

1. **`"query: "` 前缀缺失**：原 CoreML 路径定义了 `queryPrefix` 但从未使用（`dz-eval golden` 与 t011 配方都带前缀）；Windows 端一直带前缀。现两端统一 `"query: "`。
2. **跨平台向量分叉大幅收敛**：黄金样本实测 Windows fp32-ONNX vs Mac int8-ONNX 余弦 **0.9988–0.9993（9/9 全过 0.995 关口，M0 GOLDEN: PASS）**；旧 Mac int8-CoreML vs Windows fp32 为 0.947–0.992（未达 0.995）。M0 §3 的量化偏差问题实质关闭。

架构：`Core/Sources/OrtBridge`（纯 C 翻译单元：dlopen dylib + C API 会话 + mask 均值池化 + L2，内置互斥串行）+ `E5EmbeddingEngine` 重写（swift-transformers 分词 + 前缀/截断 + 桥调用）。dylib 与模型均取自已锁定制品：ONNX Runtime 1.30.0（与 Windows 同一 NuGet 包，dylib SHA-256 `bffaa6ef…`）、`model_quantized.onnx`（SHA-256 `f80102d3…`，M0-eval-int8 已验证同达标）。

## 1. 推理微基准（Mac，M5，修正单位后）

| 文本桶 | 旧 CoreML（动态 shape，cpuOnly） | 新 ONNX（OrtBridge） | C# ONNX fp32（同机参照） |
| --- | --- | --- | --- |
| zh 50 字 | ~2.0–2.7 s | **2.6 ms** | 5.6 ms |
| zh 200 字 | ~3.2 s | **6.1 ms** | 7.2 ms |
| zh 600 字 | ~38 s | **36 ms** | 38.7 ms |
| en 40 字符 | ~1.5 s | **2.1 ms** | 3.1 ms |
| en 600 字符 | ~5.0 s | **10.4 ms** | 9.2 ms |

CoreML 旧值为量级推断（见 §5 单位勘误：整秒部分从打印值不可恢复，但与墙钟/取样观察一致）；新值与 C# 同机对照同级。

## 2. 规模曲线（合成语料，修正单位后；C# 为 Stopwatch 实测）

| n | 切片 | Mac 新引擎 索引 | Mac regen（批量 SELECT 修复后） | C# 索引 | C# regen |
| --- | --- | --- | --- | --- | --- |
| 30 | 90 | 0.42 s | 19 ms | 0.67 s | 28 ms |
| 100 | 316 | 1.4 s | 168 ms | 1.3 s | 118 ms |
| 300 | 908 | 4.3 s | 1.3 s | 3.9 s | 409 ms |
| 1000 | 3044 | **14.8 s** | **14.1 s** | **13.6 s** | 3.5–5.5 s |

千稿级两端均可用（原 CoreML 路径 n=100 即 ~13 分钟，n=1000 不可用）。
Mac regen 在 n=1000 比 C# 慢 ~4x（标量余弦循环 vs .NET 向量化内联），后续可用预归一化 + SIMD 点积收敛，非阻塞项。

## 3. 评分阶段修复（修②）与正则缓存（修③）

- **批量存在性检查**（双端镜像）：regenerate 落库前一次读全表按无序对键聚合，替代逐对 `fetchOne`。语义不变（同对取 createdAt 最新）。修前 Mac regen 常数被 GRDB 异步往返放大（逐对 SELECT ~35ms/条量级），n=100 实测 192s+；修后 n=100 为 168ms。
- **NSRegularExpression 静态缓存**（Mac）：每次 `tokens()` 调用内编译 ~50ms（ICU），千稿级占分钟级；改为 `nonisolated(unsafe) static let`。C# 端本为手写扫描，无需改。

## 4. 质量关口（换栈 + 前缀统一后全量重验）

| 关口 | 结果 | 门槛 | 判定 |
| --- | --- | --- | --- |
| Mac 冻结 30 份集 recall@5 | 81.0%（17/21） | ≥80% | ✅ |
| Mac 冻结 30 份集 prec@3 | **81.6%（40/49）**（旧 Mac 引擎 76.6%） | ≥70% | ✅ |
| 黄金 token IDs（新旧引擎对 9 条） | 9/9 一致（分词路径未变） | 全同 | ✅ |
| 跨平台黄金余弦（Win fp32 vs Mac int8-ONNX） | **0.9988–0.9993** | 0.995 | ✅（历史首次达标） |
| Mac `swift test` | 77/77（0 失败） | — | ✅ |
| Windows `dotnet test` | 71/71（0 失败） | — | ✅ |

证据文件：`Windows/evidence/ENGINE-SWAP-eval-2026-10-04.json`（冻结集报告）、`golden-onnx.json`（新引擎黄金样本，提交入库）、`/tmp/dz-eval-onnx/`（会话产物）。
索引迁移：`indexStatus` 新增 `modelSignature`（Mac GRDB v5 迁移 / C# 启动时幂等 ALTER）；签名不符的切片在刷新时自动重嵌（新签名 `e5-small-int8-onnx-query-v1`，Windows `e5-small-fp32-onnx-query-v1`）。`.dzarchive` 不含向量，迁移格式不受影响。

## 5. 勘误（2026-10-03 版数据结论作废项）

**错误：** 基准脚本把 `Duration` 换算写错（`attoseconds/1e12` 得到微秒），且 `ContinuousClock.measure` 在 async 上下文里包裹阻塞调用时会显著虚增计时。两层叠加使 10-03 版的全部 Duration 类数值（Mac 推理/评分/regen 分相）**不可直接采信**——部分值虚高约 1000x，部分值丢失整秒部分，同一表内不一致。

**仍然成立（由墙钟、C `clock_gettime`、C# `Stopwatch` 三方独立佐证）：**
- 旧 CoreML 引擎真实缓慢（短文 ~2-3s/切片；n=100 索引 ~13 分钟——与取样等待的墙钟吻合）；
- C# 引擎数值（Stopwatch）全部真实；
- 评分阶段逐对 SELECT 的往返常数问题方向正确（修复后 n=100 从 ~192s 级到 168ms 级）；
- 正则逐调用编译 ~50ms/次为真（ICU 编译，与 10-03 分相观察一致量级）。

**作废：** 10-03 版 §1/§2/§4 的全部具体毫秒数与"300-600 倍"的精确倍数表述；§4 外推表。真实倍数：短文本 ~1000x（2.65s → 2.6ms），千稿索引从不可用变为 14.8s。据此，当日外部调研报告中引用的对应性能数字一并以本文档为准。

**教训（已固化）：** 基准计时一律 `durationMs()`（seconds×1000 + attoseconds/1e15）或 C/Stopwatch 计时；禁止在 async 上下文用 `measure` 包裹阻塞调用。
