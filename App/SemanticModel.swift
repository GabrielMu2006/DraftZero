import SwiftUI
import DraftZeroCore

/// 语义子系统状态（R-004 的降级要求：模型/索引不可用必须明示，不能冒充完整分析）。
enum SemanticState: Equatable {
    case idle
    case indexing
    case ready
    case degraded(String)
}

extension AppModel {

    // MARK: - 语义索引与候选（R-004）

    func bootstrapSemantic() async {
        guard let database, candidateEngine == nil else { return }
        do {
            let engine = try await E5EmbeddingEngine()
            embedder = engine
            candidateEngine = CandidateEngine(database: database, embedder: engine)
        } catch {
            semanticState = .degraded("语义线索暂不可用（\(error.localizedDescription)），当前只显示关键词线索")
            return
        }
        await refreshSemantic()
    }

    /// 增量索引 + 重新生成候选。进入线索台时调用；草稿内容未变的部分自动跳过。
    func refreshSemantic() async {
        guard let engine = candidateEngine, let database else { return }
        semanticState = .indexing
        let drafts = (try? await database.drafts()) ?? []
        do {
            clueReport = try await engine.refresh(drafts: drafts)
            semanticState = .ready
        } catch {
            semanticState = .degraded("索引失败（\(error.localizedDescription)），可在设置中重建索引")
        }
        await loadQueues()
    }

    func loadQueues() async {
        guard let engine = candidateEngine else { return }
        leadPairs = (try? await engine.queue(kind: .lead)) ?? []
        duplicatePairs = (try? await engine.queue(kind: .duplicate)) ?? []
        deferredLeads = (try? await engine.queue(kind: .lead, status: .deferred)) ?? []
        rejectedLeads = (try? await engine.queue(kind: .lead, status: .rejected)) ?? []
        await loadRemoteSuggestions()
    }

    // MARK: - 裁决（接受 / 不相关 / 暂缓 / 重新分析）

    func acceptPair(_ pair: CandidatePair, intoProject project: Project) async {
        guard let engine = candidateEngine else { return }
        try? await engine.accept(pairId: pair.id, addDraftsToProject: project.id)
        await loadQueues()
        await reload()
    }

    func createProjectAndAccept(_ name: String, pair: CandidatePair) async {
        guard let database else { return }
        if let project = try? await database.createProject(name: name) {
            await acceptPair(pair, intoProject: project)
        }
    }

    func rejectPair(_ pair: CandidatePair) async {
        guard let engine = candidateEngine else { return }
        try? await engine.decide(pairId: pair.id, status: .rejected)
        await loadQueues()
    }

    func deferPair(_ pair: CandidatePair) async {
        guard let engine = candidateEngine else { return }
        try? await engine.decide(pairId: pair.id, status: .deferred)
        await loadQueues()
    }

    func reanalyzePair(_ pair: CandidatePair) async {
        guard let engine = candidateEngine else { return }
        try? await engine.reanalyze(pairId: pair.id)
        await loadQueues()
    }

    /// 索引故障后的完全重建（R-004：故障后可重建索引）。
    func rebuildSemanticIndex() async {
        guard let engine = candidateEngine, let database else { return }
        semanticState = .indexing
        let drafts = (try? await database.drafts()) ?? []
        do {
            try await database.rebuildSemanticIndex(drafts: drafts, embedder: engine.embedder)
            clueReport = try await engine.refresh(drafts: drafts)
            semanticState = .ready
        } catch {
            semanticState = .degraded("重建索引失败：\(error.localizedDescription)")
        }
        await loadQueues()
    }
}
