using Avalonia.Media;

namespace DraftZero.App;

/// <summary>
/// 「索引档案」语义色（UI-REDESIGN-PLAN §3.1 浅色基准 + 夜间档案同构色板）。
/// 浅石灰/柔纸/深墨/索引棕；禁散布十六进制散值，全部经此令牌。
/// </summary>
public static class Theme
{
    // 浅色（概念图基准）
    public static readonly Color CanvasLight = Color.Parse("#D9D6CC");
    public static readonly Color SurfaceLight = Color.Parse("#F1F0E9");
    public static readonly Color RailLight = Color.Parse("#E7E6DC");
    public static readonly Color RaisedLight = Color.Parse("#FAFAF6");
    public static readonly Color SelectedLight = Color.Parse("#D3D9CC");
    public static readonly Color TextLight = Color.Parse("#282B27");
    public static readonly Color MutedTextLight = Color.Parse("#666B65");
    public static readonly Color RuleLight = Color.Parse("#C8C8BE");
    public static readonly Color AccentLight = Color.Parse("#80602D");
    public static readonly Color ConfirmedLight = Color.Parse("#426C55");
    public static readonly Color RemoteLight = Color.Parse("#6F5A83");
    public static readonly Color DangerLight = Color.Parse("#A5483B");

    // 深色（夜间档案）
    public static readonly Color CanvasDark = Color.Parse("#242C2A");
    public static readonly Color SurfaceDark = Color.Parse("#303A34");
    public static readonly Color RailDark = Color.Parse("#29332D");
    public static readonly Color RaisedDark = Color.Parse("#39463E");
    public static readonly Color SelectedDark = Color.Parse("#435344");
    public static readonly Color TextDark = Color.Parse("#EFF0E7");
    public static readonly Color MutedTextDark = Color.Parse("#C3CCC2");
    public static readonly Color RuleDark = Color.Parse("#59665C");
    public static readonly Color AccentDark = Color.Parse("#E1C993");
    public static readonly Color ConfirmedDark = Color.Parse("#A9D1B1");
    public static readonly Color RemoteDark = Color.Parse("#CFBCE0");
    public static readonly Color DangerDark = Color.Parse("#F0A89E");
}

/// <summary>应用层枚举：导航项与页面路由（对齐 Mac SidebarItem）。</summary>
public enum SidebarItem
{
    DraftBox,    // 01 草稿箱
    ClueDesk,    // 02 线索台
    Projects,    // 03 想法项目
    Todo,        // 04 TODO
    Archived,    // 05 暂时封存
    Settings,    // 底部设置
}

/// <summary>草稿箱筛选（视图状态，不写入数据模型）。</summary>
public enum DraftBoxFilter
{
    All,            // 全部
    Ungrouped,      // 未归组
    RecentlyEdited, // 最近编辑
    Snapshots,      // 来源快照
}

public static class SidebarItemExtensions
{
    public static string DisplayName(this SidebarItem item) => item switch
    {
        SidebarItem.DraftBox => "草稿箱",
        SidebarItem.ClueDesk => "线索台",
        SidebarItem.Projects => "想法项目",
        SidebarItem.Todo => "TODO",
        SidebarItem.Archived => "暂时封存",
        SidebarItem.Settings => "设置",
        _ => "",
    };

    public static string IndexNumber(this SidebarItem item) => item switch
    {
        SidebarItem.DraftBox => "01",
        SidebarItem.ClueDesk => "02",
        SidebarItem.Projects => "03",
        SidebarItem.Todo => "04",
        SidebarItem.Archived => "05",
        SidebarItem.Settings => "06",
        _ => "",
    };
}

public static class DraftBoxFilterExtensions
{
    public static string DisplayName(this DraftBoxFilter f) => f switch
    {
        DraftBoxFilter.All => "全部",
        DraftBoxFilter.Ungrouped => "未归组",
        DraftBoxFilter.RecentlyEdited => "最近编辑",
        DraftBoxFilter.Snapshots => "来源快照",
        _ => "",
    };
}
