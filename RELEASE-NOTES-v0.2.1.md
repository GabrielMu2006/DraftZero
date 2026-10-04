# Draft Zero V0.2.1 — 引擎升级（Pre-release）

**日期：** 2026-10-04 · **渠道：** GitHub Releases（Draft / Pre-release）· **平台：** Windows 11 24H2+ x64；macOS 26+ Apple Silicon

V0.2.1 是 V0.2.0 之后的引擎升级版：**Mac 端推理引擎从 CoreML 换为 ONNX Runtime**（与 Windows 同栈），并完成两处性能修复。功能与界面与 V0.2.0 一致。这是**预览版**：独立真实素材的正式验收仍未进行。

## 本版变化

- **Mac 引擎换栈**：multilingual-e5-small（int8 ONNX）经纯 C 桥（OrtBridge）推理，替换原 CoreML 路径。千稿级工作区全量索引从"小时级（不可用）"降到 **约 15 秒**，短文本单切片从秒级降到毫秒级。
- **前缀统一（修复）**：Mac 端此前漏加 `"query: "` 前缀（与 Windows 及验证配方不一致），本版两端统一。升级后首次刷新会自动重嵌一次索引（引擎签名不符自动触发），无需手动操作。
- **跨平台向量对齐**：黄金样本实测 Windows fp32 与 Mac int8 的余弦 **0.9988–0.9993**（历史首次通过 0.995 关口；V0.2.0 为 0.947–0.992）。
- **评分阶段性能**（双端）：候选落库的存在性检查从逐对查询改为一次批量读取；Mac 端字面分词的正则改为静态缓存（原每次调用编译约 50ms）。
- **质量口径（冻结 30 份集，dz-eval 同口径）**：Mac recall@5 = 81.0%（17/21）、prec@3 = **81.6%**（40/49，V0.2.0 为 76.6%），双达标（门槛 ≥80% / ≥70%）。Windows 口径不变（81.0% / 83.3%）。
- **包体**：Mac zip 从 225 MB 降到 **113 MB**（组件扩展不再嵌入模型副本；主应用单份模型）。

## 安装与升级

- 系统要求与未签名分发说明与 V0.2.0 相同（见 [RELEASE-NOTES-v0.2.0.md](RELEASE-NOTES-v0.2.0.md)）。
- **升级保留数据**：同 AppId 覆盖安装即可（Windows 直接运行新安装器；Mac 替换 /Applications 里的应用）。数据目录不变，**首次刷新线索台时索引自动重嵌一次**，期间语义线索短暂重建属预期。
- `.dzarchive` 迁移格式不变，V0.2.0 与 V0.2.1 之间双向迁移互通。

## 如实待验清单（继承 V0.2.0，未关闭项）

1. **独立真实/脱敏归类集的正式验收**：仍未提供；本版因此保持 Pre-release。
2. Windows 实机对 v0.2.1 的安装/升级复核由产品所有者进行（升级保留数据 + 首刷自动重嵌）。
3. Narrator/VoiceOver 朗读、DeepSeek 付费路径仍未真人复核（与 V0.2.0 相同）。
4. 本版已完成验证：Mac 77 项测试 0 失败、Windows 71 项测试 0 失败、双构建 Release 对照、安装器双端 SHA 一致。

---

**资产校验（2026-10-04 回填）：**

- `DraftZero-Setup-v0.2.1-win-x64.exe`：287,433,267 B · SHA-256 `a9dccdea31265b790d18672dff0dd4206526d57d9c5d542ebfa1493a9888522b`
- `DraftZero-v0.2.1-arm64.zip`（Mac）：SHA-256 `98311ca80a3ca8b20049c5121a9c5d0250f2bd86f010a8387553e221575aaaa3`
- 构建来源：tag `v0.2.1`（commit `baa28ec` 冻结源码 + 模型 `f80102d3…`（int8）+ tokenizer `0b44a9d7…` + ORT dylib `bffaa6ef…`（1.30.0））；Windows 机锁定还原 → 测试 71/71 → publish → ISCC 6.0.5；双端 SHA 一致。Mac：77 项测试 0 失败，双构建对照。
