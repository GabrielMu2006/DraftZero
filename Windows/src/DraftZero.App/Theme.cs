namespace DraftZero.App;

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
