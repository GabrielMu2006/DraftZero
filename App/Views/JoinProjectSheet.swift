import SwiftUI
import DraftZeroCore

/// 接受建议前的项目选择（R-005：确认候选必须选现有项目或输入新项目名；
/// 候选组名不自动成为正式项目名）。
struct JoinProjectSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let pair: CandidatePair

    @State private var projects: [Project] = []
    @State private var newProjectName = ""
    @State private var selectedProjectID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("把两份草稿加入项目")
                    .font(.archiveSection)
                    .fontDesign(.serif)
                    .foregroundStyle(Color.archiveText)
                Text("接受建议会同时把两份草稿加入所选项目；归属随时可以撤销。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mutedText)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().overlay(Color.rule)

            List {
                Section("现有项目") {
                    if projects.isEmpty {
                        Text("还没有项目——输入新名称创建。")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.mutedText)
                    }
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
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("确认加入") {
                    Task {
                        if let projectId = selectedProjectID,
                           let project = projects.first(where: { $0.id == projectId }) {
                            await model.acceptPair(pair, intoProject: project)
                        } else if !newProjectName.trimmingCharacters(in: .whitespaces).isEmpty {
                            await model.createProjectAndAccept(newProjectName, pair: pair)
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
        .frame(width: 440, height: 380)
        .archiveSheet()
        .task {
            projects = (try? await model.database?.projects()) ?? []
        }
    }
}
