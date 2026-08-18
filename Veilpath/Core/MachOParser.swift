import Foundation

enum MachOParser {
    private static let mhMagic64: UInt32 = 0xfeedfacf
    private static let fatMagic: UInt32 = 0xcafebabe
    private static let lcLoadDylib: UInt32 = 0xc
    private static let lcLoadWeakDylib: UInt32 = 0x80000018
    private static let lcReexportDylib: UInt32 = 0x8000001f
    private static let lcLoadUpwardDylib: UInt32 = 0x80000023
    private static let lcRpath: UInt32 = 0x8000001c
    private static let lcUUID: UInt32 = 0x1b
    private static let lcBuildVersion: UInt32 = 0x32
    private static let lcVersionMinIPhoneOS: UInt32 = 0x25
    private static let lcEncryptionInfo64: UInt32 = 0x2c
    private static let lcCodeSignature: UInt32 = 0x1d

    static func parse(_ data: Data) -> MachOInfo? {
        guard data.count >= 4 else { return nil }
        let magicBE = read32(data, 0, little: false)
        var slices: [(offset: Int, size: Int)] = []
        if magicBE == fatMagic, data.count >= 8 {
            let count = Int(read32(data, 4, little: false))
            guard count > 0, count <= 32, data.count >= 8 + count * 20 else { return nil }
            for index in 0..<count {
                let base = 8 + index * 20
                let offset = Int(read32(data, base + 8, little: false))
                let size = Int(read32(data, base + 12, little: false))
                guard offset >= 0, size > 0, offset <= data.count - size else { return nil }
                slices.append((offset, size))
            }
        } else {
            slices = [(0, data.count)]
        }

        var codeSignaturePresent = false
        let architectures = slices.enumerated().compactMap { index, slice -> MachOInfo.Architecture? in
            guard let parsed = parseSlice(data, offset: slice.offset, limit: slice.offset + slice.size) else { return nil }
            codeSignaturePresent = codeSignaturePresent || parsed.codeSigned
            return .init(id: index, name: parsed.architecture, fileType: parsed.fileType, flags: parsed.flags,
                         minimumOS: parsed.minimumOS, sdk: parsed.sdk, uuid: parsed.uuid,
                         dependencies: parsed.dependencies, rpaths: parsed.rpaths, encrypted: parsed.encrypted)
        }
        guard !architectures.isEmpty else { return nil }
        return .init(architectures: architectures, entitlements: extractEntitlements(data), codeSignaturePresent: codeSignaturePresent)
    }

    private static func parseSlice(_ data: Data, offset: Int, limit: Int) -> (architecture: String, fileType: String, flags: String, minimumOS: String?, sdk: String?, uuid: String?, dependencies: [String], rpaths: [String], encrypted: Bool?, codeSigned: Bool)? {
        guard offset + 32 <= limit, read32(data, offset, little: true) == mhMagic64 else { return nil }
        let cpu = read32(data, offset + 4, little: true)
        let subtype = read32(data, offset + 8, little: true)
        let fileType = read32(data, offset + 12, little: true)
        let commands = Int(read32(data, offset + 16, little: true))
        let commandBytes = Int(read32(data, offset + 20, little: true))
        let flags = read32(data, offset + 24, little: true)
        guard commands <= 4096, commandBytes >= 0, offset + 32 <= limit - commandBytes else { return nil }
        var cursor = offset + 32
        var dependencies: [String] = [], rpaths: [String] = []
        var minimumOS: String?, sdk: String?, uuid: String?, encrypted: Bool?, codeSigned = false
        for _ in 0..<commands {
            guard cursor + 8 <= limit else { return nil }
            let command = read32(data, cursor, little: true)
            let size = Int(read32(data, cursor + 4, little: true))
            guard size >= 8, cursor <= limit - size else { return nil }
            switch command {
            case lcLoadDylib, lcLoadWeakDylib, lcReexportDylib, lcLoadUpwardDylib:
                dependencies.append(readCString(data, start: cursor + Int(read32(data, cursor + 8, little: true)), end: cursor + size))
            case lcRpath:
                rpaths.append(readCString(data, start: cursor + Int(read32(data, cursor + 8, little: true)), end: cursor + size))
            case lcUUID where size >= 24:
                let bytes = data[(cursor + 8)..<(cursor + 24)]
                uuid = bytes.map { String(format: "%02X", $0) }.joined().replacingOccurrences(of: "^(........)(....)(....)(....)(............)$", with: "$1-$2-$3-$4-$5", options: .regularExpression)
            case lcBuildVersion where size >= 24:
                minimumOS = version(read32(data, cursor + 12, little: true)); sdk = version(read32(data, cursor + 16, little: true))
            case lcVersionMinIPhoneOS where size >= 16:
                minimumOS = version(read32(data, cursor + 8, little: true)); sdk = version(read32(data, cursor + 12, little: true))
            case lcEncryptionInfo64 where size >= 24:
                encrypted = read32(data, cursor + 16, little: true) != 0
            case lcCodeSignature: codeSigned = true
            default: break
            }
            cursor += size
        }
        let arch = cpu == 0x0100000c ? ((subtype & 0xff) == 2 ? "arm64e" : "arm64") : String(format: "CPU 0x%08X", cpu)
        let fileNames: [UInt32: String] = [1:"Object", 2:"Executable", 3:"Fixed VM Library", 4:"Core", 5:"Preloaded", 6:"Dynamic Library", 8:"Bundle", 9:"Dynamic Library Stub", 10:"dSYM", 11:"Kext Bundle"]
        return (arch, fileNames[fileType] ?? "Type \(fileType)", String(format: "0x%08X", flags), minimumOS, sdk, uuid, dependencies.filter { !$0.isEmpty }, rpaths.filter { !$0.isEmpty }, encrypted, codeSigned)
    }

    private static func extractEntitlements(_ data: Data) -> String? {
        guard let start = data.range(of: Data("<?xml".utf8))?.lowerBound,
              let endRange = data.range(of: Data("</plist>".utf8), in: start..<data.endIndex) else { return nil }
        let end = endRange.upperBound
        guard end - start < 2_000_000 else { return nil }
        let text = String(decoding: data[start..<end], as: UTF8.self)
        return text.contains("<plist") && (text.contains("application-identifier") || text.contains("com.apple")) ? text : nil
    }

    private static func version(_ raw: UInt32) -> String { "\((raw >> 16) & 0xffff).\((raw >> 8) & 0xff).\(raw & 0xff)" }
    private static func read32(_ data: Data, _ offset: Int, little: Bool) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        let bytes = data[offset..<(offset + 4)]
        return little ? bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
                      : bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }
    private static func readCString(_ data: Data, start: Int, end: Int) -> String {
        guard start >= 0, start < end, end <= data.count else { return "" }
        let stop = data[start..<end].firstIndex(of: 0) ?? end
        return String(decoding: data[start..<stop], as: UTF8.self)
    }
}
