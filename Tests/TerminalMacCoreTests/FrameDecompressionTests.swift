import XCTest
import Foundation
@testable import TerminalMacCore

final class FrameDecompressionTests: XCTestCase {
    func testRoundTripsTheHelperFormat() throws {
        let pixels = Data((0..<40_000).map { UInt8($0 % 7) })
        // The same call the guest helper uses to compress frames.
        let compressed = try (pixels as NSData).compressed(using: .lz4) as Data
        XCTAssertEqual(decompressedFrame(compressed, expectedSize: pixels.count), pixels)
    }
    func testRejectsWrongSizesAndGarbage() throws {
        let pixels = Data(count: 1_000_000)
        let compressed = try (pixels as NSData).compressed(using: .lz4) as Data
        XCTAssertLessThan(compressed.count, 10_000)
        XCTAssertNil(decompressedFrame(compressed, expectedSize: 1_000), "A frame larger than it claims must not be accepted")
        XCTAssertNil(decompressedFrame(compressed, expectedSize: 2_000_000), "A frame smaller than it claims must not be accepted")
        XCTAssertNil(decompressedFrame(Data([1, 2, 3, 4, 5, 6, 7, 8]), expectedSize: 1_000))
        XCTAssertNil(decompressedFrame(Data(), expectedSize: 1_000))
        XCTAssertNil(decompressedFrame(compressed, expectedSize: 0))
    }
}
