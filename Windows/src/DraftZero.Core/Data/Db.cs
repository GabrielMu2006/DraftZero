using Microsoft.Data.Sqlite;
using System.Globalization;

namespace DraftZero.Core;

/// <summary>行读取与写参的公共小工具。时间统一 ISO-8601 UTC（"o" 格式，字符串序=时间序）。</summary>
public static class Db
{
    public static string Fmt(DateTime t) => t.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture);

    public static DateTime? ParseTime(string? s) =>
        s is null ? null : DateTime.Parse(s, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind).ToUniversalTime();

    public static string Uid(Guid id) => id.ToString().ToUpperInvariant();

    public static Guid Uid(string? s) => Guid.Parse(s!);

    public static SqliteParameter P(string name, object? value) =>
        new(name, value ?? DBNull.Value);

    public static SqliteCommand Cmd(SqliteConnection conn, string sql, params SqliteParameter[] args)
    {
        var cmd = conn.CreateCommand();
        cmd.CommandText = sql;
        foreach (var p in args) cmd.Parameters.Add(p);
        return cmd;
    }

    public static int Exec(SqliteConnection conn, string sql, params SqliteParameter[] args)
    {
        using var cmd = Cmd(conn, sql, args);
        return cmd.ExecuteNonQuery();
    }

    public static object? Scalar(SqliteConnection conn, string sql, params SqliteParameter[] args)
    {
        using var cmd = Cmd(conn, sql, args);
        return cmd.ExecuteScalar();
    }

    public static long? Long(SqliteConnection conn, string sql, params SqliteParameter[] args)
    {
        var v = Scalar(conn, sql, args);
        return v is null or DBNull ? null : Convert.ToInt64(v);
    }

    /// <summary>读取多行到字典，避免直接依赖 reader 生命周期。</summary>
    public static List<Dictionary<string, object?>> ReadRows(SqliteConnection conn, string sql, params SqliteParameter[] args)
    {
        using var cmd = Cmd(conn, sql, args);
        using var reader = cmd.ExecuteReader();
        var rows = new List<Dictionary<string, object?>>();
        while (reader.Read())
        {
            var row = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < reader.FieldCount; i++)
            {
                row[reader.GetName(i)] = reader.IsDBNull(i) ? null : reader.GetValue(i);
            }
            rows.Add(row);
        }
        return rows;
    }

    public static string? Str(Dictionary<string, object?> row, string key) => row.TryGetValue(key, out var v) ? v as string : null;

    public static long Int(Dictionary<string, object?> row, string key) =>
        row.TryGetValue(key, out var v) && v != null ? Convert.ToInt64(v) : 0;

    public static long? IntOrNull(Dictionary<string, object?> row, string key) =>
        row.TryGetValue(key, out var v) && v != null ? Convert.ToInt64(v) : null;

    public static double Dbl(Dictionary<string, object?> row, string key) =>
        row.TryGetValue(key, out var v) && v != null ? Convert.ToDouble(v) : 0;
}

/// <summary>只读行视图。</summary>
public sealed class RowView
{
    private readonly Dictionary<string, object?> _row;
    public RowView(Dictionary<string, object?> row) => _row = row;
    public string? Str(string key) => _row.TryGetValue(key, out var v) ? v as string : null;
    public long Long(string key) => _row.TryGetValue(key, out var v) && v != null ? Convert.ToInt64(v) : 0;
    public long? LongOrNull(string key) => _row.TryGetValue(key, out var v) && v != null ? Convert.ToInt64(v) : null;
    public double Dbl(string key) => _row.TryGetValue(key, out var v) && v != null ? Convert.ToDouble(v) : 0;
}
