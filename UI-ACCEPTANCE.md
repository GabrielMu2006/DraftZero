# Draft Zero ·「索引档案」UI 改版验收记录（T-012 / UI-01～UI-09）

**日期：** 2026-09-29（同日收尾轮更新，见文末"2026-09-29 收尾轮补充"）
**基线：** SPEC.md V1 修订 3 · UI-REDESIGN-PLAN.md（2026-09-29 确认方向）
**实施范围：** UI-01～UI-09 全部实施包；非半套交付
**自动化证据：** `cd Core && swift test` 71 项 0 失败（2 项真实网络冒烟按设计跳过；收尾轮新增 10 项：候选引擎回归 2、隔离库定位 2、组件数据路径 2、UA 回归 4）；`xcodebuild -project DraftZero.xcodeproj -scheme DraftZero -configuration Debug build` 通过（含 DraftZeroWidget.appex）
**实机验收方式：** 在隔离工作区（`DZ_WORKSPACE_DIR`，解析已收敛到 Core 的 `AppDatabase.defaultDatabaseURL()`，主应用与组件扩展同一实现）中实际操作构建出的 macOS 应用；正常启动不受影响
**截图目录：** [ui-acceptance/](ui-acceptance/)（33 张实际应用截图，概念图不可替代）

## 图例

✅ 实机验证通过 · 🔶 通过但有已记录限制 · ⏸ 系统级/既有风险（非本轮 UI 引入）

## 验收矩阵逐项核对（UI-REDESIGN-PLAN §7）

### 1. 空工作区 ✅

- 启动默认草稿箱，空态只有两个强入口（新建草稿 / 导入文件链接）+ 一句话说明。见 [01-空工作区-草稿箱](ui-acceptance/01-空工作区-草稿箱.png)。
- 全页新稿（⌘N）：占位标题可空、光标默认正文、标题正文全空时保存禁用。见 [02-新稿页-空](ui-acceptance/02-新稿页-空.png)、[02-新稿页-输入中](ui-acceptance/02-新稿页-输入中.png)。
- 仅正文保存 → 自动以正文首句前 24 字作临时标题（实测落库：`这个念头先记下来：把索引当作档案，把草稿当作未完`）。
- 批量导入 32 份混合素材（30 份基线测试集 + 2 份 PDF）：29 份文本全部成功、`面包笔记_备份.txt` 按指纹判重、两份 PDF 各自导入（可读 PDF 提取正文、`手写扫描页.pdf` 标"无可用于关联的文字"）。逐项成功/失败面板见 [04-导入结果面板](ui-acceptance/04-导入结果面板.png)。
- 原文件校验：导入后夹具目录文件数与内容未变（导入是复制）。
- 添加链接弹层经 AX 树验证结构完整（输入框/取消/打开/错误位）。~~当时实际抓取被本机系统级 CFNetwork 崩溃阻断~~（历史记录；当日下午已通过显式 User-Agent 修复并完成应用内导入实测，见"已知限制"第 1 条与 [32-网页快照-详情](ui-acceptance/32-网页快照-详情.png)）；2026-09-29 收尾轮再以 Core 层 URLProtocol 拦截回归锁定三个出站收口均带显式 UA（`HTTPUserAgentRegressionTests`，4/4 通过，见 [R004-QUALITY-REPORT](release-closure/R004-QUALITY-REPORT.md) 同目录收尾报告）。

### 2. 杂稿收纳 ✅

- 34 份混合素材（32 导入 + 拆分/合并产物 + 手动新建）下按 `全部/未归组/最近编辑/来源快照` 筛选正常；计数 chips 与摘要行同步。见 [06-草稿箱-全部列表](ui-acceptance/06-草稿箱-全部列表.png)、[05-草稿箱-来源快照筛选](ui-acceptance/05-草稿箱-来源快照筛选.png)。
- 空标题（临时标题回退）、长标题截断（`雨是从傍晚开始下的。 程澄把梯子架…`）、无正文 PDF（"无可用正文" chip）、只读快照、多项目归属（"属于 1 个项目"）均不破版。
- 宽窗口"继续推进"辅助栏显示 TODO 项目 + 待确认线索入口。见 [23-浅色-草稿箱](ui-acceptance/23-浅色-草稿箱.png)。

### 3. 本机归类 ✅

- 断网环境（本机语义，DeepSeek 未配置）索引 32 份草稿生成候选；线索台两栏（队列 + 对照/证据）。见 [07-线索台-两栏](ui-acceptance/07-线索台-两栏.png)。
- 证据可读：共同术语 chips、对照摘录、双方来源与导入时间。见 [08-线索台-对照证据](ui-acceptance/08-线索台-对照证据.png)。
- 接受先经项目选择（[09-线索台-加入项目弹层](ui-acceptance/09-线索台-加入项目弹层.png)）；实测接受后项目获得 2 名成员、待审 87→86。DB 断言：`accepted|1 pending|86`。
- 拒绝与暂缓：各处理一条后 `rejected|1 deferred|1 pending|84`，项目归属不变。见 [10](ui-acceptance/10-线索台-接受后队列.png)、[11](ui-acceptance/11-线索台-拒绝暂缓后.png)。
- "可能重复"与"同一项目"分区展示（105 组线索 + 4 项可能重复 + 1 条稍后处理）。
- 降级/索引中/空结果状态文字与重建索引入口保留（代码路径 + 设置页模型状态显示，见 [21-设置页](ui-acceptance/21-设置页.png)）。

### 4. 思维演化 ✅

- 深链拆分（源第 14 字符处）+ 合并（两份来源按序）+ 恢复旧版后，项目演化图与文字事件列表表达同一事实：2 起点 + 拆分产物 + 合并产物 4 节点、按类型着色的曲线边（拆分虚线）、事件记录 5 条（合并×2 / 拆分×1 / 版本×2）。见 [12-项目档案-演化](ui-acceptance/12-项目档案-演化.png)、浅色 [26](ui-acceptance/26-浅色-项目演化.png)。
- 图形用普通 SwiftUI 形状绘制（不复用已知的 Canvas/Metal 崩溃路径）；文字列表同时是无障碍替代，支持按类型筛选。
- 关系档案面板：来源/关系类型/日期/说明 + 双向"打开来源/目标草稿"。见 [14-演化-关系档案面板](ui-acceptance/14-演化-关系档案面板.png)。
- 删除来源的"来源已删除"文案路径保留（`originText`/事件列表 `fromTitle == nil`）。
- 版本对比（± 行标识 + 底色，不单靠颜色）与恢复（恢复产生 origin=restore 新版本、历史保留，DB 断言 `restore|1`）。见 [19-版本对比](ui-acceptance/19-版本对比.png)、[18-草稿详情-版本来路检查栏](ui-acceptance/18-草稿详情-版本来路检查栏.png)。

### 5. TODO 与封存 ✅

- 项目状态菜单改为 TODO 后：索引 04 徽标 +1、TODO 页显示该项目、草稿内容不变。见 [16-TODO页](ui-acceptance/16-TODO页.png)。
- 封存页空态正确（本项目未封存）。见 [17-封存页-空](ui-acceptance/17-封存页-空.png)。
- 新草稿先不归组（未归组 32 计数）。
- 桌面组件沿用索引档案配色与文字层级，保留 TODO/最近项目、两个快捷状态动作与新建草稿深链；`containerBackground` 适配桌面浅/深背景（Widget 代码审查 + 构建嵌入验证；桌面实际添加仍属用户手工操作，沿用既有记录）。

### 6. 窗口与外观 ✅

- 三档窗口实测：1180×760（默认，多张）、960×640（[28](ui-acceptance/28-960宽-草稿箱.png)、[29](ui-acceptance/29-960宽-线索台.png)：两栏线索台无第四列）、820×620（[31](ui-acceptance/31-820宽-草稿箱.png)、[30](ui-acceptance/30-820宽-线索台.png)：索引收成 64pt 图标栏，AX 名称完整"01 草稿箱，34 项，当前页"，主区单列无横向溢出、标题不竖排）。
- 浅/深外观：浅色草稿箱/新稿/线索台/项目演化（[23](ui-acceptance/23-浅色-草稿箱.png)～[26](ui-acceptance/26-浅色-项目演化.png)）与深色对应页（[01](ui-acceptance/01-空工作区-草稿箱.png)、[24 前一版深色线索台]、[27](ui-acceptance/27-深色-项目演化.png)、[12](ui-acceptance/12-项目档案-演化.png)）。同一结构、同构色板，无黑白突变、无强制色。
- 详情页/新稿页为主区页面，不再有常驻全局详情栏挤压列表。

### 7. 键盘 / 辅助使用 🔶

- 菜单处理器实测（与快捷键同一 action）：File>快速找（⌘K）打开面板（[20-快速搜索](ui-acceptance/20-快速搜索.png)）；前往>设置（⌘6）、前往>草稿箱（⌘1）正确换页；⌘N/⌘O/⌘L 与 ⌘2–5 共用同一 `model` 路由（代码审查）。
- 审核快捷键 ⌘↩ / ⌘⌫ / ⌘. / ⌥↑⌥↓ 保留并在操作栏可发现。
- VoiceOver/AX：索引项、行卡（真 Button，本轮修复——原先仅 trait 无动作，AXPress/VoiceOver 无法激活）、对照证据、事件记录、项目状态菜单均有完整中文标签与 isSelected 标记（AX 树逐项核对）。**收尾轮全页自动审计**（草稿箱/线索台/项目/TODO/封存/设置/新稿/添加链接）：除系统滚动条与窗口红绿灯按钮外 0 缺陷；修复 3 处缺失可读名称——设置页 DeepSeek Key 输入框、新稿页标题/正文字段、详情页正文编辑区。
- Escape：新稿页/详情页返回（cancelAction）、快搜面板 onExitCommand、检查栏关闭（cancelAction）。
- 减少动态效果：系统域受权限保护无法脚本开启（`defaults write com.apple.universalaccess` 被拒；`com.apple.Accessibility ReduceMotionEnabled` 实测**不会**驱动 SwiftUI 环境值——写域成功≠生效）；代码已修复：`ClueDeskView` 证据栏开启时改淡入（读取 `accessibilityReduceMotion`），全工程无其他显式位移动画，无以动画为唯一载体的信息；Debug 构建新增只读探针记录应用实际读到的环境值（启动读取 + 系统切换）。🔶 真实系统开关开启态复核留待 R-012 人工评审（步骤见 [MANUAL-REVIEW-CARDS](release-closure/MANUAL-REVIEW-CARDS.md) 卡 1）。
- 弹层焦点：检查栏关闭后焦点回触发处（"查看依据"按钮仍在对照区顶部）。

### 8. 数据安全 ✅

- 全程在隔离工作区实测（`DZ_WORKSPACE_DIR`）；真实工作区前后校验：草稿 1 份、项目 0 个，与启动前备份一致，未清空、未迁移。
- 已有草稿/项目/版本/关联结构未做任何数据库迁移（本轮仅新增只读查询 `lastEditedByDraft`）。

## UI-01～UI-09 完成判定逐条（实施包对照）

| 编号 | 完成判定 | 证据 |
|---|---|---|
| UI-01 | 全局页面和弹层无黑白突变、无系统蓝选中残留；对比度达标 | 主题令牌化（`Theme.swift` 全语义色 + 浅/深自适应 `NSDynamicProviderColor`）；本轮清除的系统蓝：分段选择器（改档案分段）、弹层默认按钮（改档案强/次按钮）、导入面板完成按钮；mutedText 浅底 ≈4.8:1、accent ≈5.1:1（色值取自方案） |
| UI-02 | 1180×760 打开草稿/项目/线索无竖排遮挡；菜单/深链可达 | 自定义索引脊背 + 顶栏 + 主区页面覆盖路由（`MainWindowView` 重写）；深链 new-draft/import/import-dir/tab/project/pair/accept-pair/reject-pair/defer-pair/split/merge/tag/status 全部实测或沿用 |
| UI-03 | 杂稿可快速加入、未归组可找到、TODO 项目可继续 | 筛选 chips + 未归组计数 + "去线索台查看依据" + 继续推进栏（截图 05/06/23） |
| UI-04 | 仅正文可保存；未保存返回安全；组件入口同屏；失败不丢输入 | 全页 `NewDraftPage`：占位标题、返回确认对话框（继续编辑/丢弃）、失败保留输入并显示错误（`newDraftError`）、深链 `draftzero://new-draft` 同页（截图 02×2） |
| UI-05 | 证据可读可定位；确认前选项目；拒绝/暂缓不归类 | 两栏线索台 + 按需证据覆盖面板（<960）+ JoinProjectSheet 保留（截图 07-11） |
| UI-06 | 状态/标签/一稿多项目正确；演化只显示真实关系；列表可操作 | 项目列表/档案重做；演化图仅呈现 DB 中的 evolutionRelation/draftVersion；行改真 Button（截图 12/14/15/16/17） |
| UI-07 | 编辑、恢复、拆合、来源仍可用；默认窗口正文可读 | 正文 ≤720pt；保存状态行（正在保存/已保存/失败）；版本对比/恢复实测；拆分右键、合并弹层、关系说明保留（截图 13/18/19） |
| UI-08 | 无孤立旧式白色表单；远程隐私与失败状态清楚 | 全部 sheet 统一档案样式；设置页分"本机归类/DeepSeek（可选）"，显示外发范围、Key 状态、默认关闭 chip（截图 21） |
| UI-09 | 验收矩阵全通过；截图与限制记录 | 即本文件 |

## 本轮发现并修复的问题（UI-09 阻断项闭环）

1. **索引脊背整列塌陷**（首次启动即见）：`ArchiveIndexItem` 内裸 `Rectangle` 在 `safeAreaInset` 有界提案下贪婪撑爆滚动区 → 竖线改为行 overlay 实现。
2. **隔离工作区缺 snapshots 目录**：`DZ_WORKSPACE_DIR` 分支未建目录，PDF 快照复制失败（"The file doesn't exist"）→ bootstrap 补建。
3. **草稿/项目行非真按钮**：仅 `.isButton` trait 无激活动作，VoiceOver/AXPress 无法打开 → 三处改为 `Button(.plain)`，键盘 Enter 亦可激活。
4. **演化图形缺关系边**：拆分/合并产物非项目成员时节点定位失败 → 图形节点纳入关系端点（衍生节点标注"衍生·日期"）。
5. **系统蓝色残留**：项目档案分段选择器、各弹层默认操作按钮、导入面板完成按钮 → 全部替换为档案样式（含快捷键保留）。
6. **【阻断】设置页必现 Metal 系统崩溃**：进入设置页即 `EXC_CRASH`（`NSInvalidArgumentException [__NSCFNumber length]`，栈在 Metal 遥测 `getCStringForCFString`，与本机既有崩溃日志 232651 同路径）。二分定位到 **`Toggle(.switch).tint(...)` 着色开关的渲染路径**；替换为档案风格开关按钮后连续切换/复进设置页均稳定。语义不变（开关文案 + AX accessibilityValue + "已开启/默认关闭" chip）。
7. **AX 设值不提交 SwiftUI binding 的验证盲区**：`AXUIElementSetAttributeValue` 对部分 SwiftUI 输入框只改显示不改 `@State`（自动化工具限制，真实键盘输入不受影响）；E2E 改用 AXTextArea 设值（可提交）+ 产品深链路径完成验证。
8. **【阻断】应用内网页抓取必现 CFNetwork 系统崩溃**（实机验收期间发现，当日解决）：修复方式见"已知限制"第 1 条——三个 HTTP 客户端收口处显式 User-Agent，应用内导入实测通过。

## 已知限制与既有风险（非本轮 UI 引入，均有记录）

> **2026-09-29 更新：原限制 1、2 已解决，限制 3 已部分完成——见下方"后续解决记录"。**

1. ~~**⏸ 网页快照抓取在本机被系统 CFNetwork 崩溃阻断**~~ **已解决（2026-09-29 当日）**：根因是 CFNetwork 在进程内首次构造默认 User-Agent 时于 `initializeUserAgentString` 触发系统崩溃。修复：新增 `Core/Util/HTTPUserAgent.swift`，在 `WebImporter`/`GitHubClient`/`DeepSeekProvider` 三个出站请求收口处显式盖章 `User-Agent`，绕过默认 UA 构造路径。**应用内实测**：添加链接 → 抓取本地网页 → 快照入库（标题/来源/正文提取正确，导航页脚剥离）→ 详情页只读展示 → 进程存活；此前同流程 2/2 必崩。见 [22-添加链接弹层](ui-acceptance/22-添加链接弹层.png)、[32-网页快照-详情](ui-acceptance/32-网页快照-详情.png)。Core 61 项测试仍全绿。
2. ~~**🔶 添加链接弹层的可视截图未能留存**~~ **已解决**：[22-添加链接弹层](ui-acceptance/22-添加链接弹层.png)（弹层 + 背景中的网页快照行），另有 [32-网页快照-详情](ui-acceptance/32-网页快照-详情.png)。
3. **🔶 减少动态效果复核部分完成**：`com.apple.universalaccess` 域受 TCC 保护无法直接写；`com.apple.Accessibility ReduceMotionEnabled=1` 可写但**实测不驱动 SwiftUI `accessibilityReduceMotion` 环境值**（2026-09-29 收尾轮负向验证，应用启动读取仍为 false——"写域成功"不构成验收）。代码侧收尾轮已完成：证据栏过渡读取环境值开启时改淡入、Debug 只读探针记录启动读取与运行中切换。系统设置真实开启态复核留待 R-012 人工（卡 1）。
4. **⏸ 桌面组件的实际桌面添加**（桌面"编辑组件"画廊）仍属手工评审项；2026-09-29 收尾轮已把库定位收敛到 Core 共享实现（主应用与组件扩展同一 `defaultDatabaseURL()`，支持隔离目录），组件时间线 SQL 与两个状态动作写路径已由独立进程实测（[MANUAL-REVIEW-CARDS](release-closure/MANUAL-REVIEW-CARDS.md) 卡 3 交接）。本轮自动化尝试桌面添加因用户桌面被占用、通知中心/桌面菜单不可脚本化而中止，未冒充实机通过。
5. ~~R-004 归类质量门槛（A-007）仍待产品所有者确认~~ **门槛已确认（recall@5 ≥80% 且 prec@3 ≥70%）；生成集已双达标（2026-09-29 收尾轮：21/21 与 47/63，见 [R004-QUALITY-REPORT](release-closure/R004-QUALITY-REPORT.md)），正式验收仍待产品所有者认可的独立真实/脱敏集。**

## 后续解决记录（2026-09-29 同日补充）

- **网页快照实机验证补全（R-002）**：UA 修复后完整流程通过——`添加链接 → 输入 URL → 打开 → 导入完成面板 → 草稿箱显示"网页快照 · 只读快照"行 → 详情页（来源 127.0.0.1、导入时间、提取正文、"创建可编辑副本"入口、footer "外部快照只读"）`。断言：隔离工作区 `sourceType='web'` 草稿 1 份，正文以"评测思想简史：为什么 Benchmark 记录判断过程"开头。
- **减少动态效果**：如上，键级验证完成并恢复。

## 2026-09-29 收尾轮补充（RELEASE-CLOSURE-PLAN P2–P5）

- **P0/P1（R-004）**：可重复评估器 `Core/Sources/dz-eval` 复现旧基线（recall 17/21 精确一致；prec 分子 40 一致、分母 62→63 差异已查明并锁定口径）；生产引擎修复贪心截断与跨语言排序压分后，同集 **recall@5 = 21/21（100%）、prec@3 = 47/63（74.6%）双达标**。详见 [R004-QUALITY-REPORT](release-closure/R004-QUALITY-REPORT.md)。
- **P2（减少动态效果）**：代码修复 + 探针；系统开关实机保留待人工（卡 1）。
- **P3（无障碍）**：全页 AX 审计 0 应用侧缺陷（修复 3 处名称缺失）；VoiceOver 主路径朗读体验保留待人工（卡 2）。
- **P4（R-009 数据隔离）**：库定位收敛 Core；隔离目录实测主应用与独立进程的组件数据路径（时间线读 + 两动作写 + 主应用同步，截图 [P4-app-sync-after-intents](release-closure/evidence/P4-app-sync-after-intents.png)）；桌面实机添加待人工（卡 3）。
- **P5（R-002）**：UA 回归 4/4（网页/GitHub/DeepSeek 默认 fetch + 调用方 UA 不覆盖）；快照只读流程回归纳入。Core 71 项 0 失败。
- **证据目录**：[release-closure/](release-closure/)（本文件历史记录保留原样，当前状态以本节与 SPEC/ACCEPTANCE 为准）。

## 数据与产物

- 隔离测试工作区：`/tmp/dz-ui-test/workspace`（34 草稿 / 1 项目 / 1 accepted + 1 rejected + 1 deferred + 105 pending / 34 版本 / 3 关系），夹具在 `/tmp/dz-ui-test/imports`（t011 基线 30 份 + 2 份 PDF + 本地网页 HTML）。
- 真实工作区 `~/Library/Application Support/DraftZero/`：与启动前一致（1 草稿/0 项目），未迁移未清空。
- 本轮代码产物：`App/Theme.swift`（重写）、`App/Views/ArchiveComponents.swift`（新）、`App/Views/NewDraftPage.swift`（新）、主窗口/草稿箱/线索台/项目/草稿详情/全部弹层/设置/Widget 重做、`AppModel`（隔离工作区、新稿路由、保存状态、未归组计数）、Core 仅新增只读查询 `lastEditedByDraft`；无数据库迁移。
