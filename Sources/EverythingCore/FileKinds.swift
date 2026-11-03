import Foundation
import UniformTypeIdentifiers

/// The kind of every record, as the system names it, for `type:`.
struct KindTable {
    /// Per record: the index of its kind.
    var ids: [Int32] = []
    /// Per kind: its lowercase text (searchForm) in `bytes`. Each text is stored once, so many
    /// extensions with no declared type share the one "document".
    var bytes: [UInt8] = []
    var start: [Int] = []
    var length: [Int] = []
    var count: Int { start.count }
    /// (folder?, extension) -> kind index.
    var keys: [FileKinds.Key: Int32] = [:]
    /// Kind text -> kind index.
    var texts: [[UInt8]: Int32] = [:]
}

/// `type:pdf` matches the kind of a file as the system names it ("PDF document", "JPEG image"):
/// the description of the type its extension declares (UTType, in the system's language). A folder
/// is "folder", a package such as an .app its own kind ("application"), and a file whose extension
/// declares no type, or that has none, "document", as in the Finder.
enum FileKinds {
    static let maxExtensionLength = 16

    /// A folder bit and an extension of up to 16 bytes, packed so looking one up allocates nothing.
    /// Extension bytes are never 0, so the packing is unique.
    struct Key: Hashable {
        var low: UInt64 = 0, high: UInt64 = 0
        var folder: Bool

        init(folder: Bool) { self.folder = folder }

        init(_ lower: UnsafeBufferPointer<UInt8>, _ ext: Range<Int>, folder: Bool) {
            self.folder = folder
            for (j, i) in ext.enumerated() {
                if j < 8 { low |= UInt64(lower[i]) << (8 * j) } else { high |= UInt64(lower[i]) << (8 * (j - 8)) }
            }
        }
    }

    @inline(__always)
    static func isExtensionByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x7A) || b == 0x2D || b == 0x5F || b == 0x2B // 0-9 a-z - _ +
    }

    /// Where the extension of a lowercase name lies: the bytes after the last ".", when that dot
    /// isn't the first byte of the name or of a root path's last part (".bashrc" and "/Volumes/.app"
    /// have none) and 1 to 16 lowercase ASCII letters, digits, "-",
    /// "_" or "+" follow it. Anything else (a hash suffix, accents, a trailing dot) has none: no
    /// declared type has such an extension, and it keeps the number of kinds small.
    static func extensionRange(_ lower: UnsafeBufferPointer<UInt8>, _ start: Int, _ len: Int) -> Range<Int>? {
        let end = start + len
        var i = end - 1
        while i > start && end - i <= maxExtensionLength + 1 {
            let b = lower[i]
            if b == UInt8(ascii: ".") {
                // A root's name is its full path: a dot right after "/" starts its last part, so it
                // is a leading dot too ("/Volumes/.app" has none).
                return i + 1 < end && lower[i - 1] != UInt8(ascii: "/") ? (i + 1)..<end : nil
            }
            if !isExtensionByte(b) { return nil }
            i -= 1
        }
        return nil
    }

    /// The kind text (lowercase, searchForm) for a folder or file with this extension ("" for none):
    /// what type: matches and the Type sort orders by.
    static func kindText(extension ext: String, isDirectory: Bool) -> [UInt8] {
        Array(FileIndex.searchForm(kindDisplay(extension: ext, isDirectory: isDirectory)).utf8)
    }

    /// The kind as the Type column shows it: the system's text with its first letter capitalized
    /// ("PDF document", "Folder", "Document"). Lowercased, it is exactly kindText.
    static func kindDisplay(extension ext: String, isDirectory: Bool) -> String {
        var text: String?
        if isDirectory {
            if !ext.isEmpty, let t = UTType(filenameExtension: ext, conformingTo: .directory), t.conforms(to: .package) {
                text = t.localizedDescription
            }
            text = text ?? UTType.folder.localizedDescription ?? "folder"
        } else if !ext.isEmpty, let t = UTType(filenameExtension: ext), !t.isDynamic {
            text = t.localizedDescription
        }
        let shown = text ?? "document"
        return shown.prefix(1).uppercased() + shown.dropFirst()
    }

    /// The extension of a name (lowercase; "" for none), by extensionRange's rule.
    static func extensionString(ofName name: String) -> String {
        let lower = Array(FileIndex.searchForm(name).utf8)
        return lower.withUnsafeBufferPointer { buf in
            extensionRange(buf, 0, buf.count).map { String(decoding: UnsafeBufferPointer(rebasing: buf[$0]), as: UTF8.self) } ?? ""
        }
    }

    /// The Type column's text for a result, the same kind the daemon's type: and Type sort use.
    public static func kindName(ofName name: String, isDirectory: Bool) -> String {
        kindDisplay(extension: extensionString(ofName: name), isDirectory: isDirectory)
    }

    /// The Extension column's text for a result: "" for folders and names without one, as the
    /// Extension sort orders them (first).
    public static func extensionName(ofName name: String, isDirectory: Bool) -> String {
        isDirectory ? "" : extensionString(ofName: name)
    }

    /// The first 16 bytes of an extension packed big-endian, so comparing (high, low) as numbers is
    /// comparing the bytes in order; no extension is (0, 0) and sorts first. (Key packs for hashing,
    /// not order.)
    static func orderedPack(_ lower: UnsafeBufferPointer<UInt8>, _ ext: Range<Int>) -> (UInt64, UInt64) {
        var high: UInt64 = 0, low: UInt64 = 0
        for (j, i) in ext.enumerated() where j < 16 {
            if j < 8 { high |= UInt64(lower[i]) << (8 * (7 - j)) } else { low |= UInt64(lower[i]) << (8 * (15 - j)) }
        }
        return (high, low)
    }
}

extension FileIndex {
    /// Each record's kind (see FileKinds). Built on the first type: search, then extended for new
    /// records, as tempMask is: a record's name and folder bit never change, and deleted records are
    /// skipped by the search. Compaction (adopt) drops it. Costs 4 bytes per record, plus one
    /// system lookup per distinct extension, once.
    func kindTable() -> KindTable {
        kindLock.lock()
        defer { kindLock.unlock() }
        var table = kindCache ?? KindTable()
        if table.ids.count == records.count { return table }
        kindCache = nil // one owner while it grows, so appending doesn't copy the arrays
        var ids = table.ids
        table.ids = []
        ids.reserveCapacity(records.count)
        func kind(_ key: FileKinds.Key, _ ext: String) -> Int32 {
            if let known = table.keys[key] { return known }
            let text = FileKinds.kindText(extension: ext, isDirectory: key.folder)
            let id: Int32
            if let shared = table.texts[text] {
                id = shared
            } else {
                id = Int32(table.count)
                table.start.append(table.bytes.count)
                table.length.append(text.count)
                table.bytes += text
                table.texts[text] = id
            }
            table.keys[key] = id
            return id
        }
        let plainFolder = kind(FileKinds.Key(folder: true), ""), plainFile = kind(FileKinds.Key(folder: false), "")
        records.withUnsafeBufferPointer { recs in
        lowerNames.withUnsafeBufferPointer { lower in
            for i in ids.count..<recs.count {
                let r = recs[i]
                let dir = r.flags & 1 != 0
                guard let ext = FileKinds.extensionRange(lower, Int(r.lowerStart), Int(r.lowerLength)) else {
                    ids.append(dir ? plainFolder : plainFile)
                    continue
                }
                let key = FileKinds.Key(lower, ext, folder: dir)
                if let known = table.keys[key] {
                    ids.append(known)
                } else {
                    ids.append(kind(key, String(decoding: UnsafeBufferPointer(rebasing: lower[ext]), as: UTF8.self)))
                }
            }
        }}
        table.ids = ids
        kindCache = table
        return table
    }
}
