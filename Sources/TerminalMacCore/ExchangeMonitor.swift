import Foundation
import Darwin

/// The guest can write freely to the shared exchange folder, which lives on the host's disk.
/// This removes files nobody collected and reports when the folder grows past its limits.
/// Paths under the folder are guest-controlled, so nothing here follows symlinks.
public final class ExchangeMonitor {
    public struct Usage: Equatable {
        public var bytes: Int64 = 0
        public var entries = 0
        public var removed = 0
        public var overLimit = false
    }
    private let fd: Int32
    private let maxBytes: Int64
    private let maxEntries: Int
    private let maxDepth = 32

    public init(_ url: URL, maxBytes: Int64 = 1 << 30, maxEntries: Int = 20_000) throws {
        self.maxBytes = maxBytes
        self.maxEntries = maxEntries
        fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure("Cannot open exchange folder \(url.path): \(String(cString: strerror(errno)))") }
    }
    deinit { close(fd) }

    /// Removes top-level files older than `age`, or all of them with `removeAll`, then reports what
    /// remains. The protocol is flat, so directories are only measured, never removed.
    public func sweep(olderThan age: TimeInterval, removeAll: Bool = false, now: Date = Date()) -> Usage {
        var usage = Usage()
        let (names, complete) = list(fd)
        if !complete { usage.overLimit = true }
        for name in names {
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                count(info, into: &usage)
                measure(name, in: fd, depth: 1, into: &usage)
                continue
            }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            if removeAll || now.timeIntervalSince(modified) >= age, unlinkat(fd, name, 0) == 0 { usage.removed += 1 }
            else { count(info, into: &usage) }
        }
        if usage.bytes > maxBytes || usage.entries > maxEntries { usage.overLimit = true }
        return usage
    }

    private func count(_ info: stat, into usage: inout Usage) {
        usage.entries += 1
        // Allocated blocks rather than st_size: sparse files take no real space.
        usage.bytes += Int64(info.st_blocks) * 512
    }
    private func measure(_ name: String, in parent: Int32, depth: Int, into usage: inout Usage) {
        guard depth < maxDepth, usage.entries <= maxEntries else { usage.overLimit = true; return }
        let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard directory >= 0 else { return }
        defer { close(directory) }
        let (names, complete) = list(directory)
        if !complete { usage.overLimit = true }
        for child in names {
            var info = stat()
            guard fstatat(directory, child, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            count(info, into: &usage)
            if (info.st_mode & S_IFMT) == S_IFDIR { measure(child, in: directory, depth: depth + 1, into: &usage) }
        }
    }
    /// Directory entries, stopping at the entry limit. `complete` is false if it stopped early.
    private func list(_ directory: Int32) -> (names: [String], complete: Bool) {
        // Open a fresh description: dup() would share the directory iteration offset.
        let copy = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0, let handle = fdopendir(copy) else { if copy >= 0 { close(copy) }; return ([], true) }
        defer { closedir(handle) }
        var names: [String] = []
        while let entry = readdir(handle) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            if names.count > maxEntries { return (names, false) }
            names.append(name)
        }
        return (names, true)
    }
}
