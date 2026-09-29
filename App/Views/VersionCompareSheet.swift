import SwiftUI
import DraftZeroCore

/// 两个版本的并排对比（R-006"比较两个版本"）。
/// 左旧右新；颜色之外始终有 +/- 文字标识（不单靠颜色）。
struct VersionCompareSheet: View {
    let old: DraftVersion
    let new: DraftVersion

    private var ops: [LineDiff.Op] {
        LineDiff.diff(old.content, new.content)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                Text("版本对比")
                    .font(.archiveSection)
                    .fontDesign(.serif)
                    .foregroundStyle(Color.archiveText)
                Text("\(old.createdAt.formatted(date: .abbreviated, time: .shortened))（\(old.origin.displayName)）  →  \(new.createdAt.formatted(date: .abbreviated, time: .shortened))（\(new.origin.displayName)）")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mutedText)
            }
            .padding(14)

            Divider().overlay(Color.rule)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(ops.enumerated()), id: \.offset) { _, op in
                        diffLine(op)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(Color.rule)
            HStack {
                Label("− 旧版独有（删除/改动前）", systemImage: "minus.square")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accent)
                Spacer()
                Label("+ 新版独有（新增/改动后）", systemImage: "plus.square")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.confirmed)
            }
            .padding(10)
        }
        .frame(width: 720, height: 520)
        .archiveSheet()
    }

    @ViewBuilder
    private func diffLine(_ op: LineDiff.Op) -> some View {
        switch op {
        case .same(let text):
            HStack(alignment: .top, spacing: 6) {
                Text(" ").font(.system(size: 11).monospaced())
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mutedText)
            }
            .padding(.vertical, 1)
        case .removed(let text):
            HStack(alignment: .top, spacing: 6) {
                Text("−").font(.system(size: 11, weight: .bold).monospaced())
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.archiveText)
            }
            .padding(.vertical, 1)
            .padding(.horizontal, 4)
            .background(Color.accent.opacity(0.13))
        case .added(let text):
            HStack(alignment: .top, spacing: 6) {
                Text("+").font(.system(size: 11, weight: .bold).monospaced())
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.archiveText)
            }
            .padding(.vertical, 1)
            .padding(.horizontal, 4)
            .background(Color.confirmed.opacity(0.15))
        }
    }
}
