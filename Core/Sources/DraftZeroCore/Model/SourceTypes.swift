import Foundation
import GRDB

/// 来源类型决定草稿是否可编辑（R-003）：
/// 本地 TXT/Markdown 为可编辑应用内副本；PDF/网页/GitHub 为只读快照；
/// 衍生草稿（从快照创建）可编辑并保留"源自"关系。
public enum SourceType: String, Codable, Sendable, DatabaseValueConvertible, CaseIterable {
    case manual
    case localFile = "local_file"
    case pdf
    case web
    case githubFile = "github_file"
    case derived

    public var displayName: String {
        switch self {
        case .manual: "应用内新建"
        case .localFile: "本地文件"
        case .pdf: "PDF 快照"
        case .web: "网页快照"
        case .githubFile: "GitHub 快照"
        case .derived: "衍生草稿"
        }
    }

    public var isEditableByDefault: Bool {
        switch self {
        case .manual, .localFile, .derived: true
        case .pdf, .web, .githubFile: false
        }
    }

    public var symbolName: String {
        switch self {
        case .manual: "square.and.pencil"
        case .localFile: "doc.text"
        case .pdf: "doc.richtext"
        case .web: "globe"
        case .githubFile: "chevron.left.forwardslash.chevron.right"
        case .derived: "arrow.triangle.branch"
        }
    }
}

/// 版本来源（R-006）：外部快照只有 initial；恢复产生新版本且不抹掉历史。
public enum VersionOrigin: String, Codable, Sendable, DatabaseValueConvertible {
    case initial
    case autoSave = "auto_save"
    case manual
    case restore
    case split
    case merge

    public var displayName: String {
        switch self {
        case .initial: "初始版本"
        case .autoSave: "自动保存"
        case .manual: "手动保存"
        case .restore: "恢复旧版"
        case .split: "拆分"
        case .merge: "合并"
        }
    }
}

/// 演化关系类型（R-007 / SPEC §5）。
public enum RelationType: String, Codable, Sendable, DatabaseValueConvertible, CaseIterable {
    case split
    case merge
    case reinterpret
    case manualLink = "manual_link"
    case derived

    public var displayName: String {
        switch self {
        case .split: "拆分"
        case .merge: "合并"
        case .reinterpret: "重新解释"
        case .manualLink: "手动关联"
        case .derived: "源自"
        }
    }
}

/// 项目处理状态（R-008）：每个项目恰有一个，默认待整理；封存是可逆状态。
public enum ProjectStatus: String, Codable, Sendable, DatabaseValueConvertible, CaseIterable {
    case inbox
    case todo
    case inProgress
    case mostlyDone
    case archived

    public var displayName: String {
        switch self {
        case .inbox: "待整理"
        case .todo: "TODO"
        case .inProgress: "进行中"
        case .mostlyDone: "基本完成"
        case .archived: "暂时封存"
        }
    }

    public var symbolName: String {
        switch self {
        case .inbox: "tray"
        case .todo: "checklist"
        case .inProgress: "hammer"
        case .mostlyDone: "checkmark.seal"
        case .archived: "archivebox"
        }
    }
}
