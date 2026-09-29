import SwiftUI
import DraftZeroCore

/// 合并草稿（R-007）：勾选两份及以上文本草稿，按指定顺序合成新草稿；来源不变。
struct MergeSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var order: [UUID] = []
    @State private var title = ""

    private var editableDrafts: [Draft] {
        model.drafts.filter { $0.isEditable && $0.content?.isEmpty == false }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("合并草稿")
                    .font(.archiveSection)
                    .fontDesign(.serif)
                    .foregroundStyle(Color.archiveText)
                Text("按勾选顺序合成一份新的可编辑草稿；来源草稿不删除、不覆盖。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mutedText)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().overlay(Color.rule)

            if !order.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("合并顺序")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.mutedText)
                    ForEach(Array(order.enumerated()), id: \.offset) { index, id in
                        HStack {
                            Text("\(index + 1).")
                                .font(.system(size: 12, weight: .bold, design: .serif))
                                .foregroundStyle(Color.accent)
                            Text(model.drafts.first { $0.id == id }?.title ?? "?")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.archiveText)
                            Spacer()
                            Button {
                                guard index > 0 else { return }
                                order.swapAt(index, index - 1)
                            } label: {
                                Image(systemName: "arrow.up")
                            }
                            .buttonStyle(.plain)
                            .disabled(index == 0)
                            .accessibilityLabel("把「\(model.drafts.first { $0.id == id }?.title ?? "")」上移")
                            Button {
                                order.remove(at: index)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("移出合并")
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Divider().overlay(Color.rule)
            }

            List(editableDrafts) { draft in
                Button {
                    if let existing = order.firstIndex(of: draft.id) {
                        order.remove(at: existing)
                    } else {
                        order.append(draft.id)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(draft.title)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.archiveText)
                            Text(draft.content?.replacingOccurrences(of: "\n", with: " ") ?? "")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.mutedText)
                                .lineLimit(1)
                        }
                        Spacer()
                        if let index = order.firstIndex(of: draft.id) {
                            Text("第 \(index + 1) 位")
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.confirmed.opacity(0.15)))
                                .foregroundStyle(Color.confirmed)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)

            Divider().overlay(Color.rule)
            HStack {
                TextField("新草稿标题（可留空）", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("合并") {
                    Task {
                        await model.mergeDrafts(ids: order, title: title.trimmingCharacters(in: .whitespaces).isEmpty ? nil : title)
                        dismiss()
                    }
                }
                .buttonStyle(ArchiveStrongButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(order.count < 2)
            }
            .padding(12)
        }
        .frame(width: 520, height: 480)
        .archiveSheet()
    }
}
