import CoreGraphics
import CoreVideo

/// One look at the scrolling area: BGRA pixels, top row first, that the stitcher owns.
struct ScrollFrame {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixels: [UInt8]

    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    init(width: Int, height: Int, bytesPerRow: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixels = pixels
    }

    /// A copy of a stream frame, so the stream can reuse its buffer straight away.
    init?(pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let stride = width * 4
        var pixels = [UInt8](repeating: 0, count: stride * height)
        pixels.withUnsafeMutableBytes { target in
            for y in 0..<height {
                memcpy(target.baseAddress! + y * stride, base + y * sourceStride, stride)
            }
        }
        self.init(width: width, height: height, bytesPerRow: stride, pixels: pixels)
    }

    /// Any image, redrawn as BGRA. For tests and the command line.
    init?(image: CGImage) {
        let width = image.width, height = image.height, stride = width * 4
        var pixels = [UInt8](repeating: 0, count: stride * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: stride, space: Self.colorSpace, bitmapInfo: Self.bitmapInfo) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, bytesPerRow: stride, pixels: pixels)
    }

    func extent(along axis: ScrollStitcher.Axis) -> Int { axis == .vertical ? height : width }

    /// Rows (vertical) or columns (horizontal) `lines` as an image of their own.
    func image(_ lines: Range<Int>, along axis: ScrollStitcher.Axis) -> CGImage? {
        guard !lines.isEmpty else { return nil }
        let w = axis == .vertical ? width : lines.count
        let h = axis == .vertical ? lines.count : height
        let stride = w * 4
        var bytes = [UInt8](repeating: 0, count: stride * h)
        pixels.withUnsafeBytes { source in
            bytes.withUnsafeMutableBytes { target in
                if axis == .vertical {
                    memcpy(target.baseAddress!, source.baseAddress! + lines.lowerBound * bytesPerRow, stride * h)
                } else {
                    for y in 0..<h {
                        memcpy(target.baseAddress! + y * stride, source.baseAddress! + y * bytesPerRow + lines.lowerBound * 4, stride)
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride, space: Self.colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: Self.bitmapInfo), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Joins frames of an area that is being scrolled into one long image. Each frame is matched
/// against the last one it accepted: every row (or column) is hashed in a few sections across the
/// area, and the shift that lines most of them up is how far the content moved. Working in
/// sections means something fixed over part of the page, like a tab on the side, only spoils its
/// own section. Only what scrolled into view is added. A header or footer that stays put is kept
/// once, and anything else that stays put over moving content is left out.
final class ScrollStitcher {
    enum Axis { case vertical, horizontal }

    enum Step: Equatable {
        /// The first frame.
        case started
        /// Nothing moved.
        case unchanged
        /// The content moved; this many pixels were added (none while new lines settle).
        case extended(Int)
        /// The content moved back; scrolling capture only grows down or to the right.
        case backwards
        /// No overlap with the last frame: scrolled too fast, or the content changed.
        case lost
        /// The image reached the longest Proof will make.
        case full
    }

    private enum Match { case same, moved(Int), backwards, none }

    /// A hash per section across, per line along the axis: `hashes[section][line]`.
    typealias Hashes = [[UInt64]]

    /// Fixed once the content first moves.
    private(set) var axis: Axis?
    /// The pieces of the image so far, in order along the axis.
    private(set) var strips: [CGImage] = []
    /// Pixels along the axis in `strips`.
    private(set) var length = 0
    private(set) var maxLength = 0
    /// Set when the last step shortened the first strip (it ended in a footer).
    private(set) var trimmedFirstStrip = false
    /// How far the content moved in the last step that moved it, in pixels.
    private(set) var lastDistance = 0

    /// Sections across the area.
    static let sections = 6
    /// Lines that repeat more than this within a section (blank space) can't place themselves.
    private static let repeatLimit = 4
    /// A spot flagged as covered stays covered for this many moves.
    private static let coverMemory = 8
    /// Lines either side of a covered spot that count as covered too, for soft edges and shadows.
    private static let coverMargin = 4

    /// Pixels at the far edge left out of matching, where an overlay scroll bar moves.
    private let ignoredEdge: Int
    private var reference: ScrollFrame?
    private var referenceHashes: [Axis: Hashes] = [:]
    /// In the reference frame, everything before this line is already in `strips`.
    private var appendedEnd = 0
    private var hasMoved = false
    /// Moves so far, and for each section and line on screen, the move at which something there
    /// last stayed put over moving content or changed in place (a floating button, a tab on the
    /// side, a toast fading in). Lines are kept out of the image while they're covered.
    private var moveCount = 0
    private var coveredAt: [[Int]] = []

    /// The composite is capped at this many bytes, and at `longestSide` pixels along the axis.
    static let maxBytes = 400_000_000
    static let longestSide = 50_000

    init(ignoredEdge: Int = 0) {
        self.ignoredEdge = ignoredEdge
    }

    func add(_ frame: ScrollFrame) -> Step {
        trimmedFirstStrip = false
        guard let reference else {
            self.reference = frame
            referenceHashes = [.vertical: Self.hashes(frame, along: .vertical, ignoring: ignoredEdge),
                               .horizontal: Self.hashes(frame, along: .horizontal, ignoring: ignoredEdge)]
            if let whole = frame.image(0..<frame.height, along: .vertical) { strips = [whole] }
            return .started
        }
        guard frame.width == reference.width, frame.height == reference.height else { return .lost }

        let candidates: [Axis] = axis.map { [$0] } ?? [.vertical, .horizontal]
        var hashes: [Axis: Hashes] = [:]
        var matches: [Axis: Match] = [:]
        for candidate in candidates {
            let new = Self.hashes(frame, along: candidate, ignoring: ignoredEdge)
            hashes[candidate] = new
            matches[candidate] = Self.match(referenceHashes[candidate] ?? [], new)
            if case .moved = matches[candidate] { break }
        }

        guard let (moved, distance) = candidates.lazy.compactMap({ c -> (Axis, Int)? in
            if case .moved(let d) = matches[c] { return (c, d) } else { return nil }
        }).first else {
            if matches.values.contains(where: { if case .none = $0 { return true } else { return false } }) { return .lost }
            if matches.values.contains(where: { if case .backwards = $0 { return true } else { return false } }) { return .backwards }
            // Nothing moved: keep the newest pixels, in case something on the page changed.
            self.reference = frame
            for (key, value) in hashes { referenceHashes[key] = value }
            return .unchanged
        }

        lastDistance = distance
        moveCount += 1
        let old = referenceHashes[moved] ?? []
        let new = hashes[moved] ?? []
        let extent = frame.extent(along: moved)
        let sections = new.indices
        func sameInPlace(_ line: Int) -> Bool { sections.allSatisfy { old[$0][line] == new[$0][line] } }
        // Lines at the end that didn't move are a footer, added once at the very end.
        var footer = 0
        while footer < extent / 2, sameInPlace(extent - 1 - footer) { footer += 1 }
        let end = extent - footer

        if coveredAt.isEmpty {
            coveredAt = Array(repeating: Array(repeating: Int.min / 2, count: extent), count: new.count)
        }
        // Above the footer, a section that stayed put while the content moved (and isn't blank)
        // or doesn't match where its content was is covered by something.
        var counts = [[UInt64: Int]](repeating: [:], count: new.count)
        for section in sections {
            for hash in new[section][0..<end] { counts[section][hash, default: 0] += 1 }
            for line in 0..<end {
                let hash = new[section][line]
                let stayed = old[section][line] == hash && (counts[section][hash] ?? 0) <= Self.repeatLimit
                let changed = line + distance < extent && old[section][line + distance] != hash
                if stayed || changed { coveredAt[section][line] = moveCount }
            }
        }
        func covered(_ section: Int, _ line: Int) -> Bool {
            let range = max(0, line - Self.coverMargin)...min(extent - 1, line + Self.coverMargin)
            return range.contains { moveCount - coveredAt[section][$0] < Self.coverMemory }
        }
        // The header the content slides under runs from the top down to the first line where the
        // content shows moving with the scroll, and ends with the last line marked as fixed or
        // changing above it. It needn't be the same from one frame to the next: a translucent
        // toolbar is tinted by the page under it (Safari on macOS 26), and a sticky bar can slide
        // in once the page scrolls. Plain stretches say nothing either way, and neither does a
        // change where the content's last view was itself covered (by a tab on the side, say).
        var header = 0
        for line in 0..<(extent / 2) {
            var marked = false, moving = false
            for section in sections {
                let hash = new[section][line]
                let distinctive = (counts[section][hash] ?? 0) <= Self.repeatLimit
                let stayed = distinctive && old[section][line] == hash
                let from = line + distance
                let changed = from < extent && old[section][from] != hash && !covered(section, from)
                if stayed || changed {
                    marked = true
                } else if distinctive, from < extent, old[section][from] == hash {
                    moving = true
                }
            }
            if moving { break }
            if marked { header = line + 1 }
        }

        if !hasMoved {
            hasMoved = true
            axis = moved
            maxLength = min(Self.longestSide, Self.maxBytes / max(1, 4 * (moved == .vertical ? frame.width : frame.height)))
            // The first frame went in whole. Keep it only down to the first covered line (or the
            // footer): what's behind a tab or button there comes into view as the page moves.
            appendedEnd = header
            while appendedEnd < end, !sections.contains(where: { covered($0, appendedEnd) }) { appendedEnd += 1 }
            appendedEnd = max(appendedEnd, min(header + 1, end))
            if let trimmed = reference.image(0..<appendedEnd, along: moved) {
                strips = [trimmed]
                trimmedFirstStrip = true
            }
            length = appendedEnd
        }

        var added = 0
        // Lines of the last frame that are now out of sight (under the header or past the edge)
        // go in from the last frame, covered or not, so nothing is skipped.
        let leaving = min(header + distance, end)
        if appendedEnd < leaving {
            let taken = append(reference, appendedEnd..<leaving, along: moved)
            added += taken
            appendedEnd += taken
        }

        // In the new frame, the content already kept ends here. Lines go in once they've been seen
        // twice, aren't covered, and match their last view wherever that view wasn't covered.
        let keptEnd = max(appendedEnd - distance, header)
        var clearEnd = keptEnd
        while clearEnd < end, clearEnd + distance < extent, sections.allSatisfy({ section in
            !covered(section, clearEnd)
                && (old[section][clearEnd + distance] == new[section][clearEnd] || covered(section, clearEnd + distance))
        }) {
            clearEnd += 1
        }
        let taken = clearEnd > keptEnd && length < maxLength ? append(frame, keptEnd..<clearEnd, along: moved) : 0
        added += taken
        appendedEnd = keptEnd + taken
        self.reference = frame
        referenceHashes = [moved: new]
        if length >= maxLength { return .full }
        return .extended(added)
    }

    /// Adds `lines` of `frame` to the image, as far as the length cap allows. Returns how many went in.
    private func append(_ frame: ScrollFrame, _ lines: Range<Int>, along axis: Axis) -> Int {
        let room = max(0, maxLength - length)
        guard room > 0, let strip = frame.image(lines.lowerBound..<min(lines.upperBound, lines.lowerBound + room), along: axis) else { return 0 }
        strips.append(strip)
        let added = axis == .vertical ? strip.height : strip.width
        length += added
        return added
    }

    /// Everything kept, plus whatever of the last frame is past it (the footer).
    func makeImage() -> CGImage? {
        guard let reference else { return nil }
        let axis = self.axis ?? .vertical
        var pieces = strips
        if hasMoved, appendedEnd < reference.extent(along: axis), let tail = reference.image(appendedEnd..<reference.extent(along: axis), along: axis) {
            pieces.append(tail)
        }
        guard !pieces.isEmpty else { return nil }
        if pieces.count == 1 { return pieces[0] }
        let total = pieces.reduce(0) { $0 + (axis == .vertical ? $1.height : $1.width) }
        let width = axis == .vertical ? reference.width : total
        let height = axis == .vertical ? total : reference.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: ScrollFrame.colorSpace, bitmapInfo: ScrollFrame.bitmapInfo) else { return nil }
        var offset = 0
        for piece in pieces {
            // Core Graphics counts y from the bottom.
            let rect = axis == .vertical
                ? CGRect(x: 0, y: height - offset - piece.height, width: piece.width, height: piece.height)
                : CGRect(x: offset, y: 0, width: piece.width, height: piece.height)
            context.draw(piece, in: rect)
            offset += axis == .vertical ? piece.height : piece.width
        }
        return context.makeImage()
    }

    // MARK: Matching

    /// Hashes per section, per row (vertical) or column (horizontal). The low bits of each channel
    /// are left out, so a pixel that renders a shade differently after scrolling still matches.
    static func hashes(_ frame: ScrollFrame, along axis: Axis, ignoring edge: Int) -> Hashes {
        let mask: UInt32 = 0xF0F0_F0F0
        let prime: UInt64 = 0x100_0000_01B3
        let basis: UInt64 = 0xCBF2_9CE4_8422_2325
        // Sections split the other direction: columns for rows, rows for columns.
        let across = max(1, (axis == .vertical ? frame.width : frame.height) - edge)
        let count = min(sections, across)
        let bounds = (0...count).map { $0 * across / count }
        return frame.pixels.withUnsafeBytes { raw -> Hashes in
            if axis == .vertical {
                var result = Hashes(repeating: [UInt64](repeating: basis, count: frame.height), count: count)
                for y in 0..<frame.height {
                    let row = raw.baseAddress! + y * frame.bytesPerRow
                    for section in 0..<count {
                        var hash = basis
                        var x = bounds[section]
                        while x < bounds[section + 1] {
                            hash = (hash ^ UInt64(row.loadUnaligned(fromByteOffset: x * 4, as: UInt32.self) & mask)) &* prime
                            x += 1
                        }
                        result[section][y] = hash
                    }
                }
                return result
            }
            var columns = [UInt64](repeating: basis, count: frame.width)
            var result = Hashes()
            columns.withUnsafeMutableBufferPointer { columns in
                for section in 0..<count {
                    for x in 0..<columns.count { columns[x] = basis }
                    for y in bounds[section]..<bounds[section + 1] {
                        let row = raw.baseAddress! + y * frame.bytesPerRow
                        var x = 0
                        while x < columns.count {
                            columns[x] = (columns[x] ^ UInt64(row.loadUnaligned(fromByteOffset: x * 4, as: UInt32.self) & mask)) &* prime
                            x += 1
                        }
                    }
                    result.append(Array(columns))
                }
            }
            return result
        }
    }

    /// How far the content moved from `old` to `new`: line `i` of `new` shows line `i + d` of `old`.
    /// Each section votes separately. Lines that repeat (blank space) can't say where they came
    /// from, and lines that stay put (a header, a footer, a tab on the side) can't show movement,
    /// so only distinctive lines that changed vote.
    private static func match(_ old: Hashes, _ new: Hashes) -> Match {
        guard old.count == new.count, let count = old.first?.count, count > 0 else { return .none }
        if old == new { return .same }
        var votes: [Int: Int] = [:]
        var changed = [Int](repeating: 0, count: count)
        var distinctive = 0, still = 0
        for (oldLines, newLines) in zip(old, new) {
            var positions: [UInt64: [Int]] = [:]
            for (index, hash) in oldLines.enumerated() { positions[hash, default: []].append(index) }
            var newCounts: [UInt64: Int] = [:]
            for hash in newLines { newCounts[hash, default: 0] += 1 }
            for (index, hash) in newLines.enumerated() {
                guard (newCounts[hash] ?? 0) <= repeatLimit else { continue }
                distinctive += 1
                if oldLines[index] == hash {
                    still += 1
                    continue
                }
                changed[index] += 1
                guard let found = positions[hash], found.count <= repeatLimit else { continue }
                for position in found where position != index { votes[position - index, default: 0] += 1 }
            }
        }
        if let best = votes.max(by: { $0.value < $1.value || ($0.value == $1.value && abs($0.key) > abs($1.key)) }) {
            // Of the changed lines that could show old content at this shift, most must agree.
            let shift = best.key
            let overlap = shift >= 0 ? 0..<(count - shift) : (-shift)..<count
            let eligible = overlap.reduce(0) { $0 + changed[$1] }
            if best.value >= max(4, eligible / 2) { return shift > 0 ? .moved(shift) : .backwards }
        }
        // Nothing moved as a whole: unchanged if most of what's distinctive stayed where it was,
        // otherwise the content scrolled out of reach (too fast) or was replaced.
        return still * 2 >= distinctive ? .same : .none
    }
}
