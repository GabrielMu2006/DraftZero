import XCTest
@testable import DraftZeroCore

/// R-006 验收：静默 60 秒（可注入）后生成版本；离开草稿立即结算；无变化不建版本。
final class AutoVersionerTests: XCTestCase {

    private actor Collector {
        var entries: [(UUID, String)] = []
        func record(_ id: UUID, _ text: String) {
            entries.append((id, text))
        }
    }

    func testIdleDebounceRecordsOneVersionPerPause() async throws {
        let collector = Collector()
        let versioner = AutoVersioner(idleInterval: 0.05) { id, text in
            await collector.record(id, text)
        }
        let draftId = UUID()

        await versioner.contentChanged(draftId: draftId, text: "第一段")
        try await Task.sleep(for: .seconds(0.01))
        await versioner.contentChanged(draftId: draftId, text: "第一段，继续打字")
        try await Task.sleep(for: .seconds(0.2)) // 连续输入期间只有最后一次生效

        let entries = await collector.entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.1, "第一段，继续打字")
    }

    func testFlushRecordsImmediately() async throws {
        let collector = Collector()
        let versioner = AutoVersioner(idleInterval: 60) { id, text in
            await collector.record(id, text)
        }
        let draftId = UUID()
        await versioner.contentChanged(draftId: draftId, text: "离开前的内容")
        await versioner.flush(draftId: draftId) // 离开草稿立即结算

        let entries = await collector.entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.1, "离开前的内容")
    }

    func testFlushAllRecordsEveryPendingDraft() async throws {
        let collector = Collector()
        let versioner = AutoVersioner(idleInterval: 60) { id, text in
            await collector.record(id, text)
        }
        let a = UUID(), b = UUID()
        await versioner.contentChanged(draftId: a, text: "A")
        await versioner.contentChanged(draftId: b, text: "B")
        await versioner.flushAll() // 关闭窗口

        let entries = await collector.entries
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.1)), Set(["A", "B"]))
    }

    func testEndToEndWithDatabase() async throws {
        let db = try TestSupport.makeDatabase()
        let draft = try await db.createManualDraft(title: "t", content: "v1")

        let versioner = AutoVersioner(idleInterval: 0.05) { [db] id, text in
            try? await db.recordVersionIfChanged(draftId: id, content: text, origin: .autoSave)
        }
        await versioner.contentChanged(draftId: draft.id, text: "v2")
        try await Task.sleep(for: .seconds(0.2))

        let versions = try await db.versions(draftId: draft.id)
        XCTAssertEqual(versions.count, 2)
        XCTAssertEqual(versions.first?.content, "v2")
        XCTAssertEqual(versions.first?.origin, .autoSave)

        // 相同内容再次触发不产生重复版本（R-006）
        await versioner.contentChanged(draftId: draft.id, text: "v2")
        await versioner.flush(draftId: draft.id)
        let after = try await db.versions(draftId: draft.id)
        XCTAssertEqual(after.count, 2)
    }
}
