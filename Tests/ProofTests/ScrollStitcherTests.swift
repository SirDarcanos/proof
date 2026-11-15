import XCTest
@testable import Proof

final class ScrollStitcherTests: XCTestCase {
    /// A long page of "text": lines of noisy word blocks with blank space between them, so most
    /// rows are distinctive and the gaps aren't, like a real page.
    private func page(width: Int, height: Int, seed: UInt64) -> [UInt8] {
        var rng = seed
        func next() -> UInt64 {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return rng >> 33
        }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var y = 0
        while y < height {
            let lineHeight = 10 + Int(next() % 8)
            var x = 8
            while x < width - 8 {
                let word = 12 + Int(next() % 40)
                for row in y..<min(y + lineHeight, height) {
                    for column in x..<min(x + word, width - 8) {
                        let value = UInt8(next() % 200)
                        let i = (row * width + column) * 4
                        pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value &+ 40
                    }
                }
                x += word + 6
            }
            // Blank space between lines, sometimes a paragraph break.
            y += lineHeight + 4 + (next() % 5 == 0 ? 30 : 0)
        }
        return pixels
    }

    private struct Layout {
        let pageWidth: Int, pageHeight: Int
        let viewWidth: Int, viewHeight: Int
        let header: Int, footer: Int
        let axis: ScrollStitcher.Axis
    }

    /// A button floating over the content at a fixed place on screen (`rect` is x, y, width,
    /// height in the view), shown in some frames, with a shade that changes as if fading in
    /// unless it's `steady`.
    private struct Overlay {
        let rect: (x: Int, y: Int, width: Int, height: Int)
        let frames: Set<Int>
        var steady = false
    }

    /// What's on screen with the page scrolled by `offset`, with a header and footer that stay put.
    private func frame(_ page: [UInt8], _ layout: Layout, offset: Int, chrome: [UInt8], overlayShade: UInt8? = nil,
                       overlay: Overlay? = nil) -> ScrollFrame {
        let w = layout.viewWidth, h = layout.viewHeight
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let sticky = layout.axis == .vertical ? (y < layout.header || y >= h - layout.footer) : (x < layout.header || x >= w - layout.footer)
                let source: Int
                if sticky {
                    source = (y * w + x) * 4
                    for c in 0..<4 { pixels[(y * w + x) * 4 + c] = chrome[source + c] }
                } else {
                    let px = layout.axis == .vertical ? x : x + offset
                    let py = layout.axis == .vertical ? y + offset : y
                    let i = (py * layout.pageWidth + px) * 4
                    for c in 0..<4 { pixels[(y * w + x) * 4 + c] = page[i + c] }
                }
            }
        }
        if let overlay, let shade = overlayShade {
            let r = overlay.rect
            for y in r.y..<(r.y + r.height) {
                for x in r.x..<(r.x + r.width) {
                    let i = (y * w + x) * 4
                    pixels[i] = 230; pixels[i + 1] = shade; pixels[i + 2] = 20
                }
            }
        }
        return ScrollFrame(width: w, height: h, bytesPerRow: w * 4, pixels: pixels)
    }

    /// The header, the page from under the header to the end of the last view, then the footer.
    private func expected(_ page: [UInt8], _ layout: Layout, lastOffset: Int, chrome: [UInt8]) -> ScrollFrame {
        let vertical = layout.axis == .vertical
        let length = (vertical ? layout.viewHeight : layout.viewWidth) + lastOffset
        let w = vertical ? layout.viewWidth : length
        let h = vertical ? length : layout.viewHeight
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let viewLength = vertical ? layout.viewHeight : layout.viewWidth
        for y in 0..<h {
            for x in 0..<w {
                let along = vertical ? y : x
                let i: Int
                if along < layout.header {
                    i = (y * layout.viewWidth + x) * 4
                    for c in 0..<4 { pixels[(y * w + x) * 4 + c] = chrome[i + c] }
                } else if along >= length - layout.footer {
                    let inView = along - (length - viewLength)
                    i = vertical ? (inView * layout.viewWidth + x) * 4 : (y * layout.viewWidth + inView) * 4
                    for c in 0..<4 { pixels[(y * w + x) * 4 + c] = chrome[i + c] }
                } else {
                    i = (y * layout.pageWidth + x) * 4
                    for c in 0..<4 { pixels[(y * w + x) * 4 + c] = page[i + c] }
                }
            }
        }
        return ScrollFrame(width: w, height: h, bytesPerRow: w * 4, pixels: pixels)
    }

    private func run(_ layout: Layout, offsets: [Int], steps expectedSteps: [ScrollStitcher.Step]? = nil, lastOffset: Int,
                     overlay: Overlay? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let page = page(width: layout.pageWidth, height: layout.pageHeight, seed: 42)
        // Header and footer: their own "text", so they're distinctive too.
        let chrome = self.page(width: layout.viewWidth, height: layout.viewHeight, seed: 7)
        let stitcher = ScrollStitcher(ignoredEdge: 0)
        let steps = offsets.enumerated().map { index, offset in
            let shade = overlay?.frames.contains(index) == true ? UInt8(overlay!.steady ? 90 : 60 + index * 20) : nil
            return stitcher.add(frame(page, layout, offset: offset, chrome: chrome, overlayShade: shade, overlay: overlay))
        }
        // How much each step adds depends on blank lines near the footer, so only the kind is compared.
        func kind(_ step: ScrollStitcher.Step) -> ScrollStitcher.Step { if case .extended = step { return .extended(0) } else { return step } }
        if let expectedSteps { XCTAssertEqual(steps.map(kind), expectedSteps.map(kind), file: file, line: line) }
        XCTAssertEqual(stitcher.axis, offsets.count > 1 ? layout.axis : nil, file: file, line: line)
        guard let image = stitcher.makeImage(), let result = ScrollFrame(image: image) else {
            return XCTFail("no image", file: file, line: line)
        }
        var want = expected(page, layout, lastOffset: lastOffset, chrome: chrome)
        if let overlay, overlay.steady, overlay.frames.contains(offsets.count - 1) {
            // Still on screen at the end, so it shows once, in the last view.
            let r = overlay.rect, top = want.height - layout.viewHeight + r.y
            var pixels = want.pixels
            for y in top..<(top + r.height) {
                for x in r.x..<(r.x + r.width) {
                    let i = (y * want.width + x) * 4
                    pixels[i] = 230; pixels[i + 1] = 90; pixels[i + 2] = 20
                }
            }
            want = ScrollFrame(width: want.width, height: want.height, bytesPerRow: want.bytesPerRow, pixels: pixels)
        }
        XCTAssertEqual(result.width, want.width, file: file, line: line)
        XCTAssertEqual(result.height, want.height, file: file, line: line)
        XCTAssertTrue(result.pixels == want.pixels, "pixels differ", file: file, line: line)
    }

    func testVerticalScrollKeepsHeaderAndFooterOnce() {
        let layout = Layout(pageWidth: 320, pageHeight: 3000, viewWidth: 320, viewHeight: 400, header: 40, footer: 30, axis: .vertical)
        run(layout, offsets: [0, 0, 60, 150, 151, 300, 520, 700],
            steps: [.started, .unchanged, .extended(60), .extended(90), .extended(1), .extended(149), .extended(220), .extended(180)],
            lastOffset: 700)
    }

    func testScrollingTooFastIsLostThenRecovers() {
        let layout = Layout(pageWidth: 320, pageHeight: 3000, viewWidth: 320, viewHeight: 400, header: 0, footer: 0, axis: .vertical)
        run(layout, offsets: [0, 100, 700, 380, 500], steps: [.started, .extended(100), .lost, .extended(280), .extended(120)], lastOffset: 500)
    }

    func testScrollingBackIsIgnored() {
        let layout = Layout(pageWidth: 320, pageHeight: 3000, viewWidth: 320, viewHeight: 400, header: 24, footer: 0, axis: .vertical)
        run(layout, offsets: [0, 200, 120, 260], steps: [.started, .extended(200), .backwards, .extended(60)], lastOffset: 260)
    }

    func testFloatingButtonIsLeftOut() {
        // A button near the bottom right fades in partway through and is gone by the last frame,
        // so none of it should end up in the image.
        let layout = Layout(pageWidth: 320, pageHeight: 3000, viewWidth: 320, viewHeight: 400, header: 30, footer: 0, axis: .vertical)
        let overlay = Overlay(rect: (x: 200, y: 330, width: 90, height: 40), frames: Set(2...7))
        run(layout, offsets: [0, 40, 100, 150, 210, 260, 330, 380, 440, 500], lastOffset: 500, overlay: overlay)
    }

    func testTabOnTheSideShowsOnceAtTheEnd() {
        // A tab fixed halfway down the right edge for the whole capture, with steps a third of the
        // view, like auto-scroll: it belongs only in the last view, not the first or in between.
        let layout = Layout(pageWidth: 320, pageHeight: 3000, viewWidth: 320, viewHeight: 420, header: 0, footer: 0, axis: .vertical)
        let overlay = Overlay(rect: (x: 290, y: 160, width: 24, height: 120), frames: Set(0..<9), steady: true)
        run(layout, offsets: (0..<9).map { $0 * 140 }, lastOffset: 1120, overlay: overlay)
    }

    func testHorizontalScroll() {
        // A wide page: the same generator, read across.
        let layout = Layout(pageWidth: 3000, pageHeight: 300, viewWidth: 500, viewHeight: 300, header: 0, footer: 20, axis: .horizontal)
        run(layout, offsets: [0, 80, 230, 600], lastOffset: 600)
    }

    func testBlankAreaNeverMoves() {
        let blank = ScrollFrame(width: 200, height: 200, bytesPerRow: 800, pixels: [UInt8](repeating: 255, count: 200 * 200 * 4))
        let stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.add(blank), .started)
        XCTAssertEqual(stitcher.add(blank), .unchanged)
        XCTAssertEqual(stitcher.makeImage()?.height, 200)
    }
}
