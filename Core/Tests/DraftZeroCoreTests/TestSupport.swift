import XCTest
import AppKit
import GRDB
@testable import DraftZeroCore

/// 测试共享工具：临时工作区与带文字的 PDF 生成。
enum TestSupport {

    static func makeWorkspace() throws -> (root: URL, snapshots: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DraftZeroTests-\(UUID().uuidString)", isDirectory: true)
        let snapshots = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        return (root, snapshots)
    }

    static func makeDatabase() throws -> AppDatabase {
        try AppDatabase(pool: DatabaseQueue())
    }

    static func write(_ text: String, name: String, in dir: URL, encoding: String.Encoding = .utf8) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.data(using: encoding)?.write(to: url)
        return url
    }

    /// 用 CoreText 生成含真实文字运行的 PDF（PDFKit 可提取）；text 为 nil 时生成空白页。
    static func makePDF(name: String, in dir: URL, text: String?) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "TestPDF", code: 1)
        }
        context.beginPDFPage(nil)
        if let text {
            let attributed = NSAttributedString(
                string: text,
                attributes: [.font: NSFont.systemFont(ofSize: 14)])
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let path = CGPath(rect: mediaBox.insetBy(dx: 50, dy: 50), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, context)
        }
        context.endPDFPage()
        context.closePDF()
        return url
    }
}
