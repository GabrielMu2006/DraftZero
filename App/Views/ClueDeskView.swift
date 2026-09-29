import SwiftUI
import DraftZeroCore

/// 线索台（UI-05 / R-004 / R-012 的核心审核流）：默认 1180 宽为两栏——
/// 左队列 + 右文档对照，证据在对照下方按需展开；窄窗口用「查看依据」覆盖面板。
/// 接受必须经过项目选择，拒绝/暂缓不改动归属；本机/降级/远程/重复/索引中/空结果各有状态文字。
struct ClueDeskView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let width: CGFloat

    @State private var joinTargetPair: CandidatePair?
    @State private var remoteAcceptTarget: RemoteSuggestion?
    @State private var showEvidenceOverlay = false

    private var engine: CandidateEngine? { model.candidateEngine }

    /// 窄窗口（<960）证据收进覆盖检查栏。
    private var usesEvidenceOverlay: Bool { width < 960 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.rule)
            switch model.semanticState {
            case .degraded(let message):
                degradedView(message)
            case .indexing where model.leadPairs.isEmpty && model.duplicatePairs.isEmpty:
                indexingView
            default:
                desk
            }
        }
        .background(Color.surface)
        .task {
            if model.leadPairs.isEmpty && model.duplicatePairs.isEmpty {
                await model.refreshSemantic()
            }
        }
        .sheet(item: $joinTargetPair) { pair in
            JoinProjectSheet(pair: pair)
        }
        .sheet(item: $remoteAcceptTarget) { suggestion in
            RemoteAcceptSheet(suggestion: suggestion)
        }
    }

    // MARK: - 顶部

    private var header: some View {
        ArchivePageHeader(
            index: "02",
            title: "线索台",
            subtitle: statusText) {
            if model.semanticState == .ready {
                Button("重建索引") {
                    Task { await model.rebuildSemanticIndex() }
                }
                .buttonStyle(ArchiveSecondaryButtonStyle())
                .font(.system(size: 12))
                .fixedSize()
            }
        }
    }

    private var statusText: String? {
        switch model.semanticState {
        case .idle, .indexing:
            return "索引中…（切片与语义向量，只处理可读取正文）"
        case .ready:
            let leads = model.leadPairs.count
            let dups = model.duplicatePairs.count
            let deferred = model.deferredLeads.count
            var parts = ["本机线索"]
            if leads > 0 { parts.append("待审 \(leads) 组") }
            if dups > 0 { parts.append("可能重复 \(dups) 项") }
            if deferred > 0 { parts.append("稍后处理 \(deferred) 条") }
            return parts.joined(separator: " · ")
        case .degraded:
            return nil
        }
    }

    private func degradedView(_ message: String) -> some View {
        ArchiveEmptyState(
            symbolName: "sparkles.slash",
            title: "语义线索暂不可用",
            message: message + "。当前只显示关键词线索；可以重建索引，重建不影响已确认的项目归属。",
            primaryTitle: "重建索引",
            primaryAction: { Task { await model.rebuildSemanticIndex() } })
    }

    private var indexingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在本机建立检索索引（切片与语义向量），只处理可读取正文…")
                .font(.archiveFootnote)
                .foregroundStyle(Color.mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 两栏桌面：队列 + 对照/证据

    private var desk: some View {
        HStack(spacing: 0) {
            queueList
                .frame(width: queueWidth)
            Divider().overlay(Color.rule)
            pairArea
        }
    }

    private var queueWidth: CGFloat { width >= 1280 ? 278 : 256 }

    // MARK: 左：队列

    private var queueList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if model.leadPairs.isEmpty && model.duplicatePairs.isEmpty
                    && model.deferredLeads.isEmpty && model.remoteSuggestions.isEmpty {
                    emptyQueue
                }
                let groups = engine?.candidateGroups(from: model.leadPairs) ?? []
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    sectionHeader("待命名线索组 \(index + 1)", count: group.count)
                    ForEach(group) { pair in
                        queueRow(pair, subtitle: groupSummary(pair))
                    }
                }
                if !model.remoteSuggestions.isEmpty {
                    sectionHeader("远程补充", count: model.remoteSuggestions.count, tint: .remote)
                    ForEach(model.remoteSuggestions) { suggestion in
                        remoteRow(suggestion)
                    }
                }
                if !model.duplicatePairs.isEmpty {
                    sectionHeader("可能重复", count: model.duplicatePairs.count, tint: .accent)
                    ForEach(model.duplicatePairs) { pair in
                        queueRow(pair, subtitle: "内容相同或近乎相同")
                    }
                }
                if !model.deferredLeads.isEmpty {
                    sectionHeader("稍后处理", count: model.deferredLeads.count)
                    ForEach(model.deferredLeads) { pair in
                        deferredRow(pair)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.surface)
    }

    private func sectionHeader(_ title: String, count: Int? = nil, tint: Color = .mutedText) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            if let count {
                Text("\(count)")
                    .font(.system(size: 11, design: .serif))
                    .foregroundStyle(Color.mutedText)
            }
            Spacer()
        }
        .padding(.top, 6)
    }

    private func groupSummary(_ pair: CandidatePair) -> String {
        pair.evidenceDecoded?.commonTerms.prefix(3).joined(separator: " · ") ?? "内容含义相近"
    }

    private func queueRow(_ pair: CandidatePair, subtitle: String) -> some View {
        let isSelected = model.selectedCluePairID == pair.id
        return Button {
            model.selectedCluePairID = pair.id
            if usesEvidenceOverlay { showEvidenceOverlay = false }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rowTitle(pair))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.archiveText)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mutedText)
                        .lineLimit(1)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.selected : Color.raised))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accent : Color.rule, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("线索：\(rowTitle(pair))，\(subtitle)\(isSelected ? "，当前选中" : "")")
        .accessibilityAddTraits(.isButton)
    }

    private func deferredRow(_ pair: CandidatePair) -> some View {
        HStack(spacing: 6) {
            queueRow(pair, subtitle: "暂缓的候选")
            Button("重新分析") {
                Task { await model.reanalyzePair(pair) }
            }
            .buttonStyle(ArchiveTextButtonStyle())
            .fixedSize()
            .help("暂缓的候选回到待审")
        }
    }

    private func remoteRow(_ suggestion: RemoteSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ArchiveStatusChip(text: "远程补充 · DeepSeek", color: .remote, systemImage: "cloud", outlined: true)
            ForEach(suggestion.draftIds, id: \.self) { draftId in
                Text(title(of: draftId))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.archiveText)
                    .lineLimit(1)
            }
            if let explanation = suggestion.explanation, !explanation.isEmpty {
                Text(explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mutedText)
                    .lineLimit(2)
            }
            HStack {
                Button("归入项目…") {
                    remoteAcceptTarget = suggestion
                }
                .buttonStyle(ArchiveTextButtonStyle())
                Button("忽略") {
                    Task { await model.dismissRemoteSuggestion(suggestion) }
                }
                .buttonStyle(ArchiveTextButtonStyle())
            }
        }
        .padding(10)
        .background(Color.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.remote.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private var emptyQueue: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .ultraLight))
                .foregroundStyle(Color.accent)
                .accessibilityHidden(true)
            Text("暂未发现关联")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.archiveText)
            Text("再导入几份相关素材后，本机会在这里提出带证据的候选。建议永远不直接改动归属。")
                .font(.system(size: 12))
                .foregroundStyle(Color.mutedText)
                .multilineTextAlignment(.center)
            Button {
                model.closeDetailPages()
                model.sidebarSelection = .draftBox
            } label: {
                Label("去草稿箱导入素材", systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(ArchiveSecondaryButtonStyle())
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: 右：并排对照 + 证据 + 操作

    @ViewBuilder
    private var pairArea: some View {
        if let pair = selectedPair {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        comparisonHeader(pair: pair)
                        comparison(pair: pair)
                        if usesEvidenceOverlay {
                            Button {
                                showEvidenceOverlay = true
                            } label: {
                                Label("查看依据", systemImage: "text.magnifyingglass")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color.accent)
                            }
                            .buttonStyle(.plain)
                        } else {
                            evidenceSection(pair: pair)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                actions(pair: pair)
            }
            .overlay {
                if usesEvidenceOverlay && showEvidenceOverlay {
                    evidenceOverlay(pair: pair)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 28, weight: .ultraLight))
                    .foregroundStyle(Color.mutedText)
                    .accessibilityHidden(true)
                Text("从左侧选择一条线索，对照两份草稿与证据")
                    .font(.archiveFootnote)
                    .foregroundStyle(Color.mutedText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedPair: CandidatePair? {
        (model.leadPairs + model.duplicatePairs + model.deferredLeads)
            .first { $0.id == model.selectedCluePairID }
    }

    private func comparisonHeader(pair: CandidatePair) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if pair.kind == .duplicate {
                ArchiveStatusChip(text: "可能重复", color: .accent, systemImage: "doc.on.doc", outlined: true)
            } else {
                ArchiveStatusChip(text: "本机线索", color: .confirmed, systemImage: "cpu")
            }
            Text("一次对照两份草稿，证据在下方")
                .font(.system(size: 12))
                .foregroundStyle(Color.mutedText)
            Spacer()
        }
    }

    private func comparison(pair: CandidatePair) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let evidence = pair.evidenceDecoded {
                evidenceCard(evidence.a, otherTitle: title(of: evidence.b.draftId), pair: pair)
                evidenceCard(evidence.b, otherTitle: title(of: evidence.a.draftId), pair: pair)
            }
        }
    }

    private func evidenceCard(_ snippet: PairEvidence.Snippet, otherTitle: String, pair: CandidatePair) -> some View {
        ArchiveEvidenceCard(
            title: title(of: snippet.draftId),
            sourceBadge: model.drafts.first { $0.id == snippet.draftId }?.sourceType.displayName ?? "草稿",
            sourceSymbol: model.drafts.first { $0.id == snippet.draftId }?.sourceType.symbolName,
            heading: snippet.heading,
            text: String(snippet.text.prefix(320)) + (snippet.text.count > 320 ? "…" : ""),
            footnote: pair.kind == .duplicate ? "内容相同或近乎相同（可能重复）" : nil)
    }

    /// 证据区：共同术语（或"含义相近"）+ 对照摘录 + 来源信息。
    private func evidenceSection(pair: CandidatePair) -> some View {
        Group {
            if let evidence = pair.evidenceDecoded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider().overlay(Color.rule)
                    Label(evidence.commonTerms.isEmpty
                        ? "内容含义相近（没有明显的共同关键词，来自本机语义分析）"
                        : "共同术语（本机线索）",
                        systemImage: "text.badge.star")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accent)
                    if !evidence.commonTerms.isEmpty {
                        FlowChips(items: evidence.commonTerms)
                    }
                    Text("对照摘录")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.mutedText)
                    ForEach([evidence.a, evidence.b], id: \.startOffset) { snippet in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title(of: snippet.draftId))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.archiveText)
                            Text(String(snippet.text.prefix(200)) + (snippet.text.count > 200 ? "…" : ""))
                                .font(.system(size: 12))
                                .foregroundStyle(Color.mutedText)
                                .lineSpacing(3)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .archiveCard()
                    }
                    sourceInfo(evidence: evidence)
                }
            } else {
                Text("这条线索没有可展示的摘录证据。")
                    .font(.archiveFootnote)
                    .foregroundStyle(Color.mutedText)
            }
        }
    }

    private func sourceInfo(evidence: PairEvidence) -> some View {
        HStack(alignment: .top, spacing: 24) {
            ForEach([evidence.a.draftId, evidence.b.draftId], id: \.self) { draftId in
                if let draft = model.drafts.first(where: { $0.id == draftId }) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.archiveText)
                            .lineLimit(1)
                        if let label = draft.sourceLabel {
                            Text("来源：\(label)")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.mutedText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text("导入于 \(draft.importedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.mutedText)
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    /// 窄窗口证据覆盖面板；关闭后焦点回到「查看依据」触发处。
    private func evidenceOverlay(pair: CandidatePair) -> some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { showEvidenceOverlay = false }
                .accessibilityHidden(true)
            ArchiveInspector(title: "依据", onClose: { showEvidenceOverlay = false }) {
                if let evidence = pair.evidenceDecoded {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(evidence.commonTerms.isEmpty
                            ? "内容含义相近（本机语义分析）"
                            : "共同术语（本机线索）",
                            systemImage: "text.badge.star")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.accent)
                        if !evidence.commonTerms.isEmpty {
                            FlowChips(items: evidence.commonTerms)
                        }
                        ForEach([evidence.a, evidence.b], id: \.startOffset) { snippet in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(title(of: snippet.draftId))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.archiveText)
                                Text(String(snippet.text.prefix(240)))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.mutedText)
                                    .lineSpacing(3)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .archiveCard()
                        }
                        sourceInfo(evidence: evidence)
                    }
                }
            }
            .frame(width: 320)
            // 减少动态效果开启时用淡入代替横向位移（R-012：信息不依赖动画承载，
            // 选中态由静态检查栏文字与高亮表达）。
            .transition(reduceMotion ? .opacity : .move(edge: .trailing))
        }
    }

    // MARK: 操作（R-004：主按钮加入项目/不相关，次操作暂缓；快捷键界面内可发现）

    private var sortedPairs: [CandidatePair] {
        (model.leadPairs + model.duplicatePairs).sorted { $0.score > $1.score }
    }

    private func movePair(_ step: Int) {
        let pairs = sortedPairs
        guard !pairs.isEmpty else { return }
        let current = pairs.firstIndex { $0.id == model.selectedCluePairID } ?? -1
        let next = min(max(current + step, 0), pairs.count - 1)
        model.selectedCluePairID = pairs[max(next, 0)].id
    }

    private func actions(pair: CandidatePair) -> some View {
        ArchiveActionBar {
            Button {
                joinTargetPair = pair
            } label: {
                Label("加入项目", systemImage: "lightbulb")
            }
            .buttonStyle(ArchiveStrongButtonStyle())
            .keyboardShortcut(.defaultAction)

            Button(role: .destructive) {
                Task { await model.rejectPair(pair); model.selectedCluePairID = nil }
            } label: {
                Text("不相关")
            }
            .buttonStyle(ArchiveSecondaryButtonStyle())
            .keyboardShortcut(.delete, modifiers: [.command])

            Button {
                Task { await model.deferPair(pair); model.selectedCluePairID = nil }
            } label: {
                Text("暂缓")
            }
            .buttonStyle(ArchiveSecondaryButtonStyle())
            .keyboardShortcut(".", modifiers: [.command])

            Button {
                movePair(-1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(ArchiveSecondaryButtonStyle())
            .keyboardShortcut(.upArrow, modifiers: [.option])
            .help("上一条线索（⌥↑）")
            .accessibilityLabel("上一条线索")

            Button {
                movePair(1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(ArchiveSecondaryButtonStyle())
            .keyboardShortcut(.downArrow, modifiers: [.option])
            .help("下一条线索（⌥↓）")
            .accessibilityLabel("下一条线索")

            Spacer()
            Text("⌘↩ 加入 · ⌘⌫ 不相关 · ⌘. 暂缓 · ⌥↑⌥↓ 切换")
                .font(.system(size: 11))
                .foregroundStyle(Color.mutedText)
                .help("审核快捷键")
        }
    }

    private func title(of draftId: UUID) -> String {
        model.drafts.first { $0.id == draftId }?.title ?? "（草稿）"
    }

    private func rowTitle(_ pair: CandidatePair) -> String {
        let a = model.drafts.first { $0.id == pair.draftA }?.title ?? "?"
        let b = model.drafts.first { $0.id == pair.draftB }?.title ?? "?"
        return "\(a) × \(b)"
    }
}

/// 简易流式标签排布。
struct FlowChips: View {
    let items: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accent.opacity(0.12)))
                    .foregroundStyle(Color.accent)
            }
        }
    }
}
