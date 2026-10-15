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
    let n: Int                                  // needle length
    let tailCapacity: Int                       // n
    let hit: UnsafeMutablePointer<Bool>         // per record; meaningful for folders
    let slot: UnsafeMutablePointer<Int32>       // per record: folder slot, or -1
    let tails: UnsafeMutablePointer<UInt8>      // folders * tailCapacity
    let tailLength: UnsafeMutablePointer<Int32> // per folder slot
    let recordCount: Int
    let folderCount: Int

    init(needle: UnsafeBufferPointer<UInt8>, nStart: Int, n: Int,
         recs: UnsafeBufferPointer<Record>, lower: UnsafeBufferPointer<UInt8>) {
        self.n = n
        tailCapacity = n
        recordCount = recs.count
        var folders = 0
        for r in recs where r.flags & 3 == 1 { folders += 1 } // folder, not deleted
        folderCount = folders
        hit = .allocate(capacity: max(recordCount, 1))
        hit.initialize(repeating: false, count: max(recordCount, 1))
        slot = .allocate(capacity: max(recordCount, 1))
        slot.initialize(repeating: -1, count: max(recordCount, 1))
        tails = .allocate(capacity: max(folders * tailCapacity, 1))
        tailLength = .allocate(capacity: max(folders, 1))
        tailLength.initialize(repeating: 0, count: max(folders, 1))

        let slash = UInt8(ascii: "/")
        var scratch: [UInt8] = []
        var next: Int32 = 0
        for id in 0..<recordCount {
            let r = recs[id]
            guard r.flags & 3 == 1 else { continue }
            let start = Int(r.lowerStart), len = Int(r.lowerLength)
            hit[id] = matches(r, start: start, len: len, needle: needle, nStart: nStart, lower: lower)
            // This folder's tail = last n bytes of parent tail + name + "/".
            scratch.removeAll(keepingCapacity: true)
            if r.parent >= 0, case let ps = Int(slot[Int(r.parent)]), ps >= 0 {
                let pl = Int(tailLength[ps])
                scratch.append(contentsOf: UnsafeBufferPointer(start: tails + ps * tailCapacity, count: pl))
            }
            scratch.append(contentsOf: lower[start..<start + len])
            if len == 0 || lower[start + len - 1] != slash { scratch.append(slash) }
            let keep = min(scratch.count, tailCapacity)
            let s = Int(next)
            next += 1
            slot[id] = Int32(s)
            tailLength[s] = Int32(keep)
            for k in 0..<keep { tails[s * tailCapacity + k] = scratch[scratch.count - keep + k] }
        }
    }

    deinit {
        hit.deallocate()
        slot.deallocate()
        tails.deallocate()
        tailLength.deallocate()
    }

    /// Does the record's full path (parent path + "/" + name) contain the needle?
    @inline(__always)
    func matches(_ r: Record, start: Int, len: Int, needle: UnsafeBufferPointer<UInt8>, nStart: Int,
                 lower: UnsafeBufferPointer<UInt8>) -> Bool {
        let p = Int(r.parent)
        if p >= 0 && hit[p] { return true }
        if containsBytes(lower, start, len, needle, nStart, n) { return true }
        guard p >= 0, case let ps = Int(slot[p]), ps >= 0 else { return false }
        // A match that starts in the parent's tail and ends in the name.
        let tail = tails + ps * tailCapacity
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
