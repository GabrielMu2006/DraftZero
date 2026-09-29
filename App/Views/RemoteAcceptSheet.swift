import SwiftUI
import DraftZeroCore

/// 接受远程建议：整组草稿加入现有或新建项目（与候选接受同样的确认路径，
/// 绝不自动创建归属——R-010）。始终标明「远程补充」来源。
struct RemoteAcceptSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let suggestion: RemoteSuggestion

    @State private var projects: [Project] = []
    @State private var selectedProjectID: UUID?
    @State private var newProjectName = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("把远程建议的草稿加入项目")
                        .font(.archiveSection)
                        .fontDesign(.serif)
                        .foregroundStyle(Color.archiveText)
                    ArchiveStatusChip(text: "远程补充 · DeepSeek", color: .remote, systemImage: "cloud", outlined: true)
                }
                Text("建议来源：DeepSeek（远程补充）。以下草稿将一起加入所选项目；建议只是建议，归属由你确认。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mutedText)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(suggestion.draftIds, id: \.self) { draftId in
                HStack {
                    Image(systemName: model.drafts.first { $0.id == draftId }?.sourceType.symbolName ?? "doc")
                        .foregroundStyle(Color.remote)
                    Text(model.draftTitle(id: draftId) ?? "（草稿）")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.archiveText)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
            }

            Divider().overlay(Color.rule)
            List {
                Section("现有项目") {
                    ForEach(projects) { project in
                        Button {
                            selectedProjectID = project.id
                        } label: {
                            HStack {
                                Label(project.name, systemImage: project.status.symbolName)
                                    .foregroundStyle(Color.archiveText)
                                Spacer()
                                if selectedProjectID == project.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.confirmed)
                                }
                            }
                        }
                    }
                }
                Section("或新建项目") {
                    TextField("新项目名称", text: $newProjectName)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)

            Divider().overlay(Color.rule)
            HStack {
                Button("忽略建议", role: .destructive) {
                    Task {
                        await model.dismissRemoteSuggestion(suggestion)
                        dismiss()
                    }
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("确认加入") {
                    Task {
                        if let projectId = selectedProjectID,
                           let project = projects.first(where: { $0.id == projectId }) {
                            await model.acceptRemoteSuggestion(suggestion, intoProject: project)
                        } else if !newProjectName.trimmingCharacters(in: .whitespaces).isEmpty {
                            if let project = try? await model.database?.createProject(name: newProjectName) {
                                await model.acceptRemoteSuggestion(suggestion, intoProject: project)
                            }
                        }
                        dismiss()
                    }
                }
                .buttonStyle(ArchiveStrongButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(selectedProjectID == nil && newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 460, height: 440)
        .archiveSheet()
        .task {
            projects = (try? await model.database?.projects()) ?? []
        }
    }
}
