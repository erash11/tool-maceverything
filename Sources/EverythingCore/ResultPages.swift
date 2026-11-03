import Foundation

/// The rows a results window has loaded so far for one search. The first page comes with the
/// search; later pages are fetched by offset as the list is scrolled near its end.
///
/// shortcut: pages are separate daemon requests, so a live change between two of them shifts
/// rows. A path already loaded is skipped (an insert above the boundary repeats rows); a delete
/// above it can skip a row until the next search. Upgrade to a daemon-side result snapshot if
/// that ever shows up in use.
public struct ResultPages {
    public static let firstPage = 500
    public static let nextPage = 2000
    /// Start fetching the next page when a row this close to the end comes on screen.
    public static let prefetchMargin = 100

    public private(set) var hits: [SearchHit] = []
    /// The daemon's match count from the latest page.
    public private(set) var total = 0
    /// The offset to ask for next: rows the daemon has sent so far, repeats included.
    public private(set) var nextOffset = 0
    private var position: [String: Int] = [:]

    public init() {}

    public var hasMore: Bool { nextOffset < total }

    /// Starts over with the first page of a new search.
    public mutating func reset(with first: SearchResult) {
        hits = []
        position = [:]
        nextOffset = 0
        add(first)
    }

    /// Adds the page fetched at `nextOffset`.
    public mutating func append(_ page: SearchResult) {
        add(page)
    }

    /// True when `path` is within `prefetchMargin` rows of the end of what is loaded.
    public func isNearEnd(_ path: String) -> Bool {
        guard let i = position[path] else { return false }
        return i >= hits.count - Self.prefetchMargin
    }

    private mutating func add(_ page: SearchResult) {
        total = page.total
        nextOffset += page.hits.count
        // The match count can shrink between pages; an empty page means nothing is left.
        if page.hits.isEmpty { total = nextOffset }
        for hit in page.hits where position[hit.path] == nil {
            position[hit.path] = hits.count
            hits.append(hit)
        }
    }
}
