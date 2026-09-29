import SwiftUI
import AppKit

/// Draft Zero 设计令牌 ——「索引档案」（UI-REDESIGN-PLAN §3，UI-01）。
///
/// 设计语言：浅石灰/柔纸/深墨/索引棕的连续纸色层次，深色外观使用同构的
/// 「夜间档案」色板。所有页面、弹层与组件只使用这里的语义令牌；
/// 禁止在页面中散布十六进制色值，也不再有强制整应用深色或局部强制浅色。
///
/// 规则：
/// 1. 未确认线索用 accent（索引棕），已确认用 confirmed（苔绿），远程补充用 remote（紫灰）；
///    选中与状态不单靠颜色，始终伴随文字或线型。
/// 2. 层次：canvas（窗口外围）→ rail（索引脊背）→ surface（主阅读面）→ raised（卡/弹层）。
/// 3. 圆角：卡片 10 / 控件 8 / 状态胶囊全圆；细线边框优先于高阴影。
/// 4. 衬线用于中文标题与 ASCII 编号（手稿气质）；正文一律系统无衬线。
extension Color {

    private static func archive(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
    }

    // MARK: 层次（浅色基准 / 夜间档案）

    /// 窗口外围/工作区背景
    static let canvas = archive(hex(0xD9D6CC), hex(0x242C2A))
    /// 主阅读与编辑面
    static let surface = archive(hex(0xF1F0E9), hex(0x303A34))
    /// 索引脊背
    static let rail = archive(hex(0xE7E6DC), hex(0x29332D))
    /// 待审建议、草稿行、弹层
    static let raised = archive(hex(0xFAFAF6), hex(0x39463E))
    /// 当前索引及选中行
    static let selected = archive(hex(0xD3D9CC), hex(0x435344))

    // MARK: 文字

    /// 正文和主标题
    static let archiveText = archive(hex(0x282B27), hex(0xEFF0E7))
    /// 辅助文字（浅底对比约 4.8:1）
    static let mutedText = archive(hex(0x666B65), hex(0xC3CCC2))

    // MARK: 线与语义

    /// 分隔线和边框
    static let rule = archive(hex(0xC8C8BE), hex(0x59665C))
    /// 编号、次级操作与待审标识（浅底约 5.1:1）
    static let accent = archive(hex(0x80602D), hex(0xE1C993))
    /// 用户确认的归属/演化关系
    static let confirmed = archive(hex(0x426C55), hex(0xA9D1B1))
    /// DeepSeek 补充（必须始终附文字来源）
    static let remote = archive(hex(0x6F5A83), hex(0xCFBCE0))
    /// 删除与破坏性操作
    static let danger = archive(hex(0xA5483B), hex(0xF0A89E))

    // MARK: 主按钮（浅色为深墨底纸色字，深色反转）

    static let strongButtonBackground = archive(hex(0x2A2D28), hex(0xE8E9DE))
    static let strongButtonText = archive(hex(0xF4F3EC), hex(0x2A2F2A))
    /// 强按钮悬停/按下态
    static let strongButtonPressed = archive(hex(0x3C403A), hex(0xD6D8CB))
}

// MARK: - 字号（macOS point，UI-REDESIGN-PLAN §3）

extension Font {
    /// 主页面标题（30–34）
    static let archivePageTitle = Font.system(size: 31, weight: .semibold).width(.standard)
    /// 详情页项目/草稿标题（25–30）
    static let archiveDetailTitle = Font.system(size: 26, weight: .semibold)
    /// 区标题（18–21）
    static let archiveSection = Font.system(size: 19, weight: .semibold)
    /// 正文（15–16）
    static let archiveBody = Font.system(size: 15)
    /// 辅助文字（13–14）
    static let archiveFootnote = Font.system(size: 13)
    /// 索引编号（衬线小号）
    static let archiveIndexNumber = Font.system(size: 12, weight: .medium, design: .serif)
}

// MARK: - 层次容器（替代旧 PaperSurface：不再强制浅色子树）

struct ArchiveCard: ViewModifier {
    var cornerRadius: CGFloat = 10
    var stroked = true
    var background: Color = .raised

    func body(content: Content) -> some View {
        content
            .background(background, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                if stroked {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color.rule, lineWidth: 1)
                }
            }
    }
}

extension View {
    /// 档案卡：raised 纸底 + 细描边。
    func archiveCard(cornerRadius: CGFloat = 10, background: Color = .raised) -> some View {
        modifier(ArchiveCard(cornerRadius: cornerRadius, background: background))
    }

    /// 无描边的面（用于大面板）。
    func archivePanel(_ background: Color = .surface, cornerRadius: CGFloat = 10) -> some View {
        modifier(ArchiveCard(cornerRadius: cornerRadius, stroked: false, background: background))
    }

    /// 弹层容器：raised 纸底 + 描边。
    func archiveSheet(cornerRadius: CGFloat = 12) -> some View {
        modifier(ArchiveCard(cornerRadius: cornerRadius, background: .raised))
    }
}

// MARK: - 主按钮（深墨胶囊，概念图中的「+ 新稿」「保存草稿」）

struct ArchiveStrongButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.strongButtonText)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed ? Color.strongButtonPressed : Color.strongButtonBackground))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// 次级按钮：细描边纸面。
struct ArchiveSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.archiveText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed ? Color.selected : Color.raised))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.rule, lineWidth: 1))
    }
}

/// 文字按钮（accent 色）。
struct ArchiveTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed ? Color.selected : .clear))
    }
}

// MARK: - 演化图（普通 SwiftUI 形状绘制；禁用 Canvas——本机曾触发 Metal 系统崩溃）

/// 二次贝塞尔曲线（演化关系边）。
struct QuadCurveShape: Shape {
    let from: CGPoint
    let to: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        path.addQuadCurve(
            to: to,
            control: CGPoint(x: (from.x + to.x) / 2,
                             y: from.y - min(46, abs(to.x - from.x) / 2) - 8))
        return path
    }
}
