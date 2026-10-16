import Foundation

/// Answers "does this record's full lowercase path contain the needle?" for one `path:` term.
///
/// Built once per query in a single pass over records in id order, which visits every folder
/// after its parent (records are appended after their parent, and compaction and loading keep
/// that order). For each folder it stores whether its own full path matches, plus the last
/// `needle.count` bytes of "its path + /": every match that is not inside the folder's path or
/// inside a child's name must include the "/" between them, so it starts in those bytes. A
/// record then matches if its parent's path matched, its name contains the needle, or a match
/// starts in that tail and ends at or after the separator.
///
/// Tails are stored back to back, each only as long as it needs to be (a short folder path has
/// a short tail), so memory stays proportional to the index even for long needles.
final class PathTable {
    /// Needles longer than this cannot match a real path (PATH_MAX is 1024 on macOS), so no
    /// table is built for them and they match nothing.
    static let maxNeedle = 1024

    /// Plain pointers and sizes, so the per-record test does no reference counting.
    struct View {
        let n: Int
        let never: Bool                             // needle too long to match anything
        let hit: UnsafeMutablePointer<Bool>         // per record; meaningful for folders
        let slot: UnsafeMutablePointer<Int32>       // per record: folder slot, or -1
        let tails: UnsafeMutablePointer<UInt8>      // all folder tails, back to back
        let tailStart: UnsafeMutablePointer<Int>    // per folder slot
        let tailLength: UnsafeMutablePointer<Int32> // per folder slot

        /// Does the record's full path (parent path + "/" + name) contain the needle?
        @inline(__always)
        func matches(_ r: Record, start: Int, len: Int, needle: UnsafeBufferPointer<UInt8>, nStart: Int,
                     lower: UnsafeBufferPointer<UInt8>) -> Bool {
            if never { return false }
            let p = Int(r.parent)
            if p >= 0 && hit[p] { return true }
            if containsBytes(lower, start, len, needle, nStart, n) { return true }
            guard p >= 0 else { return false }
            let ps = Int(slot[p])
            guard ps >= 0 else { return false }
            return PathTable.crosses(tails + tailStart[ps], Int(tailLength[ps]), lower, start, len,
                                     needle, nStart, n)
        }
    }

    /// A match that starts in `tail` (the end of "parent path + /") and ends in the name.
    @inline(__always)
    static func crosses(_ tail: UnsafePointer<UInt8>, _ tl: Int, _ lower: UnsafeBufferPointer<UInt8>,
                        _ start: Int, _ len: Int, _ needle: UnsafeBufferPointer<UInt8>, _ nStart: Int,
                        _ n: Int) -> Bool {
        var i = 0
        while i < tl {
            var j = 0
            while j < n {
                let pos = i + j
                let b: UInt8
                if pos < tl {
                    b = tail[pos]
                } else if pos - tl < len {
                    b = lower[start + pos - tl]
                } else {
                    break
                }
                if b != needle[nStart + j] { break }
                j += 1
            }
            if j == n { return true }
            i += 1
        }
        return false
    }

    let view: View
    private let recordCount: Int
    private let folderCount: Int
    private let tailBytes: Int

    init(needle: UnsafeBufferPointer<UInt8>, nStart: Int, n: Int,
         recs: UnsafeBufferPointer<Record>, lower: UnsafeBufferPointer<UInt8>) {
        let never = n > PathTable.maxNeedle
        recordCount = never ? 0 : recs.count
        var folders = 0
        if !never { for r in recs where r.flags & 3 == 1 { folders += 1 } } // folder, not deleted
        folderCount = folders
        let hit = UnsafeMutablePointer<Bool>.allocate(capacity: max(recordCount, 1))
        hit.initialize(repeating: false, count: max(recordCount, 1))
        let slot = UnsafeMutablePointer<Int32>.allocate(capacity: max(recordCount, 1))
        slot.initialize(repeating: -1, count: max(recordCount, 1))
        let tailStart = UnsafeMutablePointer<Int>.allocate(capacity: max(folders, 1))
        tailStart.initialize(repeating: 0, count: max(folders, 1))
        let tailLength = UnsafeMutablePointer<Int32>.allocate(capacity: max(folders, 1))
        tailLength.initialize(repeating: 0, count: max(folders, 1))

        // Build tails in a growable array, then copy them into one allocation.
        var bytes: [UInt8] = []
        let slash = UInt8(ascii: "/")
        var scratch: [UInt8] = []
        var next = 0
        for id in 0..<recordCount {
            let r = recs[id]
            guard r.flags & 3 == 1 else { continue }
            let start = Int(r.lowerStart), len = Int(r.lowerLength)
            scratch.removeAll(keepingCapacity: true)
            var parentTailLength = 0
            if r.parent >= 0 {
                let ps = Int(slot[Int(r.parent)])
                if ps >= 0 {
                    parentTailLength = Int(tailLength[ps])
                    scratch.append(contentsOf: bytes[tailStart[ps]..<tailStart[ps] + parentTailLength])
                }
            }
            // Does this folder's own full path match? Same test as for any record.
            let p = Int(r.parent)
            var matched = p >= 0 && hit[p]
            if !matched { matched = containsBytes(lower, start, len, needle, nStart, n) }
            if !matched && parentTailLength > 0 {
                matched = scratch.withUnsafeBufferPointer {
                    PathTable.crosses($0.baseAddress!, parentTailLength, lower, start, len, needle, nStart, n)
                }
            }
            hit[id] = matched
            // This folder's tail = last n bytes of (parent tail + name + "/").
            scratch.append(contentsOf: lower[start..<start + len])
            if len == 0 || lower[start + len - 1] != slash { scratch.append(slash) }
            let keep = min(scratch.count, n)
            slot[id] = Int32(next)
            tailStart[next] = bytes.count
            tailLength[next] = Int32(keep)
            bytes.append(contentsOf: scratch[(scratch.count - keep)...])
            next += 1
        }
        tailBytes = max(bytes.count, 1)
        let tails = UnsafeMutablePointer<UInt8>.allocate(capacity: tailBytes)
        tails.initialize(repeating: 0, count: tailBytes)
        bytes.withUnsafeBufferPointer { if let base = $0.baseAddress { tails.update(from: base, count: $0.count) } }
        view = View(n: n, never: never, hit: hit, slot: slot, tails: tails,
                    tailStart: tailStart, tailLength: tailLength)
    }

    deinit {
        view.hit.deinitialize(count: max(recordCount, 1)).deallocate()
        view.slot.deinitialize(count: max(recordCount, 1)).deallocate()
        view.tails.deinitialize(count: tailBytes).deallocate()
        view.tailStart.deinitialize(count: max(folderCount, 1)).deallocate()
        view.tailLength.deinitialize(count: max(folderCount, 1)).deallocate()
    }
}
