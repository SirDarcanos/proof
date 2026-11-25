import AppKit
import XCTest
@testable import Proof

final class QuickAccessTests: XCTestCase {
    @MainActor
    func testTrashRejectsAReplacementAtTheSavedPath() throws {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: folder) }
        let saved = folder.appendingPathComponent("capture.png")
        let moved = folder.appendingPathComponent("moved.png")
        try Data([1]).write(to: saved)
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                              bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let capture = Capture(image: try XCTUnwrap(context.makeImage()), pointSize: CGSize(width: 1, height: 1),
                              kind: .area, appName: nil, date: Date())
        let item = QuickAccessItem(capture: capture, savedURL: saved)
        XCTAssertEqual(try item.validatedSavedURLForTrash(), saved)

        try files.moveItem(at: saved, to: moved)
        XCTAssertThrowsError(try item.validatedSavedURLForTrash())
        try Data([2]).write(to: saved)
        XCTAssertThrowsError(try item.validatedSavedURLForTrash())

        // A subsequent editor save can replace the file at the same URL.
        item.savedURL = saved
        XCTAssertEqual(try item.validatedSavedURLForTrash(), saved)
    }
}
