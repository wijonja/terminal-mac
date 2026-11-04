import CoreGraphics
import Foundation

/// Builds an image from lz4-compressed BGRA rows sent by the guest. The host only ever receives raw
/// pixels from the guest, so guest-supplied data never reaches an image file parser on the host.
public func guestFrameImage(_ compressed: Data, width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
    guard (1...8192).contains(width), (1...8192).contains(height), (width * 4...width * 4 + 1024).contains(bytesPerRow),
          let pixels = decompressedFrame(compressed, expectedSize: bytesPerRow * height),
          let provider = CGDataProvider(data: pixels as CFData), let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: colorSpace,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}

/// The mailbox name of the frame belonging to a request.
public func guestFrameName(_ id: UUID) -> String { "image-\(id.uuidString).bin" }

/// Reads the still image named in a screenshot reply. The caller removes the file afterwards.
public func guestScreenshot(_ reply: Reply, request: Request, mailbox: Mailbox) throws -> CGImage {
    guard reply.values["format"] == "bgra-lz4" else {
        throw Failure("The guest helper is out of date. Open /Volumes/My Shared Files/tools/TerminalMacGuest.app in the VM to update it")
    }
    let name = guestFrameName(request.id)
    guard reply.values["image"] == name, let width = Int(reply.values["width"] ?? ""), let height = Int(reply.values["height"] ?? ""),
          let bytesPerRow = Int(reply.values["bytesPerRow"] ?? ""), let data = try mailbox.read(name, limit: 64 * 1024 * 1024),
          let image = guestFrameImage(data, width: width, height: height, bytesPerRow: bytesPerRow) else {
        throw Failure("The guest helper returned an invalid screenshot")
    }
    return image
}
