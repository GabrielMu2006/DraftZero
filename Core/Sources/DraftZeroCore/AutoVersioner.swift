import Foundation

/// 自动版本记录器（R-006）：连续停止输入 60 秒、离开草稿或关闭窗口时，
/// 若正文相对上一版本有变化则生成版本；连续输入不逐字符建版本。
/// 时间间隔与时钟可注入，便于测试。
public actor AutoVersioner {

    public typealias Persist = @Sendable (_ draftId: UUID, _ content: String) async -> Void

    private var scheduled: [UUID: Task<Void, Never>] = [:]
    private var pending: [UUID: String] = [:]
    private let idleInterval: TimeInterval
    private let persist: Persist

    public init(idleInterval: TimeInterval = 60, persist: @escaping Persist) {
        self.idleInterval = idleInterval
        self.persist = persist
    }

    /// 每次正文变化调用；重置该草稿的静默计时。
    public func contentChanged(draftId: UUID, text: String) {
        pending[draftId] = text
        scheduled[draftId]?.cancel()
        let interval = idleInterval
        scheduled[draftId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            await self?.commit(draftId: draftId)
        }
    }

    /// 离开草稿/关闭窗口时立即结算，不再等待静默期。
    public func flush(draftId: UUID) async {
        scheduled[draftId]?.cancel()
        await commit(draftId: draftId)
    }

    public func flushAll() async {
        for (_, task) in scheduled { task.cancel() }
        scheduled.removeAll()
        for draftId in Array(pending.keys) {
            await commit(draftId: draftId)
        }
    }

    private func commit(draftId: UUID) async {
        scheduled[draftId] = nil
        guard let text = pending.removeValue(forKey: draftId) else { return }
        await persist(draftId, text)
    }
}
