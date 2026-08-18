import Foundation
import zlib

struct StoredZIPEntry: Sendable {
    let archivePath: String
    let sourceURL: URL?
    let data: Data?
    let isDirectory: Bool
    let modifiedAt: Date?

    static func file(_ sourceURL: URL, path: String, modifiedAt: Date?) -> Self {
        .init(archivePath: path, sourceURL: sourceURL, data: nil, isDirectory: false, modifiedAt: modifiedAt)
    }

    static func data(_ data: Data, path: String, modifiedAt: Date? = .now) -> Self {
        .init(archivePath: path, sourceURL: nil, data: data, isDirectory: false, modifiedAt: modifiedAt)
    }

    static func directory(_ path: String, modifiedAt: Date?) -> Self {
        .init(archivePath: path.hasSuffix("/") ? path : path + "/", sourceURL: nil, data: nil,
              isDirectory: true, modifiedAt: modifiedAt)
    }
}

struct StoredZIPExtractedEntry: Sendable {
    let archivePath: String
    let destinationURL: URL
    let isDirectory: Bool
    let uncompressedSize: Int64
}

enum StoredZIPError: LocalizedError {
    case archiveTooLarge, pathTooLong, invalidArchive, unsupportedCompression, encryptedArchive
    case unsafePath(String), symbolicLink, verificationFailed, insufficientStorage, suspiciousCompression

    var errorDescription: String? {
        switch self {
        case .archiveTooLarge: "The ZIP archive exceeds the supported 4 GB or 65,535-entry limit."
        case .pathTooLong: "A ZIP entry path is too long."
        case .invalidArchive: "The ZIP archive is incomplete or malformed."
        case .unsupportedCompression: "This ZIP uses a compression method that Veilpath cannot safely extract yet."
        case .encryptedArchive: "Encrypted ZIP archives are not supported."
        case .unsafePath(let path): "The ZIP contains an unsafe absolute or parent-relative path: \(path)"
        case .symbolicLink: "The ZIP contains a symbolic-link entry, which Veilpath will not extract."
        case .verificationFailed: "A ZIP entry failed its size or CRC-32 verification."
        case .insufficientStorage: "There is not enough free storage to extract this archive safely."
        case .suspiciousCompression: "The ZIP has a suspicious expansion ratio and was blocked."
        }
    }
}

enum StoredZIPArchive {
    typealias Progress = @Sendable (_ completedBytes: Int64, _ totalBytes: Int64, _ completedItems: Int, _ totalItems: Int) async -> Void
    private static let chunkSize = 1024 * 1024
    private static let maximumExtractedBytes: Int64 = 8 * 1024 * 1024 * 1024
    private static let storageReserve: Int64 = 64 * 1024 * 1024
    private static let maximumCompressionRatio: Int64 = 1_000

    nonisolated static func write(entries: [StoredZIPEntry], to destination: URL, progress: Progress) async throws {
        guard entries.count <= Int(UInt16.max) else { throw StoredZIPError.archiveTooLarge }
        let totalBytes = try entries.reduce(Int64(0)) { partial, entry in
            if let data = entry.data { return partial + Int64(data.count) }
            if let source = entry.sourceURL {
                let values = try source.resourceValues(forKeys: [.fileSizeKey])
                return partial + Int64(values.fileSize ?? 0)
            }
            return partial
        }
        guard totalBytes <= Int64(UInt32.max) else { throw StoredZIPError.archiveTooLarge }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).partial")
        try? FileManager.default.removeItem(at: partial)
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let output = try FileHandle(forWritingTo: partial)
            defer { try? output.close() }
            var records: [CentralRecord] = []
            var completedBytes: Int64 = 0
            var completedItems = 0
            await progress(0, totalBytes, 0, entries.count)
            for entry in entries {
                try Task.checkCancellation()
                let normalized = try safePath(entry.archivePath, directory: entry.isDirectory)
                let name = Data(normalized.utf8)
                guard name.count <= Int(UInt16.max) else { throw StoredZIPError.pathTooLong }
                let offset = try output.offset()
                guard offset <= UInt64(UInt32.max) else { throw StoredZIPError.archiveTooLarge }
                let date = dosDate(entry.modifiedAt)
                if entry.isDirectory {
                    try output.write(contentsOf: localHeader(name: name, date: date, descriptor: false))
                    records.append(.init(name: name, crc: 0, size: 0, offset: UInt32(offset), date: date, isDirectory: true))
                } else {
                    try output.write(contentsOf: localHeader(name: name, date: date, descriptor: true))
                    var crc = crc32(0, nil, 0)
                    var size: UInt32 = 0
                    if let data = entry.data {
                        try output.write(contentsOf: data)
                        crc = updateCRC(crc, data)
                        size = try checkedSize(data.count)
                        completedBytes += Int64(data.count)
                    } else if let source = entry.sourceURL {
                        let input = try FileHandle(forReadingFrom: source)
                        defer { try? input.close() }
                        while let data = try input.read(upToCount: chunkSize), !data.isEmpty {
                            try Task.checkCancellation()
                            try output.write(contentsOf: data)
                            crc = updateCRC(crc, data)
                            let next = UInt64(size) + UInt64(data.count)
                            guard next <= UInt64(UInt32.max) else { throw StoredZIPError.archiveTooLarge }
                            size = UInt32(next)
                            completedBytes += Int64(data.count)
                            await progress(completedBytes, totalBytes, completedItems, entries.count)
                        }
                    } else { throw StoredZIPError.invalidArchive }
                    try output.write(contentsOf: descriptor(crc: crc, size: size))
                    records.append(.init(name: name, crc: crc, size: size, offset: UInt32(offset), date: date, isDirectory: false))
                }
                completedItems += 1
                await progress(completedBytes, totalBytes, completedItems, entries.count)
            }
            let centralOffset = try output.offset()
            for record in records { try output.write(contentsOf: centralHeader(record)) }
            let end = try output.offset()
            guard centralOffset <= UInt64(UInt32.max), end - centralOffset <= UInt64(UInt32.max) else {
                throw StoredZIPError.archiveTooLarge
            }
            try output.write(contentsOf: endRecord(count: UInt16(records.count), size: UInt32(end - centralOffset), offset: UInt32(centralOffset)))
            try output.synchronize()
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    nonisolated static func extract(_ archive: URL, to destination: URL, progress: Progress) async throws -> [StoredZIPExtractedEntry] {
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        let archiveSize = try input.seekToEnd()
        let records = try centralRecords(from: input, archiveSize: archiveSize)
        guard records.count <= Int(UInt16.max) else { throw StoredZIPError.archiveTooLarge }
        let normalizedPaths = try records.map { try safePath($0.path, directory: $0.isDirectory) }
        guard normalizedPaths.count == Set(normalizedPaths).count else { throw StoredZIPError.invalidArchive }
        let total = try records.reduce(Int64(0)) { partial, record in
            let (next, overflow) = partial.addingReportingOverflow(Int64(record.size))
            guard !overflow else { throw StoredZIPError.archiveTooLarge }
            return next
        }
        guard total <= maximumExtractedBytes else { throw StoredZIPError.archiveTooLarge }
        for record in records where !record.isDirectory && record.size > 64 * 1024 * 1024 {
            if record.compressedSize == 0 || Int64(record.size) > Int64(record.compressedSize) * maximumCompressionRatio {
                throw StoredZIPError.suspiciousCompression
            }
        }
        try requireStorage(for: total, near: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var completed: Int64 = 0
        var results: [StoredZIPExtractedEntry] = []
        for (index, record) in records.enumerated() {
            try Task.checkCancellation()
            guard record.method == 0 || record.method == 8 else { throw StoredZIPError.unsupportedCompression }
            guard record.flags & 0x0001 == 0 else { throw StoredZIPError.encryptedArchive }
            guard !record.isSymbolicLink else { throw StoredZIPError.symbolicLink }
            let path = try safePath(record.path, directory: record.isDirectory)
            let target = destination.appending(path: path)
            let destinationPath = canonicalPath(destination)
            let targetPath = canonicalPath(target)
            guard targetPath.hasPrefix(destinationPath + "/") else { throw StoredZIPError.unsafePath(record.path) }
            if record.isDirectory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let partial = target.deletingLastPathComponent().appending(path: ".\(target.lastPathComponent).partial-\(UUID().uuidString)")
                do {
                    guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                    let output = try FileHandle(forWritingTo: partial)
                    defer { try? output.close() }
                    let offset = try payloadOffset(for: record, from: input)
                    try input.seek(toOffset: offset)
                    let result = record.method == 8
                        ? try await inflateRaw(from: input, compressedSize: Int64(record.compressedSize),
                                               expectedSize: Int64(record.size), to: output)
                        : try await copyStored(from: input, compressedSize: Int64(record.compressedSize), to: output)
                    try output.synchronize()
                    guard result.size == Int64(record.size), result.crc == record.crc else { throw StoredZIPError.verificationFailed }
                    try FileManager.default.moveItem(at: partial, to: target)
                    completed += result.size
                } catch {
                    try? FileManager.default.removeItem(at: partial)
                    throw error
                }
            }
            results.append(.init(archivePath: path, destinationURL: target, isDirectory: record.isDirectory,
                                 uncompressedSize: Int64(record.size)))
            await progress(completed, total, index + 1, records.count)
        }
        return results
    }

    private struct CentralRecord {
        let path: String
        let name: Data
        let crc: uLong
        let size: UInt32
        let offset: UInt32
        let date: (time: UInt16, date: UInt16)
        let isDirectory: Bool
        let method: UInt16
        let compressedSize: UInt32
        let isSymbolicLink: Bool
        let flags: UInt16

        init(path: String = "", name: Data, crc: uLong, size: UInt32, offset: UInt32,
             date: (time: UInt16, date: UInt16), isDirectory: Bool, method: UInt16 = 0,
             compressedSize: UInt32? = nil, isSymbolicLink: Bool = false, flags: UInt16 = 0) {
            self.path = path
            self.name = name
            self.crc = crc
            self.size = size
            self.offset = offset
            self.date = date
            self.isDirectory = isDirectory
            self.method = method
            self.compressedSize = compressedSize ?? size
            self.isSymbolicLink = isSymbolicLink
            self.flags = flags
        }
    }

    private static func centralRecords(from handle: FileHandle, archiveSize: UInt64) throws -> [CentralRecord] {
        guard archiveSize >= 22 else { throw StoredZIPError.invalidArchive }
        let tailSize = Int(min(archiveSize, 65_557))
        try handle.seek(toOffset: archiveSize - UInt64(tailSize))
        let tail = try readExactly(tailSize, from: handle)
        var endOffset: Int?
        for offset in stride(from: tail.count - 22, through: 0, by: -1) where tail.uint32LE(at: offset) == 0x06054b50 {
            if let commentLength = tail.uint16LE(at: offset + 20), offset + 22 + Int(commentLength) == tail.count {
                endOffset = offset; break
            }
        }
        guard let endOffset,
              tail.uint16LE(at: endOffset + 4) == 0,
              tail.uint16LE(at: endOffset + 6) == 0,
              let diskCount = tail.uint16LE(at: endOffset + 8),
              let count = tail.uint16LE(at: endOffset + 10), diskCount == count,
              let centralSize = tail.uint32LE(at: endOffset + 12),
              let centralOffset = tail.uint32LE(at: endOffset + 16),
              UInt64(centralOffset) + UInt64(centralSize) <= archiveSize else { throw StoredZIPError.invalidArchive }
        try handle.seek(toOffset: UInt64(centralOffset))
        let data = try readExactly(Int(centralSize), from: handle)
        var cursor = 0
        var records: [CentralRecord] = []
        for _ in 0..<count {
            guard data.uint32LE(at: cursor) == 0x02014b50,
                  let flags = data.uint16LE(at: cursor + 8),
                  let method = data.uint16LE(at: cursor + 10),
                  let crc = data.uint32LE(at: cursor + 16),
                  let compressedSize = data.uint32LE(at: cursor + 20),
                  let size = data.uint32LE(at: cursor + 24),
                  let nameLength = data.uint16LE(at: cursor + 28),
                  let extraLength = data.uint16LE(at: cursor + 30),
                  let commentLength = data.uint16LE(at: cursor + 32),
                  let external = data.uint32LE(at: cursor + 38),
                  let offset = data.uint32LE(at: cursor + 42) else { throw StoredZIPError.invalidArchive }
            let nameStart = cursor + 46
            let nameEnd = nameStart + Int(nameLength)
            guard nameEnd <= data.count else { throw StoredZIPError.invalidArchive }
            let name = data.subdata(in: nameStart..<nameEnd)
            let path = String(decoding: name, as: UTF8.self)
            let directory = path.hasSuffix("/") || (external & 0x10) != 0
            let symbolicLink = ((external >> 16) & 0xF000) == 0xA000
            _ = flags
            records.append(.init(path: path, name: name, crc: uLong(crc), size: size, offset: offset,
                                 date: (0, 0), isDirectory: directory, method: method,
                                 compressedSize: compressedSize, isSymbolicLink: symbolicLink, flags: flags))
            cursor = nameEnd + Int(extraLength) + Int(commentLength)
        }
        guard cursor <= data.count else { throw StoredZIPError.invalidArchive }
        return records
    }

    private static func payloadOffset(for record: CentralRecord, from handle: FileHandle) throws -> UInt64 {
        try handle.seek(toOffset: UInt64(record.offset))
        let header = try readExactly(30, from: handle)
        guard header.uint32LE(at: 0) == 0x04034b50,
              let flags = header.uint16LE(at: 6), flags & 0x0001 == 0,
              header.uint16LE(at: 8) == record.method,
              let nameLength = header.uint16LE(at: 26),
              let extraLength = header.uint16LE(at: 28) else { throw StoredZIPError.invalidArchive }
        let name = try readExactly(Int(nameLength), from: handle)
        guard name == record.name else { throw StoredZIPError.invalidArchive }
        return UInt64(record.offset) + 30 + UInt64(nameLength) + UInt64(extraLength)
    }

    private static func copyStored(from input: FileHandle, compressedSize: Int64, to output: FileHandle) async throws -> (size: Int64, crc: uLong) {
        var remaining = compressedSize
        var written: Int64 = 0
        var crc = crc32(0, nil, 0)
        while remaining > 0 {
            try Task.checkCancellation()
            let data = try readExactly(Int(min(Int64(chunkSize), remaining)), from: input)
            try output.write(contentsOf: data)
            crc = updateCRC(crc, data)
            written += Int64(data.count)
            remaining -= Int64(data.count)
        }
        return (written, crc)
    }

    private static func inflateRaw(
        from input: FileHandle,
        compressedSize: Int64,
        expectedSize: Int64,
        to output: FileHandle
    ) async throws -> (size: Int64, crc: uLong) {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw StoredZIPError.verificationFailed
        }
        defer { inflateEnd(&stream) }
        var remaining = compressedSize
        var written: Int64 = 0
        var crc = crc32(0, nil, 0)
        var reachedEnd = false
        while remaining > 0, !reachedEnd {
            try Task.checkCancellation()
            let inputData = try readExactly(Int(min(Int64(chunkSize), remaining)), from: input)
            remaining -= Int64(inputData.count)
            try inputData.withUnsafeBytes { inputBytes in
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBytes.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(inputData.count)
                while stream.avail_in > 0 {
                    var buffer = [UInt8](repeating: 0, count: chunkSize)
                    let (status, produced): (Int32, Int) = buffer.withUnsafeMutableBytes { outputBytes in
                        stream.next_out = outputBytes.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = uInt(chunkSize)
                        let status = inflate(&stream, Z_NO_FLUSH)
                        return (status, chunkSize - Int(stream.avail_out))
                    }
                    guard status == Z_OK || status == Z_STREAM_END else { throw StoredZIPError.verificationFailed }
                    if produced > 0 {
                        let data = Data(buffer.prefix(produced))
                        try output.write(contentsOf: data)
                        crc = updateCRC(crc, data)
                        written += Int64(produced)
                        guard written <= expectedSize else { throw StoredZIPError.verificationFailed }
                    }
                    if status == Z_STREAM_END { reachedEnd = true; break }
                }
            }
        }
        guard reachedEnd, remaining == 0, written == expectedSize else { throw StoredZIPError.verificationFailed }
        return (written, crc)
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        if count == 0 { return Data() }
        guard count >= 0, let data = try handle.read(upToCount: count), data.count == count else {
            throw StoredZIPError.invalidArchive
        }
        return data
    }

    private static func requireStorage(for bytes: Int64, near destination: URL) throws {
        var probe = destination
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
            probe.deleteLastPathComponent()
        }
        let values = try probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage,
           available < bytes + storageReserve {
            throw StoredZIPError.insufficientStorage
        }
    }

    private static func safePath(_ raw: String, directory: Bool) throws -> String {
        let replaced = raw.replacingOccurrences(of: "\\", with: "/")
        guard !replaced.hasPrefix("/"), !replaced.contains("\0") else { throw StoredZIPError.unsafePath(raw) }
        var parts: [Substring] = []
        for part in replaced.split(separator: "/") {
            guard part != ".", part != ".." else { throw StoredZIPError.unsafePath(raw) }
            parts.append(part)
        }
        guard !parts.isEmpty else { throw StoredZIPError.unsafePath(raw) }
        let value = parts.joined(separator: "/")
        return directory ? value + "/" : value
    }

    private static func canonicalPath(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path == "/var" || path.hasPrefix("/var/") { path = "/private" + path }
        return path
    }

    private static func checkedSize(_ count: Int) throws -> UInt32 {
        guard count <= Int(UInt32.max) else { throw StoredZIPError.archiveTooLarge }
        return UInt32(count)
    }

    private static func updateCRC(_ crc: uLong, _ data: Data) -> uLong {
        data.withUnsafeBytes { bytes in crc32(crc, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)) }
    }

    private static func localHeader(name: Data, date: (time: UInt16, date: UInt16), descriptor: Bool) -> Data {
        var data = Data(); data.appendLE(UInt32(0x04034b50)); data.appendLE(UInt16(20)); data.appendLE(UInt16(0x0800 | (descriptor ? 0x0008 : 0)))
        data.appendLE(UInt16(0)); data.appendLE(date.time); data.appendLE(date.date); data.appendLE(UInt32(0)); data.appendLE(UInt32(0)); data.appendLE(UInt32(0))
        data.appendLE(UInt16(name.count)); data.appendLE(UInt16(0)); data.append(name); return data
    }

    private static func descriptor(crc: uLong, size: UInt32) -> Data {
        var data = Data(); data.appendLE(UInt32(0x08074b50)); data.appendLE(UInt32(crc)); data.appendLE(size); data.appendLE(size); return data
    }

    private static func centralHeader(_ record: CentralRecord) -> Data {
        var data = Data(); data.appendLE(UInt32(0x02014b50)); data.appendLE(UInt16(20)); data.appendLE(UInt16(20)); data.appendLE(UInt16(0x0800 | (record.isDirectory ? 0 : 0x0008)))
        data.appendLE(UInt16(0)); data.appendLE(record.date.time); data.appendLE(record.date.date); data.appendLE(UInt32(record.crc)); data.appendLE(record.size); data.appendLE(record.size)
        data.appendLE(UInt16(record.name.count)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0)); data.appendLE(record.isDirectory ? UInt32(0x10) : UInt32(0)); data.appendLE(record.offset); data.append(record.name); return data
    }

    private static func endRecord(count: UInt16, size: UInt32, offset: UInt32) -> Data {
        var data = Data(); data.appendLE(UInt32(0x06054b50)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0)); data.appendLE(count); data.appendLE(count)
        data.appendLE(size); data.appendLE(offset); data.appendLE(UInt16(0)); return data
    }

    private static func dosDate(_ date: Date?) -> (time: UInt16, date: UInt16) {
        let values = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date ?? .now)
        let year = min(2107, max(1980, values.year ?? 1980))
        return (UInt16((values.hour ?? 0) << 11 | (values.minute ?? 0) << 5 | (values.second ?? 0) / 2),
                UInt16((year - 1980) << 9 | (values.month ?? 1) << 5 | (values.day ?? 1)))
    }
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func uint32LE(at offset: Int) -> UInt32? {
        guard let low = uint16LE(at: offset), let high = uint16LE(at: offset + 2) else { return nil }
        return UInt32(low) | UInt32(high) << 16
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
