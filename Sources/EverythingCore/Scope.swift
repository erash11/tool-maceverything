import Foundation

/// A part of the index the search window can limit results to. Each scope is plain query text,
/// ANDed with what the person typed, so scoping costs nothing extra in the search engine.
public enum SearchScope: Hashable {
    case all
    /// The Mac's own disk: everything not under /Volumes.
    case thisMac
    /// Synced cloud folders: File Provider (Google Drive, Dropbox, Box), OneDrive, iCloud Drive.
    case cloud
    /// One indexed root other than "/", usually an external drive.
    case drive(String)

    /// Stable text for saving the choice.
    public var id: String {
        switch self {
        case .all: return "all"
        case .thisMac: return "mac"
        case .cloud: return "cloud"
        case .drive(let root): return "drive:" + root
        }
    }

    public init?(id: String) {
        switch id {
        case "all": self = .all
        case "mac": self = .thisMac
        case "cloud": self = .cloud
        default:
            guard id.hasPrefix("drive:"), id.count > 6 else { return nil }
            self = .drive(String(id.dropFirst(6)))
        }
    }

    public var title: String {
        switch self {
        case .all: return "All"
        case .thisMac: return "This Mac"
        case .cloud: return "Cloud"
        case .drive(let root): return (root as NSString).lastPathComponent
        }
    }

    /// Folder fragments that mark a synced cloud folder, matched anywhere in the path.
    static let cloudPaths = ["/library/cloudstorage/", "onedrivestandalonesuite/", "/library/mobile documents/"]

    /// The query text this scope adds.
    public var query: String {
        switch self {
        case .all: return ""
        case .thisMac: return "!path:/volumes/"
        case .cloud: return SearchScope.cloudPaths.map { "\"path:\($0)\"" }.joined(separator: " | ")
        case .drive(let root): return "\"path:\(root)/\""
        }
    }

    /// The scopes worth offering: every root other than "/" as a drive, and Cloud when a synced
    /// cloud folder exists in `home`.
    public static func choices(roots: [String], home: String = NSHomeDirectory(),
                               exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [SearchScope] {
        var out: [SearchScope] = [.all, .thisMac]
        let cloudFolders = ["/Library/CloudStorage", "/Library/Mobile Documents/com~apple~CloudDocs",
                            "/Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite"]
        if cloudFolders.contains(where: { exists(home + $0) }) { out.append(.cloud) }
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
