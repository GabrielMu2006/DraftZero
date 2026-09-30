# Draft Zero V1 验收证据（T-010）

**日期：** 2026-09-29（收尾轮更新；首轮 2026-09-27）
**基线：** SPEC.md V1 修订 5
**自动化证据：** `cd Core && swift test`（71 项，见下表）；`xcodebuild -project DraftZero.xcodeproj -scheme DraftZero build`
**图例：** ✅ 已自动化验证 · 🖐 需人工/产品所有者操作 · ⏸ 记录在案的已知偏差

| 需求 | 实现位置 | 自动化证据 | 人工验收项 |
| --- | --- | --- | --- |
| R-001 主动收纳本地素材 | `Core/Import/LocalFileImporter`、`DraftBoxView` | ImporterTests：逐项失败不互相影响、空文件不生成草稿、损坏 PDF 报错、原文件字节不变、重开可取回 | 🖐 真实拖放多种文件的手感；空态入口可见性 |
| R-002 网页/GitHub 快照 | `WebImporter`、`GitHubImporter`、`AddLinkSheet` | WebGitHubDiffTests：正文提取、失败分类、树截断标记、blob URL+SHA、取消勾选不导入；HTTPUserAgentRegressionTests（收尾轮）：三个出站收口默认 fetch 均带显式 UA、调用方 UA 不被覆盖、快照只读+来源正确；`DZ_NET_TEST=1` 真实网络冒烟 2/2 | 🖐 大型公开仓库的列表截断实感 |
| R-003 阅读/编辑/来源区分 | `DraftDetailView`、`createDerivedDraft` | StoreTests.testDerivedDraftKeepsSourceRelation；ImporterTests：副本可编辑、原文件不变、只读快照无覆盖入口 | — |
| R-004 本机关联建议 | `Chunker`、`SemanticIndex`、`CandidateEngine`、`E5EmbeddingEngine`、`dz-eval` | E5IntegrationTests：真实模型 recall@5 命中；CandidateEngineTests + 收尾轮回归 2 项（满槽枢纽保留跨语言伙伴、跨语言伙伴不被同语言噪声反转）；**生成集双指标达标：recall@5 = 21/21（100%）、prec@3 = 47/63（74.6%）**，可重复评估器与逐篇证据见 [release-closure/R004-QUALITY-REPORT.md](release-closure/R004-QUALITY-REPORT.md) | 🖐 **正式验收待独立真实/脱敏集 + 归属标注（产品所有者）；在此之前 V1 质量关口不标绿** |
| R-005 整理想法项目 | `ProjectStore`、`ProjectsView`、`JoinProjectSheet` | ProjectStoreTests：双项目共享一份内容、移出不影响另一处、删除项目保留草稿；候选接受幂等 | 🖐 接受→项目选择的操作流 |
| R-006 自动版本与恢复 | `AutoVersioner`、`recordVersionIfChanged`、版本 UI | StoreTests：变化才建版本、恢复产生新版本且历史保留；AutoVersionerTests：静默结算/立即结算/关闭全结算 | 🖐 编辑时的 60 秒版本节奏体验 |
| R-007 拆分/合并/重新解释 | `splitDraft`、`mergeDrafts`、`来路` 区 | SplitMergeTests：源不变、按序合成、双向关系、单稿拒绝、来源删除语义；关系说明可增改删 | 🖐 段落右键拆分的实际手感 |
| R-008 项目状态与标签 | `ProjectStatus`、`ProjectStore` 标签、TODO/封存页 | ProjectStoreTests：默认待整理、状态任意切换、同名标签不重复、按标签筛选 | — |
| R-009 桌面组件 | `Widget/DraftZeroWidget`、App Group 数据 | 构建：`DraftZeroWidget.appex` 嵌入；收尾轮：库定位收敛 Core（`WorkspaceOverrideTests`），组件时间线 SQL/解码与两个状态动作写路径实测（`WidgetDataPathTests` + 独立进程 `dz-eval widget-qa`，隔离库读写与主应用同步截图留证） | 🖐 **桌面实机添加 + 明暗背景 + 空状态（复核卡 3）** |
| R-010 DeepSeek 可选分析 | `DeepSeekProvider`、`SettingsView`、`RemoteModel` | RemoteAnalysisTests：未启用不发送（门禁）、编造引用剔除、单稿组丢弃、截断说明、401/402/429/500 映射、请求体无路径；HTTPUserAgentRegressionTests：默认 fetch 带 UA | 🖐 真实 Key 的启用/关闭/错误体验 |
| R-011 本机数据/删除/可见性 | `AppDatabase`、`deleteDraft` | StoreTests.testDeleteDraft…：正文与版本移除、其他草稿与关系行保留（来源已删除）；数据在 `~/Library/Group Containers/group.com.draftzero.shared/` | — |
| R-012 归类工作台界面 | `ClueDeskView` 等 | 构建 + 审核流贯通；⌘N/⌘O/⌘L/⌘K/⌥↑⌥↓ 快捷键；收尾轮：全页 AX 审计应用侧 0 缺陷（修复 3 处名称缺失）、减少动态效果代码修复 + Debug 探针 | 🖐 不读帮助完成主路径、**VoiceOver 全流程（复核卡 2）**、**减少动态效果系统开关开启态（复核卡 1）**、深浅色与高对比评审 |

## 已知偏差（均有记录与理由）

1. **沙盒与 App Group 未启用**（本地无签名身份）：Debug 构建数据落在 Application Support 且主应用/组件共享同一默认定位实现；分发前启用沙盒 + 证书即可（Core 逻辑已就绪）。
2. ~~R-004 质量门槛为工作线~~ **门槛已确认（recall@5 ≥80% 且 prec@3 ≥70%）**；生成集 2026-09-29 双达标（21/21、47/63），旧字面排序的跨语言压分与贪心截断已修复并加回归锁定。**独立真实/脱敏集验收仍缺席，V1 质量关口不标绿。**
3. **组件显示可能延迟刷新**：时间线由主应用主动刷新 + 30 分钟兜底；SPEC §6 已允许。
4. **组件形态按复核意见调整（2026-09-29/30）**：扩展按 macOS 26 要求沙盒化（否则不入组件画廊，temporary-exception 授权共享数据目录）；SPEC R-009 的"两种状态一键切换"按钮按产品所有者裁定移除（无签名构建上交互按钮不稳定 + 观感原因），组件保留项目一览、点击直达主应用对应项目与"新建草稿"入口；状态修改回主应用。SPEC R-009 文本由产品所有者后续修订。

## 待产品所有者完成（V1 正式放行前）

- [ ] 提供或认可独立真实/脱敏草稿集 + 归属标注（"同一项目 / 相关但不同项目 / 重复 / 无关"；格式建议见 release-closure/CLOSURE-REPORT.md 附录），在认可素材上按同一评估器复测双指标
- [x] ~~复核卡 1/2：减少动态效果 + VoiceOver~~ **产品所有者裁定 V0.1.0 首版不纳入（2026-09-30）**；应用侧代码与探针保留，发布说明如实标注"未复核"，未来版本按原卡补测（release-closure/FINAL-CHECKLIST-v0.1.0.md 存档）
- [ ] 复核卡 3：桌面组件实机添加、主路径、空状态、明暗背景（进行中：画廊收录与桌面渲染已达成）
- [x] ~~质量门槛数字确认~~（已确认：80%/70%）
- [ ] e5-small 选型与许可证（MIT）记录存档
