import Foundation
import zlib

enum ShareExportRequest: Equatable, Sendable {
    case file(FileItem)
    case directory(url: URL, name: String, includeHidden: Bool)

    var title: String {
        switch self {
        case .file(let item): item.name
        case .directory(_, let name, _): name + ".zip"
        }
    }
}

struct SharePreparation: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case preparing
        case ready(URL, detail: String)
        case failed(String)
    }

    let id: UUID
    let request: ShareExportRequest
    var progress: ShareExportProgress
    var state: State
}

struct ShareExportProgress: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable { case preparing, copying, archiving, finalizing }
    let phase: Phase
    let completedBytes: Int64
    let totalBytes: Int64
    let completedItems: Int
    let totalItems: Int
}

struct DirectoryArchiveResult: Equatable, Sendable {
    let url: URL
    let itemCount: Int
    let skippedSymbolicLinks: Int
    let totalBytes: Int64
}

enum ShareExportError: LocalizedError {
    case sourceMissing
    case directoryExpected
    case fileExpected
    case archiveTooLarge
    case pathTooLong
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .sourceMissing: "The source no longer exists."
        case .directoryExpected: "A folder is required for ZIP export."
        case .fileExpected: "A file is required for this export."
        case .archiveTooLarge: "This folder exceeds the current 4 GB ZIP export limit."
        case .pathTooLong: "A path is too long to store safely in the ZIP archive."
        case .verificationFailed: "The prepared export did not match the source size."
        }
    }
}

enum ShareExportService {
    typealias ProgressHandler = @Sendable (ShareExportProgress) async -> Void
    private static let chunkSize = 1024 * 1024

    nonisolated static func prepareFile(
        at source: URL,
        named requestedName: String,
        progress: ProgressHandler
    ) async throws -> URL {
        let source = source.standardizedFileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard FileManager.default.fileExists(atPath: source.path) else { throw ShareExportError.sourceMissing }
        guard (attributes[.type] as? FileAttributeType) != .typeDirectory else { throw ShareExportError.fileExpected }
        let total = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let grant = try acquireGrant(for: source, directory: false)
        defer { release(grant) }
        let operation = try ExportCache.createOperationDirectory()
        let partial = operation.appending(path: ".partial")
        let destination = operation.appending(path: ExportCache.safeName(requestedName))
        do {
            await progress(.init(phase: .preparing, completedBytes: 0, totalBytes: total, completedItems: 0, totalItems: 1))
            try FileManager.default.createFile(atPath: partial.path, contents: nil).requireSuccess()
            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: partial)
            defer { try? input.close(); try? output.close() }
            var copied: Int64 = 0
            while true {
                try Task.checkCancellation()
                guard let data = try input.read(upToCount: chunkSize), !data.isEmpty else { break }
                try output.write(contentsOf: data)
                copied += Int64(data.count)
                await progress(.init(phase: .copying, completedBytes: copied, totalBytes: total, completedItems: 0, totalItems: 1))
            }
            try output.synchronize()
            guard copied == total else { throw ShareExportError.verificationFailed }
            try FileManager.default.moveItem(at: partial, to: destination)
            await progress(.init(phase: .finalizing, completedBytes: total, totalBytes: total, completedItems: 1, totalItems: 1))
            return destination
        } catch {
            try? FileManager.default.removeItem(at: operation)
            throw error
        }
    }

    nonisolated static func prepareDirectoryZIP(
        at root: URL,
        named requestedName: String,
        includeHidden: Bool,
        progress: ProgressHandler
    ) async throws -> DirectoryArchiveResult {
        let root = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { throw ShareExportError.sourceMissing }
        guard isDirectory.boolValue else { throw ShareExportError.directoryExpected }
        let grant = try acquireGrant(for: root, directory: true)
        defer { release(grant) }

        let entries = try archiveEntries(root: root, includeHidden: includeHidden)
        let totalBytes = entries.reduce(Int64(0)) { $0 + ($1.isDirectory ? 0 : $1.size) }
        guard totalBytes <= Int64(UInt32.max) else { throw ShareExportError.archiveTooLarge }
        let skipped = entries.filter(\.isSymbolicLink).count
        let included = entries.filter { !$0.isSymbolicLink }
        let operation = try ExportCache.createOperationDirectory()
        let zipName = ExportCache.safeName(requestedName).deletingPathExtension + ".zip"
        let partial = operation.appending(path: ".partial")
        let destination = operation.appending(path: zipName)
        do {
            try FileManager.default.createFile(atPath: partial.path, contents: nil).requireSuccess()
            let output = try FileHandle(forWritingTo: partial)
            defer { try? output.close() }
            await progress(.init(phase: .preparing, completedBytes: 0, totalBytes: totalBytes, completedItems: 0, totalItems: included.count))
            var centralRecords: [CentralRecord] = []
            var completedBytes: Int64 = 0
            var completedItems = 0
            for entry in included {
                try Task.checkCancellation()
                let offset = try output.offset()
                guard offset <= UInt64(UInt32.max) else { throw ShareExportError.archiveTooLarge }
                let nameData = Data(entry.relativePath.utf8)
                guard nameData.count <= Int(UInt16.max) else { throw ShareExportError.pathTooLong }
                let date = dosDate(entry.modifiedAt)
                if entry.isDirectory {
                    try output.write(contentsOf: localHeader(name: nameData, date: date, usesDescriptor: false))
                    centralRecords.append(.init(name: nameData, crc: 0, size: 0, offset: UInt32(offset), date: date, isDirectory: true))
                } else {
                    guard entry.size <= Int64(UInt32.max) else { throw ShareExportError.archiveTooLarge }
                    try output.write(contentsOf: localHeader(name: nameData, date: date, usesDescriptor: true))
                    var crc = crc32(0, nil, 0)
                    var written: UInt32 = 0
                    do {
                        let input = try FileHandle(forReadingFrom: entry.url)
                        defer { try? input.close() }
                        while true {
                            try Task.checkCancellation()
                            guard let data = try input.read(upToCount: chunkSize), !data.isEmpty else { break }
                            try output.write(contentsOf: data)
                            crc = data.withUnsafeBytes { bytes in
                                crc32(crc, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(data.count))
                            }
                            written += UInt32(data.count)
                            completedBytes += Int64(data.count)
                            await progress(.init(phase: .archiving, completedBytes: completedBytes, totalBytes: totalBytes,
                                                 completedItems: completedItems, totalItems: included.count))
                        }
                    }
                    guard Int64(written) == entry.size else { throw ShareExportError.verificationFailed }
                    try output.write(contentsOf: descriptor(crc: crc, size: written))
                    centralRecords.append(.init(name: nameData, crc: crc, size: written, offset: UInt32(offset), date: date, isDirectory: false))
                }
                completedItems += 1
                await progress(.init(phase: .archiving, completedBytes: completedBytes, totalBytes: totalBytes,
                                     completedItems: completedItems, totalItems: included.count))
            }
            let centralOffset = try output.offset()
            for record in centralRecords { try output.write(contentsOf: centralHeader(record)) }
            let centralEnd = try output.offset()
            guard centralOffset <= UInt64(UInt32.max), centralEnd - centralOffset <= UInt64(UInt32.max), centralRecords.count <= Int(UInt16.max) else {
                throw ShareExportError.archiveTooLarge
            }
            try output.write(contentsOf: endRecord(count: UInt16(centralRecords.count),
                                                    size: UInt32(centralEnd - centralOffset), offset: UInt32(centralOffset)))
            try output.synchronize()
            try FileManager.default.moveItem(at: partial, to: destination)
            await progress(.init(phase: .finalizing, completedBytes: totalBytes, totalBytes: totalBytes,
                                 completedItems: included.count, totalItems: included.count))
            return .init(url: destination, itemCount: included.count, skippedSymbolicLinks: skipped, totalBytes: totalBytes)
        } catch {
            try? FileManager.default.removeItem(at: operation)
            throw error
        }
    }

    private struct ArchiveEntry {
        let url: URL
        let relativePath: String
        let isDirectory: Bool
        let isSymbolicLink: Bool
        let size: Int64
        let modifiedAt: Date?
    }

    private struct CentralRecord {
        let name: Data
        let crc: uLong
        let size: UInt32
        let offset: UInt32
        let date: (time: UInt16, date: UInt16)
        let isDirectory: Bool
    }

    private static func archiveEntries(root: URL, includeHidden: Bool) throws -> [ArchiveEntry] {
        var options: FileManager.DirectoryEnumerationOptions = []
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var entries: [ArchiveEntry] = []
        var pending: [(url: URL, relativePrefix: String)] = [(root, "")]
        while let directory = pending.popLast() {
            try Task.checkCancellation()
            let children = try FileManager.default.contentsOfDirectory(
                at: directory.url,
                includingPropertiesForKeys: Array(keys),
                options: options
            )
            for url in children {
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: keys)
                let symbolicLink = values.isSymbolicLink == true
                let isDirectory = values.isDirectory == true
                var relative = directory.relativePrefix + url.lastPathComponent
                if isDirectory { relative += "/" }
                entries.append(.init(url: url, relativePath: relative, isDirectory: isDirectory,
                                     isSymbolicLink: symbolicLink, size: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate))
                if isDirectory, !symbolicLink {
                    pending.append((url, relative))
                }
            }
        }
        return entries.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    private static func localHeader(name: Data, date: (time: UInt16, date: UInt16), usesDescriptor: Bool) -> Data {
        var data = Data()
        data.appendLE(UInt32(0x04034b50)); data.appendLE(UInt16(20)); data.appendLE(UInt16(0x0800 | (usesDescriptor ? 0x0008 : 0)))
        data.appendLE(UInt16(0)); data.appendLE(date.time); data.appendLE(date.date)
        data.appendLE(UInt32(0)); data.appendLE(UInt32(0)); data.appendLE(UInt32(0))
        data.appendLE(UInt16(name.count)); data.appendLE(UInt16(0)); data.append(name)
        return data
    }

    private static func descriptor(crc: uLong, size: UInt32) -> Data {
        var data = Data(); data.appendLE(UInt32(0x08074b50)); data.appendLE(UInt32(crc)); data.appendLE(size); data.appendLE(size); return data
    }

    private static func centralHeader(_ record: CentralRecord) -> Data {
        var data = Data()
        data.appendLE(UInt32(0x02014b50)); data.appendLE(UInt16(20)); data.appendLE(UInt16(20))
        data.appendLE(UInt16(0x0800 | (record.isDirectory ? 0 : 0x0008))); data.appendLE(UInt16(0))
        data.appendLE(record.date.time); data.appendLE(record.date.date); data.appendLE(UInt32(record.crc))
        data.appendLE(record.size); data.appendLE(record.size); data.appendLE(UInt16(record.name.count))
        data.appendLE(UInt16(0)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0))
        data.appendLE(record.isDirectory ? UInt32(0x10) : UInt32(0)); data.appendLE(record.offset); data.append(record.name)
        return data
    }

    private static func endRecord(count: UInt16, size: UInt32, offset: UInt32) -> Data {
        var data = Data(); data.appendLE(UInt32(0x06054b50)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0))
        data.appendLE(count); data.appendLE(count); data.appendLE(size); data.appendLE(offset); data.appendLE(UInt16(0)); return data
    }

    private static func dosDate(_ date: Date?) -> (time: UInt16, date: UInt16) {
        let values = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: date ?? .now)
        let year = min(2107, max(1980, values.year ?? 1980))
        let time = UInt16((values.hour ?? 0) << 11 | (values.minute ?? 0) << 5 | (values.second ?? 0) / 2)
        let day = UInt16((year - 1980) << 9 | (values.month ?? 1) << 5 | (values.day ?? 1))
        return (time, day)
    }

    private static func acquireGrant(for url: URL, directory: Bool) throws -> BadQueryGrant? {
        #if targetEnvironment(simulator)
        return nil
        #else
        return try BadQueryClient.acquire(.init(path: directory ? url.path : url.deletingLastPathComponent().path, createIfMissing: true))
        #endif
    }

    private static func release(_ grant: BadQueryGrant?) { if let grant { BadQueryClient.release(grant) } }
}

extension ExportCache {
    static func createOperationDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    static func safeName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
        let cleaned = name.components(separatedBy: invalid).filter { !$0.isEmpty }.joined(separator: "-")
        return cleaned.isEmpty ? "Export" : String(cleaned.prefix(180))
    }
}

private extension String {
    var deletingPathExtension: String { (self as NSString).deletingPathExtension }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

private extension Bool {
    func requireSuccess() throws { if !self { throw CocoaError(.fileWriteUnknown) } }
}
