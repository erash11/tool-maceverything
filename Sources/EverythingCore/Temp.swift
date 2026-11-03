import Foundation

/// Temporary and generated files: what coding tools, editors and browsers leave behind, and the
/// Trash. The
/// `temp:` keyword matches them and everything inside a temp folder; the search window hides
/// them with `!temp:` unless "Show temp files" is ticked. Nothing is left out of the index.
enum TempFiles {
    /// Folders whose whole contents count as temp (dependency stores, build output, caches).
    static let folderNames: [[UInt8]] = [
        "node_modules", ".git", "__pycache__", ".venv", ".mypy_cache", ".pytest_cache", ".ruff_cache",
        ".next", ".nuxt", ".turbo", ".parcel-cache", ".svelte-kit", ".angular", ".gradle", ".build",
        "deriveddata", ".tox", ".nox", ".eggs", ".cache", ".npm", ".pnpm-store", ".yarn", ".terraform",
        ".swc", ".expo", ".dart_tool", ".ipynb_checkpoints", ".nyc_output",
        // The Trash (~/.Trash, and .Trashes on other drives): a file moved there, from the Finder or
        // the window's Move to Trash, leaves the results like a deleted one.
        ".trash", ".trashes",
    ].map { Array($0.utf8) }

    /// System temp folders, by full path.
    static let folderPaths = ["/private/tmp", "/private/var/tmp", "/private/var/folders"]

    static let suffixes: [[UInt8]] = [
        ".tmp", ".temp", ".swp", ".swo", ".swx", ".pyc", ".pyo", ".crdownload", ".part", ".partial",
        ".pid", ".egg-info", "~",
    ].map { Array($0.utf8) }

    static let prefixes: [[UInt8]] = ["~$", ".~lock.", ".#"].map { Array($0.utf8) }

    static let exactNames: [[UInt8]] = [".ds_store", "thumbs.db", "desktop.ini"].map { Array($0.utf8) }

    @inline(__always)
    static func equal(_ lower: UnsafeBufferPointer<UInt8>, _ start: Int, _ len: Int, _ word: [UInt8]) -> Bool {
        if word.count != len { return false }
        var i = 0
        while i < len { if lower[start + i] != word[i] { return false }; i += 1 }
        return true
    }

    @inline(__always)
    static func hasSuffix(_ lower: UnsafeBufferPointer<UInt8>, _ start: Int, _ len: Int, _ word: [UInt8]) -> Bool {
        if word.count > len { return false }
        return equal(lower, start + len - word.count, word.count, word)
    }

    @inline(__always)
    static func hasPrefix(_ lower: UnsafeBufferPointer<UInt8>, _ start: Int, _ len: Int, _ word: [UInt8]) -> Bool {
        if word.count > len { return false }
        return equal(lower, start, word.count, word)
    }

    /// Whether one record's own name marks it as temp.
    static func isTemp(_ r: Record, _ lower: UnsafeBufferPointer<UInt8>) -> Bool {
        let start = Int(r.lowerStart), len = Int(r.lowerLength)
        if len == 0 { return false }
        if r.flags & 1 != 0 {
            for w in folderNames where equal(lower, start, len, w) { return true }
        }
        for w in suffixes where hasSuffix(lower, start, len, w) { return true }
        for w in prefixes where hasPrefix(lower, start, len, w) { return true }
        for w in exactNames where equal(lower, start, len, w) { return true }
        return false
    }
}

extension FileIndex {
    /// One byte per record: 1 when it is temp or inside a temp folder. Parents always come
    /// before their children, so one pass in id order is enough. Records are only appended and
    /// a name never changes, so the cached mask is extended for new records instead of rebuilt;
    /// deleted records are skipped by the search anyway. Compaction (adopt) drops the cache.
    func tempMask() -> [UInt8] {
        tempMaskLock.lock()
        defer { tempMaskLock.unlock() }
        var mask = tempMaskCache?.mask ?? []
        if mask.count == records.count { return mask }
        let first = mask.count
        mask.append(contentsOf: repeatElement(0, count: records.count - first))
        for path in TempFiles.folderPaths {
            if let id = lookup(path), Int(id) >= first { mask[Int(id)] = 1 }
        }
        records.withUnsafeBufferPointer { recs in
        lowerNames.withUnsafeBufferPointer { lower in
            for i in first..<recs.count where mask[i] == 0 {
                let r = recs[i]
                if (r.parent >= 0 && mask[Int(r.parent)] != 0) || TempFiles.isTemp(r, lower) { mask[i] = 1 }
            }
        }}
        tempMaskCache = (records.count, deletedCount, mask)
        return mask
    }
}
