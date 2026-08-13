import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct FileProperties: Equatable, Sendable {
    let size: Int64
    let createdAt: Date?
    let modifiedAt: Date?
    let posixPermissions: Int
    let owner: String?
    let group: String?
    let inode: UInt64?
    let typeIdentifier: String?
    let sha256: String
}

struct StructuredNode: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case dictionary, array, string, number, boolean, date, data, null }
    let id: String
    let key: String
    let value: String?
    let kind: Kind
    let children: [StructuredNode]

    var searchableText: String {
        ([key, value ?? ""] + children.map(\.searchableText)).joined(separator: " ")
    }

    func matching(_ query: String) -> StructuredNode? {
        guard !query.isEmpty else { return self }
        let matchingChildren = children.compactMap { $0.matching(query) }
        if key.localizedCaseInsensitiveContains(query)
            || value?.localizedCaseInsensitiveContains(query) == true
            || !matchingChildren.isEmpty {
            return .init(id: id, key: key, value: value, kind: kind, children: matchingChildren)
        }
        return nil
    }

    static func make(key: String, value: Any, path: String = "root") -> StructuredNode {
        let id = "\(path).\(key)"
        switch value {
        case let dictionary as [String: Any]:
            return .init(id: id, key: key, value: nil, kind: .dictionary,
                         children: dictionary.keys.sorted().map { make(key: $0, value: dictionary[$0]!, path: id) })
        case let array as [Any]:
            return .init(id: id, key: key, value: nil, kind: .array,
                         children: array.enumerated().map { make(key: "[\($0.offset)]", value: $0.element, path: id) })
        case let string as String:
            return .init(id: id, key: key, value: string, kind: .string, children: [])
        case let date as Date:
            return .init(id: id, key: key, value: date.formatted(.iso8601), kind: .date, children: [])
        case let data as Data:
            return .init(id: id, key: key, value: "\(data.count) bytes", kind: .data, children: [])
        case let number as NSNumber:
            let isBoolean = CFGetTypeID(number) == CFBooleanGetTypeID()
            return .init(id: id, key: key, value: isBoolean ? (number.boolValue ? "true" : "false") : number.stringValue,
                         kind: isBoolean ? .boolean : .number, children: [])
        case is NSNull:
            return .init(id: id, key: key, value: "null", kind: .null, children: [])
        default:
            return .init(id: id, key: key, value: String(describing: value), kind: .string, children: [])
        }
    }
}

struct ImageDetails: Equatable, Sendable {
    let width: Int
    let height: Int
    let frameCount: Int
    let typeIdentifier: String?
    let properties: [String: String]
}

struct MachOInfo: Equatable, Sendable {
    struct Architecture: Identifiable, Equatable, Sendable {
        let id: Int
        let name: String
        let fileType: String
        let flags: String
        let minimumOS: String?
        let sdk: String?
        let uuid: String?
        let dependencies: [String]
        let rpaths: [String]
        let encrypted: Bool?
    }
    let architectures: [Architecture]
    let entitlements: String?
    let codeSignaturePresent: Bool
}

enum FileAnalyzer {
    static func properties(for url: URL, data: Data) throws -> FileProperties {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let resource = try? url.resourceValues(forKeys: [.contentTypeKey])
        return FileProperties(
            size: (attributes[.size] as? NSNumber)?.int64Value ?? Int64(data.count),
            createdAt: attributes[.creationDate] as? Date,
            modifiedAt: attributes[.modificationDate] as? Date,
            posixPermissions: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0,
            owner: attributes[.ownerAccountName] as? String,
            group: attributes[.groupOwnerAccountName] as? String,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            typeIdentifier: resource?.contentType?.identifier,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }

    static func imageDetails(data: Data) -> ImageDetails? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
        let width = (raw[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
        let height = (raw[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
        var flattened: [String: String] = [:]
        for (key, value) in raw where !(value is [String: Any]) {
            flattened[key] = String(describing: value)
        }
        return .init(width: width, height: height, frameCount: CGImageSourceGetCount(source),
                     typeIdentifier: CGImageSourceGetType(source) as String?, properties: flattened)
    }

    static func hexDump(data: Data, maximumBytes: Int = 1024 * 1024) -> String {
        let bytes = [UInt8](data.prefix(maximumBytes))
        return stride(from: 0, to: bytes.count, by: 16).map { offset in
            let slice = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = slice.map { String(format: "%02X", $0) }.joined(separator: " ").padding(toLength: 47, withPad: " ", startingAt: 0)
            let ascii = slice.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "." }
            return String(format: "%08X  %@  |%@|", offset, hex, String(ascii))
        }.joined(separator: "\n")
    }
}
