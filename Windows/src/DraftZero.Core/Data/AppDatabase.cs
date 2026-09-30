using Microsoft.Data.Sqlite;

namespace DraftZero.Core;

/// <summary>
/// Windows 本机工作区数据库（R-011 / 计划 §4 W-005）。
/// Windows 自有迁移与类型映射；不打开 Mac 端 SQLite 文件。表与字段语义对齐
/// Mac AppDatabase 迁移 v1–v4（见 V0.2.0-P001-BASELINE-FREEZE.md §1）。
/// </summary>
public sealed class AppDatabase : IAsyncDisposable
{
    private readonly SqliteConnection _writeConnection;
    private readonly SemaphoreSlim _writeLock = new(1, 1);

    public string DatabasePath { get; }
    public string WorkspaceDirectory { get; }
    public string SnapshotsDirectory { get; }

    public AppDatabase(string databasePath, string? snapshotsDirectory = null)
    {
        DatabasePath = Path.GetFullPath(databasePath);
        WorkspaceDirectory = Path.GetDirectoryName(DatabasePath)!;
        SnapshotsDirectory = snapshotsDirectory
            ?? Path.Combine(WorkspaceDirectory, "snapshots");
        Directory.CreateDirectory(WorkspaceDirectory);
        Directory.CreateDirectory(SnapshotsDirectory);

        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = DatabasePath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Private,
            Pooling = false,
        };
        _writeConnection = new SqliteConnection(builder.ToString());
        _writeConnection.Open();
        Execute("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;");
        Migrate();
    }

    /// <summary>默认数据目录：%LocalAppData%\DraftZero（W-009）。
    /// DZ_WORKSPACE_DIR 环境变量覆盖（QA 隔离，与 Mac 语义一致）。</summary>
    public static (string DatabasePath, string SnapshotsDirectory) DefaultWorkspace()
    {
        var overrideDir = Environment.GetEnvironmentVariable("DZ_WORKSPACE_DIR");
        string dir;
        if (!string.IsNullOrWhiteSpace(overrideDir))
        {
            dir = Path.GetFullPath(overrideDir);
        }
        else
        {
            var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            dir = Path.Combine(localAppData, "DraftZero");
        }
        Directory.CreateDirectory(dir);
        Directory.CreateDirectory(Path.Combine(dir, "snapshots"));
        return (Path.Combine(dir, "DraftZero.sqlite"), Path.Combine(dir, "snapshots"));
    }

    // ---- 底层访问 ----

    public SqliteConnection OpenReadConnection()
    {
        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = DatabasePath,
            Mode = SqliteOpenMode.ReadOnly,
            Pooling = false,
        };
        var conn = new SqliteConnection(builder.ToString());
        conn.Open();
        return conn;
    }

    /// <summary>串行化的写连接（WAL 允许并发读；写入单线程避免 SQLITE_BUSY）。</summary>
    public async Task<T> WriteAsync<T>(Func<SqliteConnection, Task<T>> body)
    {
        await _writeLock.WaitAsync().ConfigureAwait(false);
        try
        {
            return await body(_writeConnection).ConfigureAwait(false);
        }
        finally
        {
            _writeLock.Release();
        }
    }

    public Task WriteAsync(Func<SqliteConnection, Task> body) =>
        WriteAsync<object?>(async conn => { await body(conn).ConfigureAwait(false); return null; });

    public int Execute(string sql) => Execute(_writeConnection, sql);

    internal static int Execute(SqliteConnection conn, string sql)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = sql;
        return cmd.ExecuteNonQuery();
    }

    public async ValueTask DisposeAsync()
    {
        await _writeLock.WaitAsync().ConfigureAwait(false);
        try
        {
            await _writeConnection.DisposeAsync().ConfigureAwait(false);
        }
        finally
        {
            _writeLock.Release();
        }
    }

    // ---- 迁移（Windows v1：全新库一次成型；升级用后续 vN 追加） ----

    private void Migrate()
    {
        Execute(_writeConnection, """
            CREATE TABLE IF NOT EXISTS schemaMeta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """);
        var version = QueryScalar<string>(_writeConnection, "SELECT value FROM schemaMeta WHERE key='version'");
        if (version is null)
        {
            var draftCount = QueryScalar<long>(_writeConnection, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='draft'");
            if (draftCount > 0)
            {
                throw new InvalidOperationException("工作区数据库缺少版本标记，为避免损坏不予打开；请先用应用支持的方式迁移。");
            }
            Execute(_writeConnection, "INSERT INTO schemaMeta(key,value) VALUES('version','1')");
        }

        Execute(_writeConnection, """
            CREATE TABLE IF NOT EXISTS draft (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                content TEXT,
                isEditable INTEGER NOT NULL DEFAULT 1,
                hasExtractableText INTEGER NOT NULL DEFAULT 1,
                sourceType TEXT NOT NULL,
                sourceLocation TEXT,
                sourceLabel TEXT,
                snapshotFileURL TEXT,
                fingerprint TEXT,
                sourceVersionSha TEXT,
                importedAt TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_draft_fingerprint ON draft(fingerprint);
            CREATE TABLE IF NOT EXISTS draftVersion (
                id TEXT PRIMARY KEY,
                draftId TEXT NOT NULL REFERENCES draft(id) ON DELETE CASCADE,
                content TEXT NOT NULL,
                origin TEXT NOT NULL,
                createdAt TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_draftVersion_draftId ON draftVersion(draftId);
            CREATE TABLE IF NOT EXISTS evolutionRelation (
                id TEXT PRIMARY KEY,
                sourceDraftId TEXT NOT NULL,
                targetDraftId TEXT NOT NULL,
                type TEXT NOT NULL,
                note TEXT,
                createdAt TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_evolution_source ON evolutionRelation(sourceDraftId);
            CREATE INDEX IF NOT EXISTS idx_evolution_target ON evolutionRelation(targetDraftId);
            CREATE TABLE IF NOT EXISTS project (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                notes TEXT,
                status TEXT NOT NULL DEFAULT 'inbox',
                createdAt TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS tag (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL UNIQUE
            );
            CREATE TABLE IF NOT EXISTS projectTag (
                projectId TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                tagId TEXT NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
                PRIMARY KEY (projectId, tagId)
            );
            CREATE TABLE IF NOT EXISTS projectDraft (
                projectId TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                draftId TEXT NOT NULL REFERENCES draft(id) ON DELETE CASCADE,
                PRIMARY KEY (projectId, draftId)
            );
            CREATE INDEX IF NOT EXISTS idx_projectDraft_draftId ON projectDraft(draftId);
            CREATE TABLE IF NOT EXISTS indexChunk (
                draftId TEXT NOT NULL REFERENCES draft(id) ON DELETE CASCADE,
                chunkIndex INTEGER NOT NULL,
                text TEXT NOT NULL,
                startOffset INTEGER NOT NULL,
                heading TEXT,
                embedding BLOB NOT NULL,
                PRIMARY KEY (draftId, chunkIndex)
            );
            CREATE TABLE IF NOT EXISTS indexStatus (
                draftId TEXT PRIMARY KEY REFERENCES draft(id) ON DELETE CASCADE,
                fingerprint TEXT NOT NULL,
                indexedAt TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS candidatePair (
                id TEXT PRIMARY KEY,
                draftA TEXT NOT NULL REFERENCES draft(id) ON DELETE CASCADE,
                draftB TEXT NOT NULL REFERENCES draft(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                score REAL NOT NULL,
                evidence TEXT,
                status TEXT NOT NULL,
                fingerprintA TEXT,
                fingerprintB TEXT,
                lastDecision TEXT,
                createdAt TEXT NOT NULL,
                decidedAt TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_candidatePair_status ON candidatePair(status);
            CREATE TABLE IF NOT EXISTS remoteSuggestion (
                id TEXT PRIMARY KEY,
                provider TEXT NOT NULL,
                model TEXT,
                draftIdsData TEXT,
                explanation TEXT,
                citationsData TEXT,
                notice TEXT,
                createdAt TEXT NOT NULL,
                dismissed INTEGER NOT NULL DEFAULT 0
            );
            """);

        // 草稿全文搜索索引（FTS5 trigram，可重建数据）；计数不一致自动重建
        // ——顺带自愈旧库与导入遗留（W-007）。
        DraftSearchStore.EnsureSchemaAndConsistency(_writeConnection);
    }

    // ---- 小工具 ----

    public static T? QueryScalar<T>(SqliteConnection conn, string sql, params (string, object?)[] args)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = sql;
        foreach (var (name, value) in args)
        {
            cmd.Parameters.AddWithValue(name, value ?? DBNull.Value);
        }
        var result = cmd.ExecuteScalar();
        if (result is null || result is DBNull) return default;
        return (T)Convert.ChangeType(result, typeof(T).IsEnum ? typeof(object) : typeof(T)) is T typed
            ? typed : default;
    }

    public static long? QueryLong(SqliteConnection conn, string sql, params (string, object?)[] args)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = sql;
        foreach (var (name, value) in args) cmd.Parameters.AddWithValue(name, value ?? DBNull.Value);
        var result = cmd.ExecuteScalar();
        if (result is null or DBNull) return null;
        return Convert.ToInt64(result);
    }
}
