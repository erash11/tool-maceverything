import Foundation

/// A part of the index the search window can limit results to. Each scope is plain query text,
/// ANDed with what the person typed, so scoping costs nothing extra in the search engine.
public enum SearchScope: Hashable {
    case all
    /// The Mac's own disk: everything not under /Volumes.
    case thisMac
    /// Synced cloud folders: File Provider (Google Drive, Dropbox, Box), OneDrive, iCloud Drive.
    case cloud
    /// One synced cloud account's folder, by full path: a ~/Library/CloudStorage entry
    /// (Google Drive, OneDrive, Dropbox, Box) or iCloud Drive.
    case cloudFolder(String)
    /// One indexed root other than "/", usually an external drive.
    case drive(String)

    /// Stable text for saving the choice.
    public var id: String {
        switch self {
        case .all: return "all"
        case .thisMac: return "mac"
        case .cloud: return "cloud"
        case .cloudFolder(let path): return "cloud:" + path
        case .drive(let root): return "drive:" + root
        }
    }

    public init?(id: String) {
        switch id {
        case "all": self = .all
        case "mac": self = .thisMac
        case "cloud": self = .cloud
        default:
            if id.hasPrefix("cloud:"), id.count > 6 {
                self = .cloudFolder(String(id.dropFirst(6)))
                return
            }
            guard id.hasPrefix("drive:"), id.count > 6 else { return nil }
            self = .drive(String(id.dropFirst(6)))
        }
    }

    public var title: String {
        switch self {
        case .all: return "All"
        case .thisMac: return "This Mac"
        case .cloud: return "Cloud"
        case .cloudFolder(let path): return SearchScope.cloudTitle(path)
        case .drive(let root): return (root as NSString).lastPathComponent
        }
    }

    /// Provider names for CloudStorage folder prefixes ("GoogleDrive-me@x.com").
    static let providers = ["GoogleDrive": "Google Drive", "OneDrive": "OneDrive", "Dropbox": "Dropbox", "Box": "Box"]

    /// "GoogleDrive-me@x.com" → "Google Drive (me@x.com)", "Box-Box" → "Box", Mobile Documents →
    /// "iCloud Drive". The account stays in the title so two accounts of one provider differ.
    static func cloudTitle(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        if name == "Mobile Documents" { return "iCloud Drive" }
        let parts = name.split(separator: "-", maxSplits: 1).map(String.init)
        guard let first = parts.first else { return name }
        let provider = providers[first] ?? first
        guard parts.count == 2, parts[1] != first else { return provider }
        return "\(provider) (\(parts[1]))"
    }

    /// Folder fragments that mark a synced cloud folder, matched anywhere in the path.
    static let cloudPaths = ["/library/cloudstorage/", "onedrivestandalonesuite/", "/library/mobile documents/"]

    /// The query text this scope adds.
    public var query: String {
        switch self {
        case .all: return ""
        case .thisMac: return "!path:/volumes/"
        case .cloud: return SearchScope.cloudPaths.map { "\"path:\($0)\"" }.joined(separator: " | ")
        case .cloudFolder(let path), .drive(let path): return "\"path:\(path)/\""
        }
    }

    /// The scopes worth offering: Cloud when a synced cloud folder exists in `home`, then each
    /// cloud account on its own, then every root other than "/" as a drive.
    public static func choices(roots: [String], home: String = NSHomeDirectory(),
                               exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                               list: (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] })
                               -> [SearchScope] {
        var out: [SearchScope] = [.all, .thisMac]
        let cloudFolders = ["/Library/CloudStorage", "/Library/Mobile Documents/com~apple~CloudDocs",
                            "/Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite"]
        if cloudFolders.contains(where: { exists(home + $0) }) { out.append(.cloud) }
        let storage = home + "/Library/CloudStorage"
        for name in list(storage).sorted() where !name.hasPrefix(".") {
            out.append(.cloudFolder(storage + "/" + name))
        }
        if exists(home + "/Library/Mobile Documents/com~apple~CloudDocs") {
            out.append(.cloudFolder(home + "/Library/Mobile Documents"))
        }
        for root in roots where root != "/" { out.append(.drive(root)) }
        return out
    }
}

extension Query {
    /// This query with `other`'s groups added, so results must match both.
    public func and(_ other: Query) -> Query {
        Query(groups: groups + other.groups)
    }
}

/// The search window's file-type menu, after Everything's Search > filters. Each one is plain
/// query text ANDed with the search, like a scope, and each has a typed keyword (`audio:` etc.).
public enum FileFilter: String, CaseIterable, Hashable {
    case everything, audio, compressed, document, executable, folder, picture, video

    public var title: String {
        self == .everything ? "Everything" : rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    /// The keyword a search can type for the same filter.
    public var keyword: String? {
        switch self {
        case .everything: return nil
        case .audio: return "audio:"
        case .compressed: return "zip:"
        case .document: return "doc:"
        case .executable: return "exe:"
        case .folder: return "folder:"
        case .picture: return "pic:"
        case .video: return "video:"
        }
    }

    /// The query text this filter adds.
    public var query: String { keyword ?? "" }

    /// Extensions per filter: Everything's lists, plus common Mac formats.
    static let extensions: [FileFilter: [String]] = [
        .audio: ["aac", "ac3", "aif", "aifc", "aiff", "alac", "amr", "ape", "au", "caf", "cda", "dts", "fla", "flac",
                 "it", "m1a", "m2a", "m3u", "m4a", "m4r", "mid", "midi", "mka", "mod", "mp2", "mp3", "mpa", "ogg",
                 "opus", "ra", "rmi", "snd", "spc", "umx", "voc", "wav", "wma", "xm"],
        .compressed: ["7z", "ace", "arj", "bz2", "cab", "cpio", "gz", "gzip", "jar", "lz", "lzma", "rar", "sit",
                      "sitx", "tar", "tbz", "tbz2", "tgz", "txz", "xar", "xip", "xz", "z", "zip", "zst"],
        .document: ["c", "chm", "cpp", "csv", "cxx", "doc", "docm", "docx", "dot", "dotm", "dotx", "epub", "h",
                    "hpp", "htm", "html", "hxx", "ini", "java", "json", "key", "lua", "md", "mht", "mhtml",
                    "numbers", "odp", "ods", "odt", "pages", "pdf", "potm", "potx", "ppam", "pps", "ppsm", "ppsx",
                    "ppt", "pptm", "pptx", "rtf", "rtfd", "sldm", "sldx", "tex", "thmx", "tsv", "txt", "vsd",
                    "wpd", "wps", "wri", "xlam", "xls", "xlsb", "xlsm", "xlsx", "xltm", "xltx", "xml", "yaml",
                    "yml"],
        .executable: ["app", "bat", "cmd", "command", "dmg", "exe", "msi", "msp", "pkg", "scr", "sh", "tool",
                      "workflow", "zsh"],
        .picture: ["ani", "arw", "avif", "bmp", "cr2", "cr3", "dng", "gif", "heic", "heif", "ico", "icns", "jpe",
                   "jpeg", "jpg", "jxl", "nef", "orf", "pcx", "png", "psd", "raf", "raw", "rw2", "svg", "tga",
                   "tif", "tiff", "webp", "wmf"],
        .video: ["3g2", "3gp", "3gp2", "3gpp", "amv", "asf", "avi", "bdmv", "bik", "divx", "drc", "dv", "evo",
                 "f4v", "flc", "fli", "flic", "flv", "hdmov", "ifo", "ivf", "m1v", "m2p", "m2t", "m2ts", "m2v",
                 "m4b", "m4p", "m4v", "mkv", "mod", "mov", "mp2v", "mp4", "mp4v", "mpe", "mpeg", "mpg", "mpls",
                 "mpv2", "mpv4", "mts", "mxf", "ogm", "ogv", "qt", "ram", "rm", "rmvb", "swf", "tod", "tp", "ts",
                 "vob", "webm", "wm", "wmv"],
    ]

    /// The filter a typed keyword names (`audio:`, `zip:`, `doc:`, `exe:`, `pic:`, `video:`).
    static func forKeyword(_ lower: String) -> FileFilter? {
        if lower == "image:" { return .picture } // Everything's other name for pic:
        return allCases.first { $0 != .folder && $0.keyword == lower }
    }
}
