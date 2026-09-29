import Foundation

/// 行级文本差异（版本对比，R-006）。LCS 动态规划；超长文本退化为整段替换，
/// 提示用户用拆分查看局部。
public enum LineDiff {

    public enum Op: Equatable, Sendable {
        case same(String)
        case added(String)    // 新版本独有
        case removed(String)  // 旧版本独有
    }

    static let maxDiffLines = 2000

    public static func diff(_ oldText: String, _ newText: String) -> [Op] {
        var old = oldText.components(separatedBy: .newlines)
        var new = newText.components(separatedBy: .newlines)
        let capped = old.count > maxDiffLines || new.count > maxDiffLines
        if capped {
            // 超长降级：不丢内容，只标明整体替换。
            return old.map { .removed($0) } + new.map { .added($0) }
        }

        let n = old.count, m = new.count
        // LCS 长度表（UInt16 足够，2000×2000 ≈ 8MB）。
        var table = [[UInt16]](repeating: [UInt16](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var ops: [Op] = []
        ops.reserveCapacity(n + m)
        var i = 0, j = 0
        while i < n && j < m {
            if old[i] == new[j] {
                ops.append(.same(old[i])); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                ops.append(.removed(old[i])); i += 1
            } else {
                ops.append(.added(new[j])); j += 1
            }
        }
        while i < n { ops.append(.removed(old[i])); i += 1 }
        while j < m { ops.append(.added(new[j])); j += 1 }
        return ops
    }

    public static func hasChanges(_ ops: [Op]) -> Bool {
        ops.contains { if case .same = $0 { return false } else { return true } }
    }
}
