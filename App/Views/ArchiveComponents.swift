import SwiftUI
import DraftZeroCore

/// 「索引档案」标准组件（UI-REDESIGN-PLAN §3 组件标准化，UI-01）。
/// 主导航与主要动作始终有文字；图标只作提示；状态不单靠颜色。

// MARK: - ArchivePageHeader：编号 + 标题 + 摘要行 + 尾随操作

struct ArchivePageHeader<Trailing: View>: View {
    let index: String
    let title: String
    var breadcrumb: String?
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(index)
                .font(.archiveIndexNumber)
                .foregroundStyle(Color.accent)
            if let breadcrumb {
                Text(breadcrumb)
                    .font(.archiveFootnote)
                    .foregroundStyle(Color.accent)
            }
            Text(title)
                .font(.archivePageTitle)
                .fontDesign(.serif)
                .foregroundStyle(Color.archiveText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 12)
            if let subtitle {
                Text(subtitle)
                    .font(.archiveFootnote)
                    .foregroundStyle(Color.mutedText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            trailing()
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }
}

extension ArchivePageHeader where Trailing == EmptyView {
    init(index: String, title: String, breadcrumb: String? = nil, subtitle: String?) {
        self.init(index: index, title: title, breadcrumb: breadcrumb, subtitle: subtitle) {
            EmptyView()
        }
    }
}

// MARK: - ArchiveIndexItem：索引脊背行（编号 + 名称 + 数量）

struct ArchiveIndexItem: View {
    let number: String
    let title: String
    var count: Int?
    var isSymbolOnly: Bool = false
    let symbolName: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isSymbolOnly {
                    Image(systemName: symbolName)
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? Color.archiveText : Color.mutedText)
                        .frame(maxWidth: .infinity)
                } else {
                    Text(number)
                        .font(.archiveIndexNumber)
                        .foregroundStyle(Color.accent)
                    Text(title)
                        .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(Color.archiveText)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let count, count > 0 {
                        Text("\(count)")
                            .font(.system(size: 12, design: .serif))
                            .foregroundStyle(Color.mutedText)
                            .monospacedDigit()
                    }
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.selected : .clear))
            // 选中竖线画在行容器 overlay 上：高度随行，不会像裸 Shape 一样被提案撑爆
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isSelected ? Color.accent : .clear)
                    .frame(width: 4)
            }
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var accessibilityText: String {
        var parts = ["\(number) \(title)"]
        if let count, count > 0 {
            parts.append("\(count) 项")
        }
        if isSelected {
            parts.append("当前页")
        }
        return parts.joined(separator: "，")
    }
}

// MARK: - ArchiveStatusChip：状态胶囊（文字承载状态，颜色只作提示）

struct ArchiveStatusChip: View {
    let text: String
    var color: Color = .mutedText
    var systemImage: String?
    var outlined: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(outlined ? .clear : color.opacity(0.13)))
        .overlay {
            if outlined {
                Capsule().strokeBorder(color.opacity(0.55), lineWidth: 1)
            }
        }
    }
}

// MARK: - ArchiveDraftRow：草稿行式档案卡

struct ArchiveDraftRow: View {
    let draft: Draft
    let projectCount: Int
    var projectNames: [String] = []
    var trailingHint: String?

    private var summary: String {
        if let content = draft.content, !content.isEmpty {
            return content.replacingOccurrences(of: "\n", with: " ")
        }
        return draft.hasExtractableText ? "（空草稿）" : "无可用于关联的文字"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(draft.title)
                    .font(.system(size: 17, weight: .medium))
                    .fontDesign(.serif)
                    .foregroundStyle(Color.archiveText)
                    .lineLimit(1)
                Text(summary)
                    .font(.archiveFootnote)
                    .foregroundStyle(Color.mutedText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Label(draft.sourceType.displayName, systemImage: draft.sourceType.symbolName)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mutedText)
                    if !draft.hasExtractableText {
                        ArchiveStatusChip(text: "无可用正文", color: .accent)
                    }
                    ArchiveStatusChip(
                        text: draft.isEditable ? "可编辑" : "只读快照",
                        color: draft.isEditable ? .confirmed : .mutedText)
                    if projectCount > 0 {
                        Label(
                            projectCount == 1
                                ? (projectNames.first ?? "1 个项目")
                                : "属于 \(projectCount) 个项目",
                            systemImage: "lightbulb")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.confirmed)
                            .lineLimit(1)
                    } else {
                        Text("未归组")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accent)
                    }
                }
            }
            Spacer(minLength: 8)
            if let trailingHint {
                Text(trailingHint)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accent)
                    .fixedSize()
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .archiveCard()
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        var parts = ["草稿：\(draft.title)", draft.sourceType.displayName,
                     draft.isEditable ? "可编辑" : "只读快照"]
        if !draft.hasExtractableText { parts.append("无可用于关联的文字") }
        parts.append(projectCount > 0 ? "属于 \(projectCount) 个项目" : "未归组")
        return parts.joined(separator: "，")
    }
}

// MARK: - ArchiveProjectRow：项目行

struct ArchiveProjectRow: View {
    let name: String
    let status: ProjectStatus
    let tags: [String]
    let memberCount: Int
    var isSelected: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(name)
                    .font(.system(size: 17, weight: .medium))
                    .fontDesign(.serif)
                    .foregroundStyle(Color.archiveText)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    ArchiveStatusChip(
                        text: status.displayName,
                        color: status == .archived ? .mutedText : .confirmed,
                        systemImage: status.symbolName)
                    Label("\(memberCount) 份草稿", systemImage: "doc")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mutedText)
                    ForEach(tags.prefix(3), id: \.self) { tag in
                        ArchiveStatusChip(text: tag, color: .accent, outlined: true)
                    }
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.mutedText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .archiveCard(background: isSelected ? .selected : .raised)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("项目：\(name)，状态 \(status.displayName)，\(memberCount) 份草稿")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - ArchiveEvidenceCard：对照摘录卡

struct ArchiveEvidenceCard: View {
    let title: String
    let sourceBadge: String
    var sourceSymbol: String?
    var heading: String?
    let text: String
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .fontDesign(.serif)
                    .foregroundStyle(Color.archiveText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Label(sourceBadge, systemImage: sourceSymbol ?? "doc")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mutedText)
                    .lineLimit(1)
            }
            if let heading, !heading.isEmpty {
                Label(heading, systemImage: "number")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accent)
                    .lineLimit(1)
            }
            Text(text)
                .font(.archiveBody)
                .foregroundStyle(Color.archiveText)
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if let footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .archiveCard()
    }
}

// MARK: - ArchiveEmptyState：空态（两强入口）

struct ArchiveEmptyState: View {
    let symbolName: String
    let title: String
    let message: String
    var primaryTitle: String?
    var primaryAction: (() -> Void)?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbolName)
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(Color.accent)
                .accessibilityHidden(true)
            Text(title)
                .font(.archiveSection)
                .fontDesign(.serif)
                .foregroundStyle(Color.archiveText)
            Text(message)
                .font(.archiveFootnote)
                .foregroundStyle(Color.mutedText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
            if primaryTitle != nil || secondaryTitle != nil {
                HStack(spacing: 12) {
                    if let primaryTitle, let primaryAction {
                        Button(primaryTitle, action: primaryAction)
                            .buttonStyle(ArchiveStrongButtonStyle())
                    }
                    if let secondaryTitle, let secondaryAction {
                        Button(secondaryTitle, action: secondaryAction)
                            .buttonStyle(ArchiveSecondaryButtonStyle())
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - ArchiveInspector：检查栏容器（标题 + 关闭；内容自理）

struct ArchiveInspector<Content: View>: View {
    let title: String
    var onClose: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.mutedText)
                Spacer()
                if let onClose {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.mutedText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭\(title)")
                    .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider().overlay(Color.rule)
            ScrollView {
                content()
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.raised)
        .overlay(alignment: .leading) { Divider().overlay(Color.rule) }
    }
}

// MARK: - ArchiveActionBar：底部操作条（主操作 + 次操作 + 快捷键提示）

struct ArchiveActionBar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.rule)
            HStack(spacing: 10) {
                content()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Color.surface)
    }
}

// MARK: - ArchiveWritingCanvas：全页写作面（标题可空 + 正文）

struct ArchiveWritingCanvas: View {
    @Binding var title: String
    @Binding var content: String
    var autoFocusContent = true

    @FocusState private var contentFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TextField("给这个念头起个名字（可稍后补）", text: $title)
                    .textFieldStyle(.plain)
                    .font(.archiveDetailTitle)
                    .fontDesign(.serif)
                    .foregroundStyle(Color.archiveText)
                    .padding(.bottom, 10)
                    // R-012/VoiceOver：占位文字不进入 AX 名称，需显式标签
                    .accessibilityLabel("标题")
                Divider().overlay(Color.rule)
                TextField("写下第一句话…不完整也可以保存", text: $content, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.archiveBody)
                    .lineSpacing(6)
                    .foregroundStyle(Color.archiveText)
                    .focused($contentFocused)
                    .padding(.top, 14)
                    .minimumScaleFactor(1)
                    .accessibilityLabel("正文")
            }
            .padding(.horizontal, 32)
            .padding(.top, 26)
            .padding(.bottom, 40)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.surface)
        .task {
            if autoFocusContent {
                contentFocused = true
            }
        }
    }
}

// MARK: - 筛选 chips（视图状态，不写入数据模型）

struct ArchiveFilterChips<Option: Hashable>: View {
    let options: [Option]
    let label: (Option) -> String
    var count: ((Option) -> Int?)? = nil
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    HStack(spacing: 5) {
                        Text(label(option))
                        if let value = count?(option), value > 0 {
                            Text("\(value)")
                                .font(.system(size: 11, design: .serif))
                                .monospacedDigit()
                        }
                    }
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.strongButtonText : Color.archiveText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(isSelected ? Color.strongButtonBackground : Color.raised))
                    .overlay {
                        if !isSelected {
                            Capsule().strokeBorder(Color.rule, lineWidth: 1)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(option))
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }
}
