import Foundation
import CryptoKit

/// .dzarchive 读取与校验（D-002 双向迁移）：Mac 端导入 Windows 导出的工作区档案。
/// 解压经系统 `ditto`（-x -k 支持 deflate 与 store），无需第三方依赖；
/// 条目名先经 `unzip -Z1` 校验（拒绝绝对路径/越级/重复）再解压。
/// 校验规则与 Windows 端 DzArchiveReader 一致（manifest SHA、引用完整性、计数对账）。
public enum DzArchiveReader {

    enum DzArchiveError: LocalizedError {
        case notFound
        case notAZip
        case entryCountExceeded(Int)
        case totalSizeExceeded
        case illegalPath(String)
        case duplicatePath(String)
        case missingManifest
        case badManifest(String)
        case unsupportedVersion(Int)
        case missingDataFile(String)
        case checksumFailed(String)
        case missingSnapshot(String)
        case badReference(String)
        case countMismatch(String)
        case decompressFailed(String)

        var errorDescription: String? {
            switch self {
            case .notFound: "找不到迁移档案文件"
            case .notAZip: "不是有效的 ZIP 档案"
            case .entryCountExceeded(let n): "档案条目数超过上限（>\(n)）"
            case .totalSizeExceeded: "档案解压总量超过上限"
            case .illegalPath(let p): "档案包含非法路径：\(p)"
            case .duplicatePath(let p): "档案包含重复路径：\(p)"
            case .missingManifest: "档案缺少 manifest.json"
            case .badManifest(let why): "manifest.json 无法解析：\(why)"
            case .unsupportedVersion(let v): "档案格式版本不受支持：\(v)"
            case .missingDataFile(let p): "档案缺少数据文件：\(p)"
            case .checksumFailed(let p): "文件校验失败（SHA-256 不符）：\(p)"
            case .missingSnapshot(let p): "草稿引用的 PDF 快照缺失：\(p)"
            case .badReference(let why): why
            case .countMismatch(let what): "manifest 记录数与实际数据不一致（\(what)）"
            case .decompressFailed(let why): "档案解压失败：\(why)"
            }
        }
    }

    struct Contents {
        public let manifest: DzArchiveExporter.Manifest
        public let drafts: [DzArchiveExporter.ArchiveDraft]
        public let versions: [DzArchiveExporter.ArchiveVersion]
        public let relations: [DzArchiveExporter.ArchiveRelation]
        public let projects: [DzArchiveExporter.ArchiveProject]
        public let tags: DzArchiveExporter.ArchiveTags
        public let memberships: [DzArchiveExporter.ArchiveMembership]
        public let decisions: [DzArchiveExporter.ArchiveCandidateDecision]
        public let suggestions: [DzArchiveExporter.ArchiveRemoteSuggestion]
        /// entryPath → 已提取的文件 URL（临时目录内）
        public let pdfFiles: [String: URL]
        public let extractedDirectory: URL
    }

    // ---- 对外入口 ----

    static func read(archivePath: String) throws -> Contents {
        guard FileManager.default.fileExists(atPath: archivePath) else {
            throw DzArchiveError.notFound
        }
        // 解压目录由调用方负责清理（Contents.extractedDirectory）：
        // 导入器需要其中的 PDF 文件，read() 返回后仍需存活。
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dz-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // 1. 条目名预检（unzip -Z1 仅列名，不解压）
        let names = try listEntryNames(archivePath: archivePath)
        guard names.count <= 20_000 else { throw DzArchiveError.entryCountExceeded(20_000) }
        var seen = Set<String>()
        for name in names {
            if name.hasPrefix("/") || name.contains(":") || name.split(separator: "/").contains("..") {
                throw DzArchiveError.illegalPath(name)
            }
            if name.hasSuffix("/") { continue }
            if !seen.insert(name).inserted {
                throw DzArchiveError.duplicatePath(name)
            }
        }

        // 2. 解压（ditto -x -k）
        try run("/usr/bin/ditto", ["-x", "-k", archivePath, tmp.path])

        // 3. 只允许预期路径（防解压逃逸类异常档案）
        let allFiles = try allRelativeFiles(in: tmp)
        for f in allFiles where !seen.contains(f) {
            throw DzArchiveError.illegalPath(f)
        }
        guard allFiles.count <= 20_000 else { throw DzArchiveError.entryCountExceeded(20_000) }

        // 4. manifest
        let manifestURL = tmp.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw DzArchiveError.missingManifest
        }
        let manifest: DzArchiveExporter.Manifest
        do {
            manifest = try JSONDecoder().decode(DzArchiveExporter.Manifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw DzArchiveError.badManifest(error.localizedDescription)
        }
        guard manifest.formatVersion == 1 else {
            throw DzArchiveError.unsupportedVersion(manifest.formatVersion)
        }

        // 5. 逐文件 SHA-256 + 大小
        var total = 0
        for file in manifest.files {
            let url = tmp.appendingPathComponent(file.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw DzArchiveError.missingDataFile(file.path)
            }
            let data = try Data(contentsOf: url)
            total += data.count
            if total > 4 * 1024 * 1024 * 1024 { throw DzArchiveError.totalSizeExceeded }
            guard data.count == file.sizeBytes,
                  DzArchiveExporter.sha256Hex(data) == file.sha256 else {
                throw DzArchiveError.checksumFailed(file.path)
            }
        }

        // 6. 数据文件
        func readData<T: Decodable>(_ type: T.Type, _ path: String) throws -> T {
            let url = tmp.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw DzArchiveError.missingDataFile(path)
            }
            do {
                return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
            } catch {
                throw DzArchiveError.badManifest("\(path)：\(error.localizedDescription)")
            }
        }
        let drafts = try readData([DzArchiveExporter.ArchiveDraft].self, "data/drafts.json")
        let versions = try readData([DzArchiveExporter.ArchiveVersion].self, "data/versions.json")
        let relations = try readData([DzArchiveExporter.ArchiveRelation].self, "data/relations.json")
        let projects = try readData([DzArchiveExporter.ArchiveProject].self, "data/projects.json")
        let tags = try readData(DzArchiveExporter.ArchiveTags.self, "data/tags.json")
        let memberships = try readData([DzArchiveExporter.ArchiveMembership].self, "data/memberships.json")
        let decisions = try readData([DzArchiveExporter.ArchiveCandidateDecision].self, "data/candidates.json")
        let suggestions = try readData([DzArchiveExporter.ArchiveRemoteSuggestion].self, "data/remoteSuggestions.json")

        // 7. 引用完整性（与 Windows 端 DzArchiveReader 同规则）
        try validate(drafts: drafts, versions: versions, relations: relations,
                     projects: projects, tags: tags.tags, projectTags: tags.memberships,
                     memberships: memberships, decisions: decisions, suggestions: suggestions)
        if manifest.counts.drafts != drafts.count {
            throw DzArchiveError.countMismatch("drafts")
        }
        if manifest.counts.memberships != memberships.count {
            throw DzArchiveError.countMismatch("memberships")
        }

        // 8. PDF 快照定位
        var pdfFiles: [String: URL] = [:]
        for draft in drafts {
            guard let entry = draft.snapshotFile else { continue }
            let url = tmp.appendingPathComponent(entry)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw DzArchiveError.missingSnapshot(entry)
            }
            pdfFiles[entry] = url
        }

        return Contents(
            manifest: manifest, drafts: drafts, versions: versions, relations: relations,
            projects: projects, tags: tags, memberships: memberships,
            decisions: decisions, suggestions: suggestions,
            pdfFiles: pdfFiles, extractedDirectory: tmp)
    }

    // MARK: - 校验与工具

    static func validate(drafts: [DzArchiveExporter.ArchiveDraft],
                         versions: [DzArchiveExporter.ArchiveVersion],
                         relations: [DzArchiveExporter.ArchiveRelation],
                         projects: [DzArchiveExporter.ArchiveProject],
                         tags: [DzArchiveExporter.ArchiveTag],
                         projectTags: [DzArchiveExporter.ArchiveProjectTag],
                         memberships: [DzArchiveExporter.ArchiveMembership],
                         decisions: [DzArchiveExporter.ArchiveCandidateDecision],
                         suggestions: [DzArchiveExporter.ArchiveRemoteSuggestion]) throws {
        var draftIds: [String] = []
        for d in drafts {
            guard UUID(uuidString: d.id) != nil else { throw DzArchiveError.badReference("草稿 ID 不是规范 UUID") }
            guard !d.title.isEmpty else { throw DzArchiveError.badReference("存在标题为空的草稿") }
            if draftIds.contains(d.id) {
                print("[dz-debug] DUP on:", d.id, "seen:", draftIds, "array count:", drafts.count)
                throw DzArchiveError.badReference("档案中存在重复草稿 ID：\(d.id)")
            }
            draftIds.append(d.id)
        }
        var projectIds: [String] = []
        for p in projects {
            guard UUID(uuidString: p.id) != nil, !p.name.isEmpty else {
                throw DzArchiveError.badReference("项目记录不完整")
            }
            guard !projectIds.contains(p.id) else { throw DzArchiveError.badReference("重复项目 ID：\(p.id)") }
            projectIds.append(p.id)
        }
        var tagIds: [String] = []
        for t in tags {
            guard !tagIds.contains(t.id) else { throw DzArchiveError.badReference("重复标签 ID：\(t.id)") }
            tagIds.append(t.id)
        }
        var versionIds: [String] = []
        for v in versions {
            guard !versionIds.contains(v.id) else { throw DzArchiveError.badReference("重复版本 ID：\(v.id)") }
            versionIds.append(v.id)
            guard draftIds.contains(v.draftId) else { throw DzArchiveError.badReference("版本引用了不存在的草稿") }
        }
        for r in relations {
            guard draftIds.contains(r.sourceDraftId), draftIds.contains(r.targetDraftId) else {
                throw DzArchiveError.badReference("关系引用了不存在的草稿")
            }
        }
        for m in projectTags where !projectIds.contains(m.projectId) || !tagIds.contains(m.tagId) {
            throw DzArchiveError.badReference("项目-标签关系引用了不存在的记录")
        }
        for m in memberships where !projectIds.contains(m.projectId) || !draftIds.contains(m.draftId) {
            throw DzArchiveError.badReference("项目成员关系引用了不存在的记录")
        }
        for c in decisions {
            guard draftIds.contains(c.draftA), draftIds.contains(c.draftB) else {
                throw DzArchiveError.badReference("候选裁决引用了不存在的草稿")
            }
        }
        for sv in suggestions {
            for id in sv.draftIds where !draftIds.contains(id) {
                throw DzArchiveError.badReference("远程建议引用了不存在的草稿")
            }
            for c in sv.citations ?? [] where !draftIds.contains(c.draftId) {
                throw DzArchiveError.badReference("远程建议引用指向不存在的草稿")
            }
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DzArchiveError.decompressFailed("\(executable) 退出码 \(process.terminationStatus)")
        }
    }

    private static func listEntryNames(archivePath: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", archivePath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DzArchiveError.notAZip
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func allRelativeFiles(in directory: URL) throws -> [String] {
        var result: [String] = []
        // /var → /private/var 符号链接：基路径与子路径必须同源（否则多删一个字符，
        // 截出形如 CAF5543/ 的随机前缀——实机测试踩过）。
        let basePath = directory.standardizedFileURL.path
        let enumerator = FileManager.default.enumerator(
            at: directory.standardizedFileURL, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                result.append(String(url.standardizedFileURL.path.dropFirst(basePath.count + 1)))
            }
        }
        return result
    }
}
