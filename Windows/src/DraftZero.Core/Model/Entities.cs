using System.Text.Json.Serialization;

namespace DraftZero.Core;

/// <summary>来源类型决定草稿是否可编辑（R-003）。字符串值与 Mac 端数据库一致。</summary>
public enum SourceType
{
    Manual,
    LocalFile,
    Pdf,
    Web,
    GitHubFile,
    Derived,
}

public static class SourceTypeExtensions
{
    public static string DbValue(this SourceType t) => t switch
    {
        SourceType.Manual => "manual",
        SourceType.LocalFile => "local_file",
        SourceType.Pdf => "pdf",
        SourceType.Web => "web",
        SourceType.GitHubFile => "github_file",
        SourceType.Derived => "derived",
        _ => throw new ArgumentOutOfRangeException(nameof(t)),
    };

    public static SourceType FromDb(string value) => value switch
    {
        "manual" => SourceType.Manual,
        "local_file" => SourceType.LocalFile,
        "pdf" => SourceType.Pdf,
        "web" => SourceType.Web,
        "github_file" => SourceType.GitHubFile,
        "derived" => SourceType.Derived,
        _ => throw new FormatException($"未知来源类型：{value}"),
    };

    public static string DisplayName(this SourceType t) => t switch
    {
        SourceType.Manual => "应用内新建",
        SourceType.LocalFile => "本地文件",
        SourceType.Pdf => "PDF 快照",
        SourceType.Web => "网页快照",
        SourceType.GitHubFile => "GitHub 快照",
        SourceType.Derived => "衍生草稿",
        _ => "",
    };

    public static bool IsEditableByDefault(this SourceType t) =>
        t is SourceType.Manual or SourceType.LocalFile or SourceType.Derived;
}

/// <summary>版本来源（R-006）。字符串值与 Mac 端一致。</summary>
public enum VersionOrigin
{
    Initial,
    AutoSave,
    Manual,
    Restore,
    Split,
    Merge,
}

public static class VersionOriginExtensions
{
    public static string DbValue(this VersionOrigin o) => o switch
    {
        VersionOrigin.Initial => "initial",
        VersionOrigin.AutoSave => "auto_save",
        VersionOrigin.Manual => "manual",
        VersionOrigin.Restore => "restore",
        VersionOrigin.Split => "split",
        VersionOrigin.Merge => "merge",
        _ => throw new ArgumentOutOfRangeException(nameof(o)),
    };

    public static VersionOrigin FromDb(string value) => value switch
    {
        "initial" => VersionOrigin.Initial,
        "auto_save" => VersionOrigin.AutoSave,
        "manual" => VersionOrigin.Manual,
        "restore" => VersionOrigin.Restore,
        "split" => VersionOrigin.Split,
        "merge" => VersionOrigin.Merge,
        _ => throw new FormatException($"未知版本来源：{value}"),
    };

    public static string DisplayName(this VersionOrigin o) => o switch
    {
        VersionOrigin.Initial => "初始版本",
        VersionOrigin.AutoSave => "自动保存",
        VersionOrigin.Manual => "手动保存",
        VersionOrigin.Restore => "恢复旧版",
        VersionOrigin.Split => "拆分",
        VersionOrigin.Merge => "合并",
        _ => "",
    };
}

/// <summary>演化关系类型（R-007）。</summary>
public enum RelationType
{
    Split,
    Merge,
    Reinterpret,
    ManualLink,
    Derived,
}

public static class RelationTypeExtensions
{
    public static string DbValue(this RelationType t) => t switch
    {
        RelationType.Split => "split",
        RelationType.Merge => "merge",
        RelationType.Reinterpret => "reinterpret",
        RelationType.ManualLink => "manual_link",
        RelationType.Derived => "derived",
        _ => throw new ArgumentOutOfRangeException(nameof(t)),
    };

    public static RelationType FromDb(string value) => value switch
    {
        "split" => RelationType.Split,
        "merge" => RelationType.Merge,
        "reinterpret" => RelationType.Reinterpret,
        "manual_link" => RelationType.ManualLink,
        "derived" => RelationType.Derived,
        _ => throw new FormatException($"未知关系类型：{value}"),
    };

    public static string DisplayName(this RelationType t) => t switch
    {
        RelationType.Split => "拆分",
        RelationType.Merge => "合并",
        RelationType.Reinterpret => "重新解释",
        RelationType.ManualLink => "手动关联",
        RelationType.Derived => "源自",
        _ => "",
    };
}

/// <summary>项目处理状态（R-008）：每项目恰一个，默认待整理；封存可逆。</summary>
public enum ProjectStatus
{
    Inbox,
    Todo,
    InProgress,
    MostlyDone,
    Archived,
}

public static class ProjectStatusExtensions
{
    public static string DbValue(this ProjectStatus s) => s switch
    {
        ProjectStatus.Inbox => "inbox",
        ProjectStatus.Todo => "todo",
        ProjectStatus.InProgress => "inProgress",
        ProjectStatus.MostlyDone => "mostlyDone",
        ProjectStatus.Archived => "archived",
        _ => throw new ArgumentOutOfRangeException(nameof(s)),
    };

    public static ProjectStatus FromDb(string value) => value switch
    {
        "inbox" => ProjectStatus.Inbox,
        "todo" => ProjectStatus.Todo,
        "inProgress" => ProjectStatus.InProgress,
        "mostlyDone" => ProjectStatus.MostlyDone,
        "archived" => ProjectStatus.Archived,
        _ => throw new FormatException($"未知项目状态：{value}"),
    };

    public static string DisplayName(this ProjectStatus s) => s switch
    {
        ProjectStatus.Inbox => "待整理",
        ProjectStatus.Todo => "TODO",
        ProjectStatus.InProgress => "进行中",
        ProjectStatus.MostlyDone => "基本完成",
        ProjectStatus.Archived => "暂时封存",
        _ => "",
    };
}

/// <summary>草稿：应用内文本副本或只读来源快照（SPEC §5）。</summary>
public class Draft
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Title { get; set; } = "";
    /// <summary>应用内正文；扫描版 PDF 为 null。</summary>
    public string? Content { get; set; }
    public bool IsEditable { get; set; } = true;
    /// <summary>扫描版 PDF 为 false，界面须显示"无可用于关联的文字"。</summary>
    public bool HasExtractableText { get; set; } = true;
    public SourceType SourceType { get; set; }
    /// <summary>原路径或 URL；应用内新建草稿为 null。</summary>
    public string? SourceLocation { get; set; }
    /// <summary>界面展示的来源名（文件名/域名/仓库路径）。</summary>
    public string? SourceLabel { get; set; }
    /// <summary>二进制快照在 Windows 工作区内的绝对路径。</summary>
    public string? SnapshotFileURL { get; set; }
    /// <summary>归一化正文 SHA-256，用于重复来源提示（不作为归组依据）。</summary>
    public string? Fingerprint { get; set; }
    /// <summary>外部快照所读版本的标识：GitHub 为 tree/commit SHA（R-002）。</summary>
    public string? SourceVersionSha { get; set; }
    public DateTime ImportedAt { get; set; } = DateTime.UtcNow;
}

/// <summary>文本版本（R-006）。恢复旧版产生 origin=Restore 的新版本，历史不删除。</summary>
public class DraftVersion
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid DraftId { get; set; }
    public string Content { get; set; } = "";
    public VersionOrigin Origin { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
}

/// <summary>演化关系（R-007）。来源草稿被删除后本行保留，界面显示"来源已删除"。</summary>
public class EvolutionRelation
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Guid SourceDraftId { get; set; }
    public Guid TargetDraftId { get; set; }
    public RelationType Type { get; set; }
    /// <summary>"重新解释"等关系的短说明，可修改或移除（R-007）。</summary>
    public string? Note { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
}

/// <summary>想法项目（R-005/R-008）。删除项目不删除草稿。</summary>
public class Project
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public string? Notes { get; set; }
    public ProjectStatus Status { get; set; } = ProjectStatus.Inbox;
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
}

/// <summary>自由主题标签（R-008），名称唯一。</summary>
public class Tag
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
}

public class ProjectTag
{
    public Guid ProjectId { get; set; }
    public Guid TagId { get; set; }
}

/// <summary>草稿与项目的多对多归属（R-005）。</summary>
public class ProjectDraft
{
    public Guid ProjectId { get; set; }
    public Guid DraftId { get; set; }
}
