import SwiftUI

// MARK: - 档案风格下拉菜单（与索引档案 UI 同风格）
//
// 实现约束（2026-09-30 崩溃复盘）：macOS `.popover` 的瞬态窗口创建会触发
// 本机 Metal 遥测路径崩溃（EXC_BREAKING: IOGPU → CFString selector 错误，
// 崩溃栈见 release-closure 证据），因此菜单必须绘制在主窗口内部的浮层：
// 按钮经 GeometryReader 上报窗口坐标，MainWindowView 顶层统一渲染
// 半透明点击关闭层 + 锚定菜单。

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

/// 当前打开的菜单（窗口坐标锚点 + 菜单项）。
@MainActor
final class ArchiveMenuStore: ObservableObject {
    struct ActiveMenu: Identifiable {
        let id = UUID()
        let anchor: CGRect
        let options: [ArchiveMenuOption]
    }

    @Published var active: ActiveMenu?

    func show(options: [ArchiveMenuOption], anchor: CGRect) {
        guard !options.isEmpty else { return }
        active = ActiveMenu(anchor: anchor, options: options)
    }

    func dismiss() {
        active = nil
    }
}

/// 触发按钮：沿用调用处既有样式；点击时上报按钮在主窗口命名坐标空间中的位置
///（与 ArchiveMenuOverlay 的浮层同一空间，保证对齐）。
struct ArchiveDropdownMenu<Label: View>: View {
    @EnvironmentObject private var store: ArchiveMenuStore
    @ViewBuilder var label: () -> Label
    let options: () -> [ArchiveMenuOption]

    @State private var anchorFrame: CGRect = .zero

    var body: some View {
        Button {
            store.show(options: options(), anchor: anchorFrame)
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { anchorFrame = geo.frame(in: .named(ArchiveMenuSpace.name)) }
                    .onChange(of: geo.frame(in: .named(ArchiveMenuSpace.name))) { _, frame in
                        anchorFrame = frame
                    }
            })
        .accessibilityHint("打开菜单")
    }
}

enum ArchiveMenuSpace {
    static let name = "dzMainWindow"
}

// MARK: - 顶层渲染（MainWindowView 挂载）

struct ArchiveMenuOverlay: View {
    @EnvironmentObject private var store: ArchiveMenuStore
    let windowSize: CGSize

    private let menuWidth: CGFloat = 232

    var body: some View {
        if let menu = store.active {
            // 点击任意空白处关闭
            Rectangle()
                .fill(Color.primary.opacity(0.001))
                .contentShape(Rectangle())
                .onTapGesture { store.dismiss() }
                .overlay(alignment: .topLeading) {
                    ArchiveMenuContent(options: menu.options)
                        .offset(x: menuX(for: menu), y: menu.anchor.maxY + 6)
                        .transition(.opacity)
                }
        }
    }

    /// 菜单水平定位：右缘对齐触发按钮（下拉的常规预期），超出窗口时钳制。
    private func menuX(for menu: ArchiveMenuStore.ActiveMenu) -> CGFloat {
        let rightAligned = menu.anchor.maxX - menuWidth
        return max(12, min(rightAligned, windowSize.width - menuWidth - 12))
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
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
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
