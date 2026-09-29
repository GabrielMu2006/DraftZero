import Foundation
import SwiftUI
import DraftZeroCore

/// 远程分析（R-010）：默认关闭；Key 存 Keychain；仅发送标题与正文节选；
/// 错误不阻断本地工作流；建议只在通过引用校验后展示。
extension AppModel {

    static let keychainAccount = "deepseek-api-key"
    static let enabledDefaultsKey = "remoteAnalysisEnabled"

    private var hasKeyInKeychain: Bool {
        KeychainStore.read(account: Self.keychainAccount) != nil
    }

    func refreshRemoteState() {
        remoteEnabled = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
        remoteHasKey = hasKeyInKeychain
        if let provider = makeProviderIfPossible() {
            remoteProvider = provider
        }
    }

    /// 未启用或未提供 Key 时返回 nil——任何调用路径都不会发送正文（R-010 验收）。
    private func makeProviderIfPossible() -> DeepSeekProvider? {
        guard remoteEnabled, let key = KeychainStore.read(account: Self.keychainAccount), !key.isEmpty else {
            return nil
        }
        return DeepSeekProvider(apiKey: key)
    }

    /// 启用：必须先有 Key；开关持久化。
    func enableRemoteAnalysis(apiKey: String) async {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            remoteStatus = "请先填写 API Key"
            return
        }
        guard KeychainStore.save(account: Self.keychainAccount, secret: trimmed) else {
            remoteStatus = "无法写入钥匙串"
            return
        }
        UserDefaults.standard.set(true, forKey: Self.enabledDefaultsKey)
        refreshRemoteState()
        remoteStatus = "已启用，新加入的草稿将自动分析"
    }

    func disableRemoteAnalysis() {
        UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
        refreshRemoteState()
        remoteStatus = "已关闭，后续草稿不再远程发送"
    }

    func removeRemoteKey() {
        UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
        KeychainStore.delete(account: Self.keychainAccount)
        remoteProvider = nil
        refreshRemoteState()
        remoteStatus = "已移除 API Key 并关闭远程分析"
    }

    /// 主动重新分析（设置页入口）：分析全部含可读正文的草稿。
    func analyzeAllDraftsRemotely() async {
        let withText = drafts.filter { $0.hasExtractableText && $0.content?.isEmpty == false }
        await analyzeRemotely(draftIds: Set(withText.map(\.id)))
    }

    /// 新草稿导入/新建后的自动触发（R-010：启用后自动分析新加入的草稿）。
    func analyzeNewDraftsSince(previousIds: Set<UUID>) async {
        let newIds = Set(drafts.map(\.id)).subtracting(previousIds)
        guard !newIds.isEmpty else { return }
        await analyzeRemotely(draftIds: newIds)
    }

    private func analyzeRemotely(draftIds: Set<UUID>) async {
        refreshRemoteState()
        guard let provider = makeProviderIfPossible() else { return } // 关闭时静默跳过
        guard database != nil else { return }

        // 新草稿优先，其余草稿提供分组对象；只发标题+正文节选（R-010：不上传路径/文件）。
        let ordered = drafts.sorted { lhs, rhs in
            (draftIds.contains(lhs.id) ? 0 : 1) < (draftIds.contains(rhs.id) ? 0 : 1)
        }
        let withText = ordered.filter { $0.hasExtractableText && $0.content?.isEmpty == false }
        guard withText.count >= 2 else {
            remoteStatus = "可读取正文的草稿不足两份，暂无远程分组对象"
            return
        }
        remoteAnalyzing = true
        defer { remoteAnalyzing = false }
        do {
            let payload = withText.map { (id: $0.id, title: $0.title, text: $0.content ?? "") }
            let (proposals, notice) = try await provider.analyzeProjectCandidates(drafts: payload)
            let contents = Dictionary(uniqueKeysWithValues: withText.map { ($0.id, $0.content ?? "") })
            for proposal in proposals {
                // 双重校验后落库（提供方内部已校验一次；入库前再按当前正文校验）。
                let validCitations = proposal.citations.filter { citation in
                    DeepSeekProvider.quoteMatches(citation.quote, in: contents[citation.draftId] ?? "")
                }
                guard !validCitations.isEmpty, proposal.draftIds.count >= 2 else { continue }
                let suggestion = RemoteSuggestion(
                    provider: provider.identifier,
                    model: provider.model,
                    draftIdsData: try? JSONEncoder().encode(proposal.draftIds),
                    explanation: proposal.reason,
                    citationsData: try? JSONEncoder().encode(validCitations),
                    notice: notice)
                try? await database?.saveRemoteSuggestion(suggestion)
            }
            await loadRemoteSuggestions()
            remoteStatus = proposals.isEmpty
                ? "远程分析完成：未提出新分组"
                : "远程分析完成：\(proposals.count) 条建议（仅供参考）" + (notice.map { " · \($0)" } ?? "")
        } catch {
            // 错误不能让本地工作流不可用（R-010）。
            remoteStatus = error.localizedDescription
        }
    }

    func loadRemoteSuggestions() async {
        remoteSuggestions = (try? await database?.pendingRemoteSuggestions()) ?? []
    }

    func dismissRemoteSuggestion(_ suggestion: RemoteSuggestion) async {
        try? await database?.dismissRemoteSuggestion(id: suggestion.id)
        await loadRemoteSuggestions()
    }

    /// 接受远程建议：把整组草稿加入项目（与候选接受相同的确认路径；不自动创建）。
    func acceptRemoteSuggestion(_ suggestion: RemoteSuggestion, intoProject project: Project) async {
        for draftId in suggestion.draftIds {
            _ = try? await database?.addDraft(draftId, toProject: project.id)
        }
        try? await database?.dismissRemoteSuggestion(id: suggestion.id)
        await loadRemoteSuggestions()
        await reload()
    }
}
