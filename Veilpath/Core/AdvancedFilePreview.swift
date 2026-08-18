import CoreGraphics
import CoreText
import Foundation
import SQLite3
import zlib

struct SQLiteSummary: Equatable, Sendable {
    struct Table: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let columns: [String]
        let rowCount: Int64?
        let sampleRows: [[String]]
    }
    let tables: [Table]
    let indexes: [String]
    let journalMode: String?
    let hasWAL: Bool
    let hasSHM: Bool
}

struct ArchiveSummary: Equatable, Sendable {
    struct Entry: Identifiable, Equatable, Sendable {
        let id: Int
        let name: String
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let isDirectory: Bool
        let previewText: String?
    }
    let entries: [Entry]
}

struct FontSummary: Equatable, Sendable {
    let postScriptName: String
    let fullName: String?
    let glyphCount: Int
}

struct BinaryCookiesSummary: Equatable, Sendable {
    struct Cookie: Identifiable, Equatable, Sendable {
        let id: Int
        let domain: String
        let name: String
        let path: String
        let value: String
        let expiresAt: Date?
    }
    let pageCount: Int
    let pageSizes: [Int]
    let totalBytes: Int
    let cookies: [Cookie]
}

enum AdvancedFileAnalyzer {
    static func sqlite(at url: URL) throws -> SQLiteSummary {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            defer { if database != nil { sqlite3_close(database) } }
            throw NSError(domain: "SQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open this database read-only."])
        }
        defer { sqlite3_close(database) }

        let tableNames = strings(
            database,
            sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name LIMIT 200"
        )
        let indexes = strings(
            database,
            sql: "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%' ORDER BY name LIMIT 500"
        )
        let tables = tableNames.enumerated().map { index, name in
            let escaped = name.replacingOccurrences(of: "'", with: "''")
            let columns = strings(database, sql: "SELECT name FROM pragma_table_info('\(escaped)')")
            let quoted = name.replacingOccurrences(of: "\"", with: "\"\"")
            // Keep initial preview bounded. Remaining tables still expose their schema.
            let count = index < 25 ? integer(database, sql: "SELECT count(*) FROM \"\(quoted)\"") : nil
            let rows = index < 25 ? rows(database, sql: "SELECT * FROM \"\(quoted)\" LIMIT 100") : []
            return SQLiteSummary.Table(id: name, name: name, columns: columns, rowCount: count, sampleRows: rows)
        }
        return .init(
            tables: tables,
            indexes: indexes,
            journalMode: strings(database, sql: "PRAGMA journal_mode").first,
            hasWAL: FileManager.default.fileExists(atPath: url.path + "-wal"),
            hasSHM: FileManager.default.fileExists(atPath: url.path + "-shm")
        )
    }

    static func zip(data: Data) -> ArchiveSummary? {
        guard data.count >= 22 else { return nil }
        let signature: UInt32 = 0x02014b50
        var entries: [ArchiveSummary.Entry] = []
        var offset = 0
        while offset + 46 <= data.count, entries.count < 5_000 {
            if readUInt32LE(data, offset) != signature {
                offset += 1
                continue
            }
            let compressed = readUInt32LE(data, offset + 20)
            let uncompressed = readUInt32LE(data, offset + 24)
            let compressionMethod = readUInt16LE(data, offset + 10)
            let nameLength = Int(readUInt16LE(data, offset + 28))
            let extraLength = Int(readUInt16LE(data, offset + 30))
            let commentLength = Int(readUInt16LE(data, offset + 32))
            let localHeaderOffset = Int(readUInt32LE(data, offset + 42))
            let end = offset + 46 + nameLength
            guard end <= data.count else { break }
            let nameData = data[(offset + 46)..<end]
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? "Entry \(entries.count + 1)"
            let previewPayload = zipEntryData(
                archive: data,
                localHeaderOffset: localHeaderOffset,
                compressionMethod: compressionMethod,
                compressedSize: Int(compressed),
                uncompressedSize: Int(uncompressed)
            )
            let previewText: String?
            if let previewPayload, previewPayload.count <= 1_048_576 {
                previewText = String(data: previewPayload, encoding: .utf8)
            } else {
                previewText = nil
            }
            entries.append(.init(
                id: entries.count,
                name: name,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                isDirectory: name.hasSuffix("/"),
                previewText: previewText
            ))
            offset = end + extraLength + commentLength
        }
        return entries.isEmpty ? nil : .init(entries: entries)
    }

    static func font(data: Data) -> FontSummary? {
        guard let provider = CGDataProvider(data: data as CFData),
              let font = CGFont(provider) else { return nil }
        return .init(
            postScriptName: font.postScriptName as String? ?? "Unknown",
            fullName: font.fullName as String?,
            glyphCount: font.numberOfGlyphs
        )
    }

    static func binaryCookies(data: Data) -> BinaryCookiesSummary? {
        guard data.starts(with: Data("cook".utf8)), data.count >= 8 else { return nil }
        let count = Int(readUInt32BE(data, 4))
        guard count >= 0, count <= 100_000, 8 + count * 4 <= data.count else { return nil }
        let sizes = (0..<count).map { Int(readUInt32BE(data, 8 + $0 * 4)) }
        var cookies: [BinaryCookiesSummary.Cookie] = []
        var pageStart = 8 + count * 4
        for pageSize in sizes where pageSize >= 8 && pageStart + pageSize <= data.count {
            let cookieCount = Int(readUInt32LE(data, pageStart + 4))
            guard cookieCount >= 0, cookieCount <= 100_000, pageStart + 8 + cookieCount * 4 <= data.count else { break }
            for index in 0..<cookieCount {
                let cookieStart = pageStart + Int(readUInt32LE(data, pageStart + 8 + index * 4))
                guard cookieStart + 48 <= pageStart + pageSize else { continue }
                let size = Int(readUInt32LE(data, cookieStart))
                guard size >= 48, cookieStart + size <= pageStart + pageSize else { continue }
                let domainOffset = Int(readUInt32LE(data, cookieStart + 16))
                let nameOffset = Int(readUInt32LE(data, cookieStart + 20))
                let pathOffset = Int(readUInt32LE(data, cookieStart + 24))
                let valueOffset = Int(readUInt32LE(data, cookieStart + 28))
                let expiry = Double(bitPattern: readUInt64LE(data, cookieStart + 32))
                cookies.append(.init(
                    id: cookies.count,
                    domain: cString(data, cookieStart + domainOffset, cookieStart + size),
                    name: cString(data, cookieStart + nameOffset, cookieStart + size),
                    path: cString(data, cookieStart + pathOffset, cookieStart + size),
                    value: cString(data, cookieStart + valueOffset, cookieStart + size),
                    expiresAt: expiry.isFinite ? Date(timeIntervalSinceReferenceDate: expiry) : nil
                ))
            }
            pageStart += pageSize
        }
        return .init(pageCount: count, pageSizes: sizes, totalBytes: data.count, cookies: cookies)
    }

    private static func strings(_ database: OpaquePointer, sql: String) -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) {
                result.append(String(cString: value))
            }
        }
        return result
    }

    private static func integer(_ database: OpaquePointer, sql: String) -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private static func rows(_ database: OpaquePointer, sql: String) -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        let count = Int(sqlite3_column_count(statement))
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((0..<count).map { index in
                switch sqlite3_column_type(statement, Int32(index)) {
                case SQLITE_NULL: return "NULL"
                case SQLITE_BLOB: return "<\(sqlite3_column_bytes(statement, Int32(index))) bytes>"
                default:
                    guard let text = sqlite3_column_text(statement, Int32(index)) else { return "" }
                    return String(cString: text)
                }
            })
        }
        return result
    }

    private static func readUInt16LE(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
    private static func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
    private static func readUInt32BE(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }
    private static func readUInt64LE(_ data: Data, _ offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << UInt64($1 * 8) }
    }
    private static func cString(_ data: Data, _ start: Int, _ limit: Int) -> String {
        guard start >= 0, start < limit, limit <= data.count else { return "" }
        let end = data[start..<limit].firstIndex(of: 0) ?? limit
        return String(data: data[start..<end], encoding: .utf8) ?? ""
    }

    private static func zipEntryData(
        archive: Data,
        localHeaderOffset: Int,
        compressionMethod: UInt16,
        compressedSize: Int,
        uncompressedSize: Int
    ) -> Data? {
        guard localHeaderOffset >= 0,
              localHeaderOffset + 30 <= archive.count,
              readUInt32LE(archive, localHeaderOffset) == 0x04034b50 else { return nil }
        let nameLength = Int(readUInt16LE(archive, localHeaderOffset + 26))
        let extraLength = Int(readUInt16LE(archive, localHeaderOffset + 28))
        let start = localHeaderOffset + 30 + nameLength + extraLength
        guard start >= 0, compressedSize >= 0, start + compressedSize <= archive.count else { return nil }
        let payload = Data(archive[start..<(start + compressedSize)])
        if compressionMethod == 0 { return payload }
        guard compressionMethod == 8, uncompressedSize > 0, uncompressedSize <= 16 * 1_048_576 else { return nil }

        var output = Data(count: uncompressedSize)
        let decoded = payload.withUnsafeBytes { sourceBuffer in
            output.withUnsafeMutableBytes { destinationBuffer -> Bool in
                guard let source = sourceBuffer.bindMemory(to: Bytef.self).baseAddress,
                      let destination = destinationBuffer.bindMemory(to: Bytef.self).baseAddress else { return false }
                var stream = z_stream()
                stream.next_in = UnsafeMutablePointer(mutating: source)
                stream.avail_in = uInt(payload.count)
                stream.next_out = destination
                stream.avail_out = uInt(uncompressedSize)
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return false }
                defer { inflateEnd(&stream) }
                return inflate(&stream, Z_FINISH) == Z_STREAM_END
            }
        }
        return decoded ? output : nil
    }
}
