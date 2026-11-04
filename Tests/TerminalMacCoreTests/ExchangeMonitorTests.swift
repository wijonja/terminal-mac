import XCTest
import Foundation
@testable import TerminalMacCore

final class ExchangeMonitorTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-mac-exchange-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func file(_ url: URL, size: Int = 64 * 1024, ageSeconds: TimeInterval = 0) throws {
        try Data(repeating: 7, count: size).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ageSeconds)], ofItemAtPath: url.path)
    }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testRemovesOnlyStaleFiles() throws {
        let root = try folder()
        let old = root.appendingPathComponent("reply-old.json"), fresh = root.appendingPathComponent("reply-new.json")
        try file(old, ageSeconds: 1000); try file(fresh)
        let usage = try ExchangeMonitor(root).sweep(olderThan: 300)
        XCTAssertFalse(exists(old))
        XCTAssertTrue(exists(fresh))
        XCTAssertEqual(usage.removed, 1)
        XCTAssertEqual(usage.entries, 1)
        XCTAssertFalse(usage.overLimit)
    }
    func testRemovingASymlinkLeavesItsTargetAlone() throws {
        let root = try folder(), outside = try folder()
        let target = outside.appendingPathComponent("precious")
        try file(target)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        _ = try ExchangeMonitor(root).sweep(olderThan: 0, removeAll: true)
        XCTAssertFalse((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
        XCTAssertTrue(exists(target))
    }
    func testSymlinkedDirectoryIsNotMeasured() throws {
        let root = try folder(), outside = try folder()
        try file(outside.appendingPathComponent("large"), size: 1_000_000)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        let usage = try ExchangeMonitor(root, maxBytes: 100_000).sweep(olderThan: 10_000)
        XCTAssertFalse(usage.overLimit)
    }
    func testReportsOversizedFolderIncludingSubdirectories() throws {
        let root = try folder()
        let nested = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try file(nested.appendingPathComponent("large"), size: 1_000_000)
        XCTAssertTrue(try ExchangeMonitor(root, maxBytes: 100_000).sweep(olderThan: 300).overLimit)
    }
    func testReportsTooManyEntries() throws {
        let root = try folder()
        for index in 0..<20 { try file(root.appendingPathComponent("f\(index)"), size: 1) }
        XCTAssertTrue(try ExchangeMonitor(root, maxEntries: 5).sweep(olderThan: 300).overLimit)
    }
    func testRemoveAllKeepsDirectories() throws {
        let root = try folder()
        let directory = root.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try file(root.appendingPathComponent("frame.bin"))
        let usage = try ExchangeMonitor(root).sweep(olderThan: 300, removeAll: true)
        XCTAssertEqual(usage.removed, 1)
        XCTAssertTrue(exists(directory))
    }
}
