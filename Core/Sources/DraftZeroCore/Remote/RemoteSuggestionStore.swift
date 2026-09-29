import Foundation
import GRDB

/// 远程建议的存取（R-010）。建议不创建任何已确认关系。
extension AppDatabase {

    public func saveRemoteSuggestion(_ suggestion: RemoteSuggestion) async throws {
        try await pool.write { db in
            try suggestion.insert(db)
        }
    }

    public func pendingRemoteSuggestions(provider: String? = nil) async throws -> [RemoteSuggestion] {
        try await pool.read { db in
            var request = RemoteSuggestion.filter(Column("dismissed") == false)
            if let provider {
                request = request.filter(Column("provider") == provider)
            }
            return try request.order(Column("createdAt").desc).fetchAll(db)
        }
    }

    public func dismissRemoteSuggestion(id: UUID) async throws {
        try await pool.write { db in
            guard var row = try RemoteSuggestion.fetchOne(db, key: id) else { return }
            row.dismissed = true
            try row.update(db)
        }
    }
}
