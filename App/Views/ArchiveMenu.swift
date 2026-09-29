import SwiftUI

// MARK: - 档案风格下拉菜单（替代系统原生 NSMenu，与索引档案 UI 同风格）

/// 菜单项：标题 + 右侧弱化快捷键提示 + 选中态 + 危险操作标红。
struct ArchiveMenuOption: Identifiable {
    var id: String { title }
    let title: String
    let shortcutHint: String?
    let isSelected: Bool
    let isDestructive: Bool
    let action: () -> Void

    init(
        _ title: String,
        shortcutHint: String? = nil,
        isSelected: Bool = false,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.shortcutHint = shortcutHint
        self.isSelected = isSelected
        self.isDestructive = isDestructive
        self.action = action
    }
}

/// 触发按钮沿用调用处的既有样式，弹出层为自绘行：
/// 悬停高亮（Color.raised）、hairline 边框、危险项红字、选中项打勾。
struct ArchiveDropdownMenu<Label: View>: View {
    @ViewBuilder var label: () -> Label
    let options: () -> [ArchiveMenuOption]

    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen = true
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            ArchiveMenuContent(options: options())
        }
    }
}

private struct ArchiveMenuContent: View {
    let options: [ArchiveMenuOption]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(options) { option in
                ArchiveMenuRow(option: option)
                if option.id != options.last?.id {
                    Divider().overlay(Color.rule.opacity(0.5))
                        .padding(.horizontal, 6)
                }
            }
        }
        .padding(6)
        .frame(width: 232)
        .background(Color.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.rule, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ArchiveMenuRow: View {
    let option: ArchiveMenuOption
    @State private var hovered = false

    var body: some View {
        Button {
            option.action()
        } label: {
            HStack(spacing: 8) {
                Text(option.title)
                    .font(.system(size: 13))
                    .foregroundStyle(
                        option.isDestructive ? Color(nsColor: .systemRed) : Color.archiveText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if option.isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accent)
                }
                if let hint = option.shortcutHint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mutedText)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered ? Color.raised : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(option.title + (option.isSelected ? "，当前选中" : ""))
    }
}
