import SwiftUI
import DraftZeroCore

/// 快速找（⌘K）：草稿/项目即输即筛，回车打开首个结果；方向键可选。
struct QuickSearchSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectionIndex = 0

    private var matchedDrafts: [Draft] {
        guard !query.isEmpty else { return Array(model.drafts.prefix(6)) }
        return model.drafts.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.content?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var matchedProjects: [Project] {
        guard !query.isEmpty else { return model.projects }
        return model.projects.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var totalMatches: Int { matchedProjects.count + min(matchedDrafts.count, 8) }

    var body: some View {
        VStack(spacing: 0) {
            TextField("找草稿或项目…", text: $query)
                .textFieldStyle(.plain)
                .font(.archiveSection)
                .padding(16)
                .onSubmit { openFirst() }
                .onChange(of: query) { _, _ in selectionIndex = 0 }

            Divider().overlay(Color.rule)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !matchedProjects.isEmpty {
                        section("项目")
                        ForEach(Array(matchedProjects.enumerated()), id: \.element.id) { index, project in
                            row(index, Label(project.name, systemImage: project.status.symbolName)) {
                                model.sidebarSelection = .projects
                                model.open(project: project)
                                dismiss()
                            }
                        }
                    }
                    if !matchedDrafts.isEmpty {
                        section("草稿")
                        ForEach(Array(matchedDrafts.prefix(8).enumerated()), id: \.element.id) { offset, draft in
                            let index = matchedProjects.count + offset
                            row(index, Label(draft.title, systemImage: draft.sourceType.symbolName)) {
                                model.open(draft: draft)
                                dismiss()
                            }
                        }
                    }
                    if matchedDrafts.isEmpty && matchedProjects.isEmpty {
                        Text("没有匹配的草稿或项目")
                            .font(.archiveFootnote)
                            .foregroundStyle(Color.mutedText)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 460, height: 380)
        .archiveSheet()
        .onMoveCommand { direction in
            guard totalMatches > 0 else { return }
            switch direction {
            case .down: selectionIndex = min(selectionIndex + 1, totalMatches - 1)
            case .up: selectionIndex = max(selectionIndex - 1, 0)
            default: break
            }
        }
        .onExitCommand { dismiss() }
    }

    private func openFirst() {
        if let project = matchedProjects.first {
            model.sidebarSelection = .projects
            model.open(project: project)
        } else if let draft = matchedDrafts.first {
            model.open(draft: draft)
        } else {
            return
        }
        dismiss()
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.mutedText)
    }

    private func row<Content: View>(_ index: Int, _ label: Content, action: @escaping () -> Void) -> some View where Content: View {
        let isSelected = index == selectionIndex
        return Button(action: action) {
            HStack {
                label
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.archiveText)
                    .lineLimit(1)
                Spacer()
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.selected : Color.raised))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accent : Color.rule, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
