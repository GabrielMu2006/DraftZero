# Draft Zero V1 收尾执行报告（RELEASE-CLOSURE-PLAN P0–P5，2026-09-29）

**范围：** 本轮按 [RELEASE-CLOSURE-PLAN.md](../RELEASE-CLOSURE-PLAN.md) 完成 R-004 本机归类质量、R-012 无障碍与减少动态效果、R-009 数据隔离、R-002 证据与文档一致性的全部**可自主完成**工作。
**一句话结论：** 冻结 30 份生成集上 R-004 双指标达标（recall@5 21/21=100%，prec@3 47/63=74.6%，改动前 17/21 与 40/63）；引擎改动有消融与回归锁定；无障碍/减少动态效果/组件数据路径全部实测或修复。**独立正式素材缺席，V1 的 R-004 质量关口与 V1 放行保持"待验收"，未标绿。**

## 1. 各项改动与结果

### P0 基线与评估器（R-004）

- 冻结素材 SHA-256（[evidence/testset-sha256.txt](evidence/testset-sha256.txt)）、模型指纹、引擎规则快照，写入 [R004-QUALITY-REPORT.md](R004-QUALITY-REPORT.md)。
- 新增可重复评估器 `Core/Sources/dz-eval`：走**生产路径**（LocalFileImporter → CandidateEngine.refresh → 直接评估 candidatePair 待审队列），非 Python spike 分数。
- 复现旧基线：recall@5 **17/21 精确一致**；prec@3 分子 **40 一致**、分母 63 vs 旧报告 62。分母差 1 已查明：旧评估库含 2 份现已不存在的临时边界文档（旧报告 93 切片/91 线索 vs 本评估器 29 稿 91 切片/84 线索），经贪心截断挤占使一篇候选少 1。口径锁定为"逐篇前 3、按实际展示数汇总"，多次运行指标与逐篇 top-5 伙伴成员完全一致（CoreML 推理存在 ~1e-5 线程浮点抖动，不影响门槛指标，评估器指纹取 3 位小数）。
- 修复确定性缺陷：排序并列打破规则固定（`rankOrder` + 队列 SQL 二级排序 + 候选组按 id），此前字典迭代顺序随进程随机。

### P1 跨语言归类优化（R-004）

**诊断（两类错误分开归因，见 [R004-QUALITY-REPORT.md](R004-QUALITY-REPORT.md) §3）**

- 4 个 recall miss（全部英文稿）：真伙伴对合成分 0.579–0.632 均过地板却双向不在队列——根因是**全局贪心双边 topK 截断的查询不对称**（zh 稿被 zh-zh 高分对占满槽位后跨语言伙伴对被整条丢弃）。
- 23 个 prec@3 错例槽（en-en 12 / zh-zh 11）：**字面分（0.3 权重）系统性抬升同语言噪声对**（共享高频字词 0.02–0.10），跨语言真伙伴字面恒为 0 被稳定压过。

**改动（`CandidateEngine.swift`）**：保留规则改"每稿保留自己的前 6（并集）"；排序改纯语义（literalWeight 0.3→0，字面信号保留于证据展示与重复检测）；未按语言身份加固定分；地板合并为语义 ≥0.45。消融表（union+纯语义 46/63 优于 union-only 43/63、0.85/0.15 45/63）见报告 §3.3。

**同集前后对照（同一冻结素材、同一评估器）**

| 指标 | 改动前 | 改动后 | 门槛 |
| --- | --- | --- | --- |
| recall@5 | 17/21 = 81.0%（miss 4，全为跨语言被截断） | **21/21 = 100%** | ≥80% ✓ |
| prec@3 | 40/63 = 63.5%（错例 23 槽） | **47/63 = 74.6%**（错例 16 槽） | ≥70% ✓ |
| 待审线索队列 | 84 条 | 121 条 | — |

逐篇排名、每对得分/标签、错例明细：[evidence/P0-baseline-run1.json](evidence/P0-baseline-run1.json)、[evidence/P1-after-run1.json](evidence/P1-after-run1.json)。剩余 16 个错例槽全部是 e5-small 语义混淆对（如"评测报告节选↔烘焙书摘录"sem 0.924），由人工裁决兜底。
**回归**：新增 2 项测试锁定修复行为（满槽枢纽保留伙伴对、跨语言伙伴排序不被字面反转）；Core 全量 71 项 0 失败；重复/线索分流、原文证据、拒绝抑制、人工裁决规则全部保持。

### P2 减少动态效果（R-012）

- 代码：`ClueDeskView` 证据栏读取 `accessibilityReduceMotion`，开启时淡入代替横向位移；`NewDraftPage` 的 opacity 过渡本身无位移（保留）；全工程审计无其他显式动画，无以动画为唯一载体的信息。
- Debug 只读探针：应用启动读取与运行中系统切换都会记录 `accessibilityReduceMotion` 值（正式版无调试文案）。
- 实机验证：`universalaccess` 域写入被 TCC 拒绝；系统设置面板在本自动化会话 0 个 AX 窗口；**负向实证**——写 `com.apple.Accessibility ReduceMotionEnabled=1` 后应用启动读取仍为 false（该域不驱动 SwiftUI 环境；上一轮"写域成功"不构成验收）。探针工作正常（[evidence/P2-probe-reducemotion-false.txt](evidence/P2-probe-reducemotion-false.txt)、应用窗口截图 [evidence/P2-app-window-reducemotion-off.png](evidence/P2-app-window-reducemotion-off.png)）。
- **状态：代码修复完成 + 探针就绪；真实系统开关开启态复核保留待人工（复核卡 1），不写"通过"。**

### P3 无障碍审计与 VoiceOver（R-012）

- 自制 AX 审计器（[evidence/ax-audit-tool.swift](evidence/ax-audit-tool.swift)）逐页审计：草稿箱/线索台/项目/TODO/封存/设置/新稿/添加链接（[evidence/dz-evidence-p3-*.txt](evidence/)）。应用侧缺陷 0（系统滚动条箭头与窗口红绿灯按钮除外，非应用代码可控）。
- 修复 3 处缺失可读名称：设置页 DeepSeek Key 输入框（`accessibilityLabel("DeepSeek API Key")` + hint）、新稿页标题/正文字段、详情页正文编辑区；修复后设置页与新稿页复验 0 应用侧问题。
- **状态：可自动核对项全部通过；真实 VoiceOver 朗读体验保留待人工（复核卡 2），不写"通过"。**

### P4 组件数据隔离与实机（R-009）

- **修复**：`DZ_WORKSPACE_DIR` 解析从 `AppModel` 收敛到 Core（`AppDatabase.defaultDatabaseURL()/defaultSnapshotsURL()`），主应用与组件扩展走同一实现；未设置时默认路径不变。新增 `WorkspaceOverrideTests` 2 项。
- **实测**：`launchctl setenv` 一处设置后，普通 `open` 启动的主应用即命中隔离库（/tmp/dz-qa/workspace，截图 [evidence/P4-app-isolated-db-projects.png](evidence/P4-app-isolated-db-projects.png)）；种入 1 个 TODO + 1 个进行中项目后，独立进程按组件代码路径执行——时间线读 → "标记为基本完成" → "设为 TODO" → 时间线翻转（[evidence/P4-widget-intents-write.txt](evidence/P4-widget-intents-write.txt)），主应用重载显示一致（[evidence/P4-app-sync-after-intents.png](evidence/P4-app-sync-after-intents.png)）。新增 `WidgetDataPathTests` 2 项锁定时间线 SQL/解码与意图写路径。
- **受阻项**：桌面实机添加。本会话的合成点击已三次命中用户正在使用的其他应用（Dock/桌面工具/通知中心不可脚本化），继续操作用户活跃桌面风险不可接受——按方案保留**具体受阻证据**而非冒充通过；隔离环境、种入数据与逐步操作卡已备好（复核卡 3）。明暗背景与空状态的实际桌面截图同样留待该卡。
- **现场**：真实用户库全程未动（见 §3）。

### P5 UA 回归与文档一致性（R-002）

- UA 回归 4/4（`HTTPUserAgentRegressionTests`，URLProtocol 拦截**真实 URLSession.shared 默认 fetch**）：网页/GitHub/DeepSeek 三个收口均带显式 UA；调用方已有 UA 不被覆盖；网页快照只读流程（isEditable=false、sourceType=web、来源无锚点）在同一回归内通过。
- 文档修正：`UI-ACCEPTANCE.md`（截图数 30→33、34 处图片断链补 `ui-acceptance/` 前缀、旧"抓取被崩溃阻断"表述收敛为历史+已解决、每节补收尾轮状态）；`IMPLEMENTATION.md`（新增第十一次推进记录，旧"崩溃阻断"表述收敛为"崩溃栈指向默认 UA 初始化路径，显式盖章后未复现"，历史待办标注时点）；`SPEC.md`（修订 5；状态行、质量关口、A-007、B-001、交接结论同步）；`ACCEPTANCE.md`（R-002/R-004/R-009/R-012 状态与证据更新，待办清单收窄）。

## 2. 最终构建与测试

- `cd Core && swift test`：**71 项 0 失败**（2 项真实网络冒烟按设计跳过）。
- `xcodebuild -project DraftZero.xcodeproj -scheme DraftZero -configuration Debug build`：**BUILD SUCCEEDED**（含 DraftZeroWidget.appex）。

## 3. 现场恢复

- 真实用户库 `~/Library/Application Support/DraftZero/`：本轮开始前基线见 [evidence/real-db-before.txt](evidence/real-db-before.txt)（1 草稿 "123"/0 项目）；结束时复核逻辑内容一致（文件哈希可能因 WAL checkpoint 变化，以逻辑转储为准）。
- `launchctl unsetenv DZ_WORKSPACE_DIR` 已执行；系统键（`com.apple.universalaccess reduceMotion`、`com.apple.Accessibility ReduceMotionEnabled`）确认不存在（恢复原状）；测试应用进程退出；临时目录 `/tmp/dz-qa`（组件复核用隔离库，保留给复核卡 3）、`/tmp/dz-empty`（空状态场景）与 `/tmp/dz-eval`（评估产物）保留并在复核卡中注明用途，重启后自动清除。

## 4. 未通过 / 待人工项（不写"通过"）

| 项 | 状态 | 证据/入口 |
| --- | --- | --- |
| R-004 正式验收 | ⏸ 待独立真实/脱敏素材（生成集已达标不替代） | [R004-QUALITY-REPORT.md](R004-QUALITY-REPORT.md) §7 |
| 减少动态效果系统开关实机 | ⏸ 待人工（代码+探针就绪；写域≠生效已实证） | 复核卡 1 |
| VoiceOver 真实朗读主路径 | ⏸ 待人工（AX 层 0 缺陷） | 复核卡 2 |
| 组件桌面实机添加/明暗/空状态 | ⏸ 待人工（数据路径已实测；桌面操作受阻留证） | 复核卡 3 |
| e5-small 许可证文本存档 | ⏸ 待办（MIT，模型卡需存档原文） | ACCEPTANCE.md |

## 附录：正式 R-004 验收所需素材与标注格式（产品所有者输入）

1. **草稿集**：独立于现有 30 份生成集的真实草稿（敏感内容可改写脱敏），建议 ≥30 份、含多条项目脉络、中英混合与至少一对重复文件；正文需可选中（扫描版 PDF 不参与）。
2. **归属标注**（每份草稿一项）：`文件名 → { 同一项目: [其他文件名列表], 关系: 同一项目 / 相关但不同项目 / 重复 / 无关 }`；"相关但不同项目"与"无关"用于精度扣分判定。格式可参照 `t011-spike/groundtruth.json`（threads/duplicates/unrelated 三段）。
3. **验收方式**：素材放入一个目录，`dz-eval --testset <目录> --gt <标注.json> --db <临时库> --out <报告.json>` 一次运行出全部指标与逐篇排名；门槛 `recall@5 ≥80%` 且 `prec@3 ≥70%` 同时成立方可标注 R-004 正式通过、关闭 B-001。素材规模/构成与生成集不同时，报告需解释代表性，不得更换口径。
