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
final class PathTable {
    /// Plain pointers and sizes, so the per-record test does no reference counting.
    struct View {
        let n: Int
        let hit: UnsafeMutablePointer<Bool>         // per record; meaningful for folders
        let slot: UnsafeMutablePointer<Int32>       // per record: folder slot, or -1
        let tails: UnsafeMutablePointer<UInt8>      // folders * n
        let tailLength: UnsafeMutablePointer<Int32> // per folder slot

        /// Does the record's full path (parent path + "/" + name) contain the needle?
        @inline(__always)
        func matches(_ r: Record, start: Int, len: Int, needle: UnsafeBufferPointer<UInt8>, nStart: Int,
                     lower: UnsafeBufferPointer<UInt8>) -> Bool {
            let p = Int(r.parent)
            if p >= 0 && hit[p] { return true }
            if containsBytes(lower, start, len, needle, nStart, n) { return true }
            guard p >= 0 else { return false }
            let ps = Int(slot[p])
            guard ps >= 0 else { return false }
            // A match that starts in the parent's tail and ends at or after the separator.
            let tail = tails + ps * n
            let tl = Int(tailLength[ps])
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
    }

    let view: View
    private let recordCount: Int
    private let folderCount: Int

    init(needle: UnsafeBufferPointer<UInt8>, nStart: Int, n: Int,
         recs: UnsafeBufferPointer<Record>, lower: UnsafeBufferPointer<UInt8>) {
        recordCount = recs.count
        var folders = 0
        for r in recs where r.flags & 3 == 1 { folders += 1 } // folder, not deleted
        folderCount = folders
        let hit = UnsafeMutablePointer<Bool>.allocate(capacity: max(recordCount, 1))
        hit.initialize(repeating: false, count: max(recordCount, 1))
        let slot = UnsafeMutablePointer<Int32>.allocate(capacity: max(recordCount, 1))
        slot.initialize(repeating: -1, count: max(recordCount, 1))
        let tails = UnsafeMutablePointer<UInt8>.allocate(capacity: max(folders * n, 1))
        tails.initialize(repeating: 0, count: max(folders * n, 1))
        let tailLength = UnsafeMutablePointer<Int32>.allocate(capacity: max(folders, 1))
        tailLength.initialize(repeating: 0, count: max(folders, 1))
        view = View(n: n, hit: hit, slot: slot, tails: tails, tailLength: tailLength)

        let slash = UInt8(ascii: "/")
        var scratch: [UInt8] = []
        var next = 0
        for id in 0..<recordCount {
            let r = recs[id]
            guard r.flags & 3 == 1 else { continue }
            let start = Int(r.lowerStart), len = Int(r.lowerLength)
            hit[id] = view.matches(r, start: start, len: len, needle: needle, nStart: nStart, lower: lower)
            // This folder's tail = last n bytes of (parent tail + name + "/").
            scratch.removeAll(keepingCapacity: true)
            if r.parent >= 0 {
                let ps = Int(slot[Int(r.parent)])
                if ps >= 0 {
                    scratch.append(contentsOf: UnsafeBufferPointer(start: tails + ps * n, count: Int(tailLength[ps])))
                }
            }
            scratch.append(contentsOf: lower[start..<start + len])
            if len == 0 || lower[start + len - 1] != slash { scratch.append(slash) }
            let keep = min(scratch.count, n)
            slot[id] = Int32(next)
            tailLength[next] = Int32(keep)
            for k in 0..<keep { tails[next * n + k] = scratch[scratch.count - keep + k] }
            next += 1
        }
    }

    deinit {
        view.hit.deinitialize(count: max(recordCount, 1)).deallocate()
        view.slot.deinitialize(count: max(recordCount, 1)).deallocate()
        view.tails.deinitialize(count: max(folderCount * view.n, 1)).deallocate()
        view.tailLength.deinitialize(count: max(folderCount, 1)).deallocate()
    }
}
