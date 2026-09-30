using DraftZero.Core;
using Xunit;

namespace DraftZero.Core.Tests;

/// <summary>合同测试：草稿、版本、关系、项目、标签、归属（对齐 Mac StoreTests/ProjectStoreTests/SplitMergeTests）。</summary>
public sealed class StoreTests : IDisposable
{
    private readonly AppDatabase _db;
    private readonly string _root;

    public StoreTests()
    {
        _root = Path.Combine(Path.GetTempPath(), "dz-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_root);
        _db = new AppDatabase(Path.Combine(_root, "dz.sqlite"));
    }

    public void Dispose()
    {
        _db.DisposeAsync().AsTask().GetAwaiter().GetResult();
        try { Directory.Delete(_root, recursive: true); } catch { }
    }

    // S-07：新建草稿；空标题回退
    [Fact]
    public async Task CreateManualDraft_FallsBackToUntitled()
    {
        var draft = await _db.CreateManualDraftAsync("", "正文");
        Assert.Equal("未命名草稿", draft.Title);
        Assert.Equal(SourceType.Manual, draft.SourceType);
        Assert.True(draft.IsEditable);
        var versions = await _db.VersionsAsync(draft.Id);
        Assert.Single(versions);
        Assert.Equal(VersionOrigin.Initial, versions[0].Origin);
    }

    // S-12b：recordVersionIfChanged 无变化不建版本
    [Fact]
    public async Task RecordVersionIfChanged_SkipsWhenUnchanged()
    {
        var draft = await _db.CreateManualDraftAsync("t", "v1");
        await _db.RecordVersionIfChangedAsync(draft.Id, "v1", VersionOrigin.AutoSave);
        Assert.Single(await _db.VersionsAsync(draft.Id));
        await _db.RecordVersionIfChangedAsync(draft.Id, "v2", VersionOrigin.AutoSave);
        Assert.Equal(2, (await _db.VersionsAsync(draft.Id)).Count);
    }

    // S-13b：恢复产生新版本且保留历史
    [Fact]
    public async Task RestoreVersion_CreatesNewVersionAndKeepsHistory()
    {
        var draft = await _db.CreateManualDraftAsync("t", "v1");
        await _db.RecordVersionIfChangedAsync(draft.Id, "v2", VersionOrigin.AutoSave);
        await _db.RecordVersionIfChangedAsync(draft.Id, "v3", VersionOrigin.AutoSave);
        var versions = await _db.VersionsAsync(draft.Id); // desc: v3, v2, v1
        var restored = await _db.RestoreVersionAsync(versions[2].Id);
        Assert.NotNull(restored);
        Assert.Equal("v1", restored!.Content);
        var after = await _db.VersionsAsync(draft.Id);
        Assert.Equal(4, after.Count);
        Assert.Equal("v1", after[0].Content);
        Assert.Equal(VersionOrigin.Restore, after[0].Origin);
        // 中间历史仍在
        Assert.Contains(after, v => v.Content == "v2");
        Assert.Contains(after, v => v.Content == "v3");
    }

    // S-15：拆分
    [Fact]
    public async Task SplitDraft_CreatesRelationAndKeepsSource()
    {
        var source = await _db.CreateManualDraftAsync("源稿", "第一段\n\n第二段内容足够长可以拆分。");
        var split = await _db.SplitDraftAsync(source.Id, "第二段内容足够长可以拆分。", 4, null);
        Assert.NotNull(split);
        Assert.Contains("拆分", split!.Title);
        Assert.Equal("第二段内容足够长可以拆分。", split.Content);
        var sourceAfter = await _db.DraftAsync(source.Id);
        Assert.Equal(source.Content, sourceAfter!.Content);
        var relations = await _db.RelationsAsync(source.Id);
        var relation = Assert.Single(relations);
        Assert.Equal(RelationType.Split, relation.Type);
        Assert.Contains("拆分自第", relation.Note);
    }

    // S-15b：空拆分被拒绝
    [Fact]
    public async Task SplitDraft_RejectsEmptyPiece()
    {
        var source = await _db.CreateManualDraftAsync("源稿", "正文");
        var split = await _db.SplitDraftAsync(source.Id, "   ", 0, null);
        Assert.Null(split);
    }

    // S-16：合并按顺序、来源保留、merge 关系
    [Fact]
    public async Task MergeDrafts_JoinsInOrderAndKeepsSources()
    {
        var a = await _db.CreateManualDraftAsync("甲", "内容甲");
        var b = await _db.CreateManualDraftAsync("乙", "内容乙");
        var merged = await _db.MergeDraftsAsync([a.Id, b.Id], "合并稿");
        Assert.NotNull(merged);
        Assert.Equal("合并稿", merged!.Title);
        Assert.Equal("内容甲\n\n内容乙", merged.Content);
        var versions = await _db.VersionsAsync(merged.Id);
        Assert.Equal(VersionOrigin.Merge, versions[0].Origin);
        var relA = await _db.RelationsAsync(a.Id);
        Assert.Equal(RelationType.Merge, Assert.Single(relA).Type);
        var relB = await _db.RelationsAsync(b.Id);
        Assert.Equal(RelationType.Merge, Assert.Single(relB).Type);
    }

    [Fact]
    public async Task MergeDrafts_RequiresTwo()
    {
        var a = await _db.CreateManualDraftAsync("甲", "内容甲");
        Assert.Null(await _db.MergeDraftsAsync([a.Id], null));
    }

    // S-17：衍生副本
    [Fact]
    public async Task CreateDerivedDraft_KeepsDerivedRelation()
    {
        var source = await _db.CreateManualDraftAsync("快照标题", "快照内容");
        var derived = await _db.CreateDerivedDraftAsync(source.Id, null, "快照内容");
        Assert.NotNull(derived);
        Assert.Equal("快照标题（副本）", derived!.Title);
        Assert.Equal(RelationType.Derived, Assert.Single(await _db.RelationsAsync(source.Id)).Type);
    }

    // S-18：关系说明可改可删
    [Fact]
    public async Task UpdateRelationNote()
    {
        var a = await _db.CreateManualDraftAsync("甲", "内容甲");
        var b = await _db.CreateManualDraftAsync("乙", "内容乙");
        var merged = await _db.MergeDraftsAsync([a.Id, b.Id], null);
        var relation = (await _db.RelationsAsync(a.Id))[0];
        await _db.UpdateRelationNoteAsync(relation.Id, "合并说明");
        Assert.Equal("合并说明", (await _db.RelationsAsync(a.Id))[0].Note);
        await _db.UpdateRelationNoteAsync(relation.Id, null);
        Assert.Null((await _db.RelationsAsync(a.Id))[0].Note);
    }

    // S-19/S-14：项目默认待整理；状态切换
    [Fact]
    public async Task ProjectStatus_Lifecycle()
    {
        var project = await _db.CreateProjectAsync("新项目");
        Assert.Equal(ProjectStatus.Inbox, project.Status);
        await _db.SetProjectStatusAsync(project.Id, ProjectStatus.Todo);
        await _db.SetProjectStatusAsync(project.Id, ProjectStatus.Archived);
        Assert.Equal(ProjectStatus.Archived, (await _db.ProjectAsync(project.Id))!.Status);
        await _db.SetProjectStatusAsync(project.Id, ProjectStatus.MostlyDone);
        Assert.Equal(ProjectStatus.MostlyDone, (await _db.ProjectAsync(project.Id))!.Status);
    }

    // S-22：删项目草稿保留
    [Fact]
    public async Task DeleteProject_KeepsDrafts()
    {
        var draft = await _db.CreateManualDraftAsync("d", "c");
        var p1 = await _db.CreateProjectAsync("p1");
        var p2 = await _db.CreateProjectAsync("p2");
        await _db.AddDraftToProjectAsync(draft.Id, p1.Id);
        await _db.AddDraftToProjectAsync(draft.Id, p2.Id);
        await _db.DeleteProjectAsync(p1.Id);
        var stillIn = await _db.ProjectsContainingAsync(draft.Id);
        Assert.Single(stillIn);
        Assert.Equal("p2", stillIn[0].Name);
        Assert.NotNull(await _db.DraftAsync(draft.Id));
        // 未归组草稿在删项目后回到未归组区（无归属）
        var alone = await _db.CreateManualDraftAsync("alone", "c2");
        var p3 = await _db.CreateProjectAsync("p3");
        await _db.AddDraftToProjectAsync(alone.Id, p3.Id);
        await _db.DeleteProjectAsync(p3.Id);
        Assert.Empty(await _db.ProjectsContainingAsync(alone.Id));
    }

    // S-23：一稿多项目 / 幂等 / 移除不影响其他
    [Fact]
    public async Task Membership_MultiProjectAndIdempotent()
    {
        var draft = await _db.CreateManualDraftAsync("d", "c");
        var p1 = await _db.CreateProjectAsync("p1");
        Assert.True(await _db.AddDraftToProjectAsync(draft.Id, p1.Id));
        Assert.False(await _db.AddDraftToProjectAsync(draft.Id, p1.Id), "重复加入应幂等返回 false");
        Assert.False(await _db.AddDraftToProjectAsync(Guid.NewGuid(), p1.Id), "不存在的草稿返回 false");
        var p2 = await _db.CreateProjectAsync("p2");
        await _db.AddDraftToProjectAsync(draft.Id, p2.Id);
        Assert.Equal(2, (await _db.ProjectCountsByDraftAsync())[draft.Id]);
        Assert.True(await _db.RemoveDraftFromProjectAsync(draft.Id, p1.Id));
        Assert.Single(await _db.ProjectsContainingAsync(draft.Id));
    }

    // S-24：同名标签不重复
    [Fact]
    public async Task Tags_UniqueByName()
    {
        var p = await _db.CreateProjectAsync("p");
        await _db.AddTagToProjectAsync("研究", p.Id);
        await _db.AddTagToProjectAsync("研究", p.Id);
        Assert.Single(await _db.TagsOnProjectAsync(p.Id));
        await _db.RemoveTagFromProjectAsync("研究", p.Id);
        Assert.Empty(await _db.TagsOnProjectAsync(p.Id));
    }

    // S-05b/S-11：删除草稿级联版本与归属、演化关系保留
    [Fact]
    public async Task DeleteDraft_CascadesVersionsButKeepsRelations()
    {
        var a = await _db.CreateManualDraftAsync("甲", "内容甲");
        var b = await _db.CreateManualDraftAsync("乙", "内容乙");
        var merged = await _db.MergeDraftsAsync([a.Id, b.Id], null);
        var p = await _db.CreateProjectAsync("p");
        await _db.AddDraftToProjectAsync(a.Id, p.Id);
        await _db.DeleteDraftAsync(a.Id);
        Assert.Null(await _db.DraftAsync(a.Id));
        Assert.Empty(await _db.VersionsAsync(a.Id));
        Assert.Empty(await _db.ProjectsContainingAsync(a.Id));
        // b 的合并关系行保留（b → 合并稿）；对已删除的 a，界面显示"来源已删除"
        var relations = await _db.RelationsAsync(b.Id);
        var mergeRelation = Assert.Single(relations);
        Assert.Equal(RelationType.Merge, mergeRelation.Type);
        Assert.Equal(b.Id, mergeRelation.SourceDraftId);
        Assert.False(await _db.DraftExistsAsync(a.Id), "草稿 a 应已删除");
        Assert.True(await _db.DraftExistsAsync(mergeRelation.TargetDraftId), "合并稿仍在");
    }

    // 指纹算式：与 Mac CharacterSet.alphanumerics + lowercase + SHA-256 对齐
    [Theory]
    [InlineData("Hello, World!", "helloworld")]
    [InlineData("标题：测试——内容。", "标题测试内容")]
    public void Fingerprint_NormalizesAsMac(string input, string expectedNormalized)
    {
        Assert.Equal(TextReading.Fingerprint(expectedNormalized), TextReading.Fingerprint(input));
    }

    // S-33：默认工作区路径与 DZ_WORKSPACE_DIR 覆盖
    [Fact]
    public void WorkspaceOverride_UsesEnvironmentVariable()
    {
        var tmp = Path.Combine(Path.GetTempPath(), "dz-override-" + Guid.NewGuid().ToString("N"));
        try
        {
            Environment.SetEnvironmentVariable("DZ_WORKSPACE_DIR", tmp);
            var (dbPath, snapshots) = AppDatabase.DefaultWorkspace();
            Assert.Equal(Path.Combine(tmp, "DraftZero.sqlite"), dbPath);
            Assert.Equal(Path.Combine(tmp, "snapshots"), snapshots);
        }
        finally
        {
            Environment.SetEnvironmentVariable("DZ_WORKSPACE_DIR", null);
            try { Directory.Delete(tmp, recursive: true); } catch { }
        }
    }
}
