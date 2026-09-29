import SwiftUI
import DraftZeroCore

/// 项目（R-005/R-008）与拆分/合并/来路（R-007）的应用层动作。
extension AppModel {

    // MARK: - 项目

    func createProject(name: String) async {
        guard let database else { return }
        _ = try? await database.createProject(name: name)
        await reload()
    }

    func renameProject(_ project: Project, to name: String) async {
        guard let database else { return }
        try? await database.renameProject(id: project.id, name: name)
        await reload()
    }

    func setProjectStatus(_ project: Project, status: ProjectStatus) async {
        guard let database else { return }
        try? await database.setProjectStatus(id: project.id, status: status)
        await reload()
    }

    /// 删除项目保留草稿（R-005）。
    func deleteProject(_ project: Project) async {
        guard let database else { return }
        try? await database.deleteProject(id: project.id)
        if selectedProject?.id == project.id {
            selectedProject = nil
        }
        await reload()
    }

    func addDraft(_ draftId: UUID, toProject projectId: UUID) async {
        guard let database else { return }
        _ = try? await database.addDraft(draftId, toProject: projectId)
        await reload()
    }

    /// 撤销误加的归属（R-005）：只移出项目，草稿与内容保留。
    func removeDraft(_ draftId: UUID, fromProject projectId: UUID) async {
        guard let database else { return }
        _ = try? await database.removeDraft(draftId, fromProject: projectId)
        await reload()
    }

    func addTag(_ name: String, toProject projectId: UUID) async {
        guard let database else { return }
        try? await database.addTag(name, toProject: projectId)
        await reload()
    }

    func removeTag(_ name: String, fromProject projectId: UUID) async {
        guard let database else { return }
        try? await database.removeTag(name, fromProject: projectId)
        await reload()
    }

    // MARK: - 拆分 / 合并（R-007）

    /// 拆分：段落级，源草稿不变；完成后选中新草稿。
    func splitDraft(_ draft: Draft, piece: String, offset: Int) async {
        guard let database else { return }
        if let split = try? await database.splitDraft(
            sourceId: draft.id, piece: piece, offsetInSource: offset, newTitle: nil) {
            await reload()
            selectedDraftID = split.id
        }
    }

    /// 合并：按给定顺序合成新草稿；完成后选中新草稿。
    func mergeDrafts(ids: [UUID], title: String?) async {
        guard let database else { return }
        if let merged = try? await database.mergeDrafts(ids: ids, title: title) {
            await reload()
            selectedDraftID = merged.id
        }
    }

    // MARK: - 来路（R-007）

    func loadRelations(draftId: UUID) async {
        guard let database else { return }
        draftRelations[draftId] = (try? await database.relations(draftId: draftId)) ?? []
    }

    func updateRelationNote(id: UUID, note: String?, draftId: UUID) async {
        guard let database else { return }
        try? await database.updateRelationNote(id: id, note: note)
        await loadRelations(draftId: draftId)
    }

    /// 关系另一端的草稿标题；已删除则返回 nil（界面显示"来源已删除"）。
    func draftTitle(id: UUID) -> String? {
        drafts.first { $0.id == id }?.title
    }
}

/// 项目详情分段（成员/演化）。
public enum ProjectSection: String, CaseIterable {
    case members = "成员"
    case evolution = "演化"
}
