import Foundation

/// 切片器（SPEC §3"切片与索引"）：按段落与标题切块，保留来源位置；
/// 避免只看开头；超长段落硬切。
public enum Chunker {

    public struct Chunk: Sendable, Equatable {
        public let chunkIndex: Int
        public let text: String
        /// 在原文中的字符偏移，用于证据跳转定位。
        public let startOffset: Int
        /// 所属 Markdown 标题（无则为 nil）；标题比普通正文更影响排序。
        public let heading: String?
    }

    static let maxChunkCharacters = 600
    static let minChunkCharacters = 12

    public static func chunk(_ text: String) -> [Chunk] {
        var paragraphs: [(text: String, offset: Int)] = []
        var searchStart = text.startIndex
        for rawPara in text.split(separator: "\n\n", omittingEmptySubsequences: false) {
            if let paraRange = text.range(of: rawPara, range: searchStart..<text.endIndex) {
                let trimmedText = rawPara.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedText.isEmpty {
                    let offset = text.distance(from: text.startIndex, to: paraRange.lowerBound)
                        + (rawPara.count - rawPara.trimmingCharacters(in: .whitespaces).count) / 2
                    paragraphs.append((trimmedText, max(0, offset)))
                }
                if paraRange.upperBound > searchStart {
                    searchStart = paraRange.upperBound
                }
            } else {
                break
            }
        }

        // 过短段落并入前一段，避免碎屑切片。
        var merged: [(String, Int)] = []
        for para in paragraphs {
            if let last = merged.last, (last.0.count < minChunkCharacters || para.text.count < minChunkCharacters) {
                merged[merged.count - 1] = (last.0 + "\n\n" + para.text, last.1)
            } else {
                merged.append((para.text, para.offset))
            }
        }

        var chunks: [Chunk] = []
        for (paraText, offset) in merged {
            // 超长段落按句号硬切（长 PDF 摘录场景）。
            var remaining = Substring(paraText)
            var pieceOffset = offset
            while remaining.count > maxChunkCharacters {
                let head = remaining.prefix(maxChunkCharacters)
                let cut = head.lastIndex(where: { $0 == "。" || $0 == "." || $0 == "！" || $0 == "?" || $0 == "；" || $0 == ";" })
                    ?? head.lastIndex(of: "\n")
                    ?? head.endIndex
                let piece = String(remaining[remaining.startIndex..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty {
                    chunks.append(makeChunk(piece, offset: pieceOffset, text: text))
                }
                let consumed = remaining.distance(from: remaining.startIndex, to: cut)
                pieceOffset += consumed
                remaining = remaining[cut...]
            }
            let tail = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                chunks.append(makeChunk(tail, offset: pieceOffset, text: text))
            }
        }
        return chunks.enumerated().map { index, chunk in
            Chunk(chunkIndex: index, text: chunk.text, startOffset: chunk.startOffset, heading: chunk.heading)
        }
    }

    private static func makeChunk(_ piece: String, offset: Int, text: String) -> Chunk {
        // 块的"标题"取片段内的首个 Markdown 标题行（若有）。
        var heading: String?
        for line in piece.split(separator: "\n", omittingEmptySubsequences: true) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") {
                heading = String(t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).prefix(60))
                break
            }
        }
        return Chunk(chunkIndex: 0, text: piece, startOffset: offset, heading: heading)
    }
}
