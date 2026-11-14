// Run with: xcrun swiftc -D DEBUG Veilpath/Core/WorseQueryWorkspace.swift
// Veilpath/Core/SandboxAccessClient.swift tests/SandboxAccessTests.swift
// -o /tmp/veilpath-access-tests && /tmp/veilpath-access-tests
import Darwin
import Foundation

// Test-only bridge and container stubs. Production sources are compiled intact.
enum ContainerKind: CaseIterable {
    case application, appGroup
    var rootPath: String {
        self == .application ? "/var/mobile/Containers/Data/Application" : "/var/mobile/Containers/Shared/AppGroup"
    }
    var rawValue: String { self == .application ? "Application" : "App Group" }
}
private var badCalls = 0
private var released: [Int64] = []
func bad_query(_ path: UnsafeMutablePointer<CChar>, _ create: Bool, _ group: UnsafeMutablePointer<CChar>?, _ isGroup: Bool) -> Int64 {
    badCalls += 1
    return 100
}
func bad_query_release(_ handle: Int64) { released.append(handle) }
func bad_query_list(_ path: UnsafeMutablePointer<CChar>, _ maximum: Int64) -> UnsafeMutablePointer<CChar>? { nil }
func veilpath_worse_query(_ group: String, _ alternate: Bool) -> Int64 { fatalError("No App Group should exist in the test process") }

@main struct SandboxAccessTests {
    enum ExpectedFailure: Error { case query }

    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw NSError(domain: "SandboxAccessTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func main() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("veilpath-access-tests-\(UUID().uuidString)")
        try files.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: root) }
        let group = root.appendingPathComponent("group")
        let cache = group.appendingPathComponent("Library/Caches")
        let saved = group.appendingPathComponent("Library/.veilpath-worse-query-preserved")
        let target = root.appendingPathComponent("target")
        let alternateTarget = root.appendingPathComponent("alternate-target")
        try files.createDirectory(at: cache, withIntermediateDirectories: true)
        try files.createDirectory(at: target, withIntermediateDirectories: false)
        try files.createDirectory(at: alternateTarget, withIntermediateDirectories: false)
        let sentinel = Data("original cache contents".utf8)
        try sentinel.write(to: cache.appendingPathComponent("sentinel"))
        try Data("target remains unchanged".utf8).write(to: target.appendingPathComponent("target-sentinel"))
        let workspace = WorseQueryWorkspace(root: group)

        try workspace.withStagedCache(target: target.path) {
            try require(try files.destinationOfSymbolicLink(atPath: cache.path) == target.path, "Cache was not staged")
            try require(try Data(contentsOf: saved.appendingPathComponent("sentinel")) == sentinel, "Original cache was not preserved")
        }
        try require(try Data(contentsOf: cache.appendingPathComponent("sentinel")) == sentinel, "Successful query lost cache contents")
        do {
            try workspace.withStagedCache(target: target.path) { throw ExpectedFailure.query }
            fatalError("Expected query failure")
        } catch ExpectedFailure.query {}
        try require(try Data(contentsOf: cache.appendingPathComponent("sentinel")) == sentinel, "Failed query lost cache contents")

        // Simulate process death both before and after link creation.
        for withLink in [false, true] {
            try files.moveItem(at: cache, to: saved)
            if withLink { try files.createSymbolicLink(atPath: cache.path, withDestinationPath: target.path) }
            try workspace.recover()
            try require(try Data(contentsOf: cache.appendingPathComponent("sentinel")) == sentinel, "Interrupted query did not recover")
        }

        // An unexpected replacement directory is retained alongside the original.
        try files.moveItem(at: cache, to: saved)
        try files.createDirectory(at: cache, withIntermediateDirectories: false)
        do { try workspace.recover(); fatalError("Unsafe recovery should fail") }
        catch WorseQueryWorkspace.WorkspaceError.unsafeState {}
        try require(files.fileExists(atPath: saved.appendingPathComponent("sentinel").path), "Unsafe recovery removed original contents")
        try files.removeItem(at: cache)
        try workspace.recover()

        // Refuse pre-existing links instead of deleting or following them.
        try files.moveItem(at: cache, to: root.appendingPathComponent("cache-hold"))
        try files.createSymbolicLink(atPath: cache.path, withDestinationPath: target.path)
        do { try workspace.withStagedCache(target: target.path) {}; fatalError("Existing link should fail") }
        catch WorseQueryWorkspace.WorkspaceError.unsafeState {}
        try require(try String(contentsOf: target.appendingPathComponent("target-sentinel"), encoding: .utf8) == "target remains unchanged", "Link target was modified")
        try files.removeItem(at: cache)
        try files.moveItem(at: root.appendingPathComponent("cache-hold"), to: cache)
        do { try workspace.withStagedCache(target: cache.path) {}; fatalError("Recursive workspace target should fail") }
        catch WorseQueryWorkspace.WorkspaceError.unsupportedTarget {}

        // Concurrent queries must never observe one another's temporary link.
        let failures = FailureRecorder()
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            let selected = index.isMultiple(of: 2) ? target : alternateTarget
            do { try workspace.withStagedCache(target: selected.path) {
                usleep(1_000)
                try require(try files.destinationOfSymbolicLink(atPath: cache.path) == selected.path, "Concurrent staging raced")
            } } catch { failures.append(error) }
        }
        try require(failures.isEmpty, "Concurrent workspace queries failed")
        try require(try Data(contentsOf: cache.appendingPathComponent("sentinel")) == sentinel, "Concurrent queries lost original contents")

        let savedPreference = UserDefaults.standard.object(forKey: "access.backend")
        UserDefaults.standard.set("bad_query", forKey: "access.backend")
        defer { UserDefaults.standard.set(savedPreference, forKey: "access.backend") }
        try require(SandboxAccessClient.selection == .automatic, "A legacy manual preference disabled automatic selection")
        let originalSelection = SandboxAccessClient.selection
        defer { try? SandboxAccessClient.setSelection(originalSelection) }
        try SandboxAccessClient.setSelection(.automatic)
        let grant = try SandboxAccessClient.acquire(.init(path: target.path))
        try require(grant.backend == .badQuery && badCalls == 1, "Automatic mode did not fall back without an App Group")
        do { try SandboxAccessClient.setSelection(.worseQuery); fatalError("Switching with an active grant should fail") }
        catch SandboxAccessError.busy {}
        SandboxAccessClient.release(grant)
        SandboxAccessClient.release(grant)
        try require(released == [100], "Grant was released more than once")
        try SandboxAccessClient.setSelection(.worseQuery)
        do { _ = try SandboxAccessClient.acquire(.init(path: target.path)); fatalError("Manual worse_query should fail without an App Group") }
        catch SandboxAccessError.noAppGroup {}
        try require(badCalls == 1, "Manual mode silently fell back")
        try SandboxAccessClient.setSelection(.badQuery)
        let manual = try SandboxAccessClient.acquire(.init(path: target.path))
        SandboxAccessClient.release(manual)
        try require(manual.backend == .badQuery && badCalls == 2, "Manual bad_query did not use its backend")
        print("PASS: workspace preservation, failure recovery, crash recovery, unsafe-state refusal, concurrent staging, automatic fallback, strict manual selection, active-grant switch protection, and single release")
    }

    final class FailureRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var errors: [Error] = []
        var isEmpty: Bool { lock.withLock { errors.isEmpty } }
        func append(_ error: Error) { lock.withLock { errors.append(error) } }
    }
}
