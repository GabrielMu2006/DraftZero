import SwiftUI
import DraftZeroCore

/// 关系说明（R-007"重新解释"）：可修改或移除，不必复制原文。
struct RelationNoteSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let relation: EvolutionRelation
    let draftId: UUID

    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("关系说明")
                .font(.archiveSection)
                .fontDesign(.serif)
                .foregroundStyle(Color.archiveText)
            Text("记录这两个草稿为什么相关，或者这次重新解释的想法。")
                .font(.system(size: 12))
                .foregroundStyle(Color.mutedText)
            TextEditor(text: $text)
                .font(.archiveBody)
                .frame(width: 380, height: 110)
                .scrollContentBackground(.hidden)
                .archiveCard(cornerRadius: 8)
            HStack {
                Button("移除说明", role: .destructive) {
                    Task {
                        await model.updateRelationNote(id: relation.id, note: nil, draftId: draftId)
                        dismiss()
                    }
                }
                .foregroundStyle(Color.danger)
                .disabled((relation.note ?? "").isEmpty)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    Task {
                        await model.updateRelationNote(
                            id: relation.id,
                            note: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text,
                            draftId: draftId)
                        dismiss()
                    }
                }
                .buttonStyle(ArchiveStrongButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 430)
        .archiveSheet()
        .task { text = relation.note ?? "" }
    }
}
