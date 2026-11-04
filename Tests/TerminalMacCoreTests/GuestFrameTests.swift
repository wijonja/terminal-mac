import XCTest
import Foundation
@testable import TerminalMacCore

final class GuestFrameTests: XCTestCase {
    private func compressedPixels(width: Int, height: Int) throws -> Data {
        // Blue, green, red, unused: the helper's byte order.
        let pixels = Data((0..<(width * height)).flatMap { _ in [UInt8(10), 20, 30, 255] })
        return try (pixels as NSData).compressed(using: .lz4) as Data
    }
    private func mailbox() throws -> Mailbox {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-mac-frame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try Mailbox(url)
    }

    func testBuildsAnImageFromRawPixels() throws {
        let image = try XCTUnwrap(guestFrameImage(compressedPixels(width: 8, height: 4), width: 8, height: 4, bytesPerRow: 32))
        XCTAssertEqual(image.width, 8)
        XCTAssertEqual(image.height, 4)
    }
    func testRejectsInvalidDimensions() throws {
        let data = try compressedPixels(width: 8, height: 4)
        XCTAssertNil(guestFrameImage(data, width: 0, height: 4, bytesPerRow: 32))
        XCTAssertNil(guestFrameImage(data, width: 8, height: 9000, bytesPerRow: 32))
        XCTAssertNil(guestFrameImage(data, width: 8, height: 4, bytesPerRow: 31))
        XCTAssertNil(guestFrameImage(data, width: 8, height: 4, bytesPerRow: 32 + 2000))
        XCTAssertNil(guestFrameImage(data, width: 8, height: 5, bytesPerRow: 32))
    }
    func testScreenshotReadsTheRequestsFrame() throws {
        let box = try mailbox()
        let request = Request(action: "screenshot")
        try box.write(compressedPixels(width: 8, height: 4), named: guestFrameName(request.id))
        let reply = Reply(id: request.id, values: ["format": "bgra-lz4", "image": guestFrameName(request.id), "width": "8", "height": "4", "bytesPerRow": "32"])
        XCTAssertEqual(try guestScreenshot(reply, request: request, mailbox: box).width, 8)
    }
    func testScreenshotRejectsPNGAndForeignFiles() throws {
        let box = try mailbox()
        let request = Request(action: "screenshot")
        let oldHelper = Reply(id: request.id, values: ["image": "image-\(request.id.uuidString).png", "width": "8", "height": "4"])
        XCTAssertThrowsError(try guestScreenshot(oldHelper, request: request, mailbox: box)) {
            XCTAssertTrue($0.localizedDescription.contains("out of date"))
        }
        try box.write(compressedPixels(width: 8, height: 4), named: "secret.bin")
        let foreign = Reply(id: request.id, values: ["format": "bgra-lz4", "image": "secret.bin", "width": "8", "height": "4", "bytesPerRow": "32"])
        XCTAssertThrowsError(try guestScreenshot(foreign, request: request, mailbox: box))
    }
}
