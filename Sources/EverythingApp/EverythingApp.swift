import AppKit
import Carbon.HIToolbox
import EverythingCore
import SwiftUI
import UniformTypeIdentifiers

extension SearchHit: Identifiable {
    public var id: String { path }
}

@main
struct EverythingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("MacEverything", systemImage: "magnifyingglass") {
            Button("Search  (Option-Space)") { appDelegate.showSearch() }
            Button("Locations…") { appDelegate.showLocations() }
            Divider()
            Button("Rebuild Index") { _ = try? IPC.send(IPCRequest(command: "rescan")) }
            Button("Quit MacEverything") { NSApp.terminate(nil) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private let model = SearchModel()
    private var locationsWindow: NSWindow?
    private let locations = LocationsModel()

    func showLocations() {
        if locationsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "MacEverything Locations"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: LocationsView(model: locations))
            w.center()
            locationsWindow = w
        }
        locations.refresh()
        NSApp.activate(ignoringOtherApps: true)
        locationsWindow?.makeKeyAndOrderFront(nil)
    }
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) { [weak self] in
            DispatchQueue.main.async { self?.toggleSearch() }
        }
    }

    func toggleSearch() {
        if let panel, panel.isVisible, panel.isKeyWindow {
            panel.orderOut(nil)
        } else {
            showSearch()
        }
    }

    func showSearch() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 820, height: 480),
                            styleMask: [.titled, .closable, .resizable, .miniaturizable],
                            backing: .buffered, defer: false)
            p.title = "MacEverything"
            p.identifier = SearchView.panelID
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.contentView = NSHostingView(rootView: SearchView(model: model))
            p.center()
            panel = p
        }
        model.refreshScopes()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
    }
}

/// A system-wide hotkey through Carbon, which needs no Accessibility permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(noErr) }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return OSStatus(noErr)
        }, 1, &spec, context, &handler)
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D45_5659), id: 1) // "MEVY"
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

final class SearchModel: ObservableObject {
    @Published var query = "" { didSet { run() } }
    @Published var hits: [SearchHit] = []
    @Published var message = ""
    @Published private(set) var sort = SortKey.name
    @Published private(set) var descending = false

    /// Changes the sort and searches once (setting the two fields separately would search twice).
    func setSort(_ key: SortKey, descending: Bool) {
        sort = key
        self.descending = descending
        run()
    }
    /// What the scope menu offers: All, This Mac, Cloud, each cloud account, then each indexed drive.
    @Published var scopes: [SearchScope] = [.all]
    @Published var scope = SearchScope.all {
        didSet {
            // A fallback while a saved drive is unplugged must not forget that choice.
            if !restoring { UserDefaults.standard.set(scope.id, forKey: SearchModel.scopeKey) }
            run()
        }
    }
    private var restoring = false
    /// The file-type menu at the end of the search box (Everything's Search > filters).
    @Published var filter: FileFilter = FileFilter(rawValue: UserDefaults.standard.string(forKey: SearchModel.filterKey) ?? "")
        ?? .everything {
        didSet {
            UserDefaults.standard.set(filter.rawValue, forKey: SearchModel.filterKey)
            run()
        }
    }
    private static let filterKey = "searchFilter"
    /// Temp and generated files (node_modules, .git, caches, *.tmp...) are hidden unless ticked.
    @Published var showTemp = UserDefaults.standard.bool(forKey: SearchModel.showTempKey) {
        didSet {
            UserDefaults.standard.set(showTemp, forKey: SearchModel.showTempKey)
            run()
        }
    }
    private static let showTempKey = "showTempFiles"

    private static let scopeKey = "searchScope"
    private let queue = DispatchQueue(label: "MacEverything.app.search")
    private var generation = 0
    /// Every row loaded so far for the current search; `hits` mirrors `pages.hits`.
    private var pages = ResultPages()
    /// The current search's request, reused with a new offset for each further page.
    private var request = IPCRequest(command: "search")
    private var loadingMore = false
    /// The generation whose first page `pages` holds; paging waits until it equals `generation`,
    /// so rows of the previous search can't ask for a page of the new one.
    private var pagesGeneration = -1
    /// The first page's search time; the count in the footer comes from the latest page.
    private var milliseconds = 0.0
    private var pageError = ""
    /// Paths whose rows are on screen. Table cells are keyed by path, so a new search that keeps
    /// rows in place may not make them appear again; this lets it check where the list is.
    private var visible = Set<String>()

    init() {
        refreshScopes()
    }

    /// Rebuilds the scope menu from the daemon's roots, so a drive plugged in or out shows up
    /// the next time the window opens. Restores the last choice when it is still offered.
    func refreshScopes() {
        queue.async {
            let roots = (try? IPC.send(IPCRequest(command: "status")))?.status?.roots ?? []
            let choices = SearchScope.choices(roots: roots)
            DispatchQueue.main.async {
                self.scopes = choices
                let saved = UserDefaults.standard.string(forKey: SearchModel.scopeKey).flatMap(SearchScope.init(id:))
                let wanted = saved ?? self.scope
                let next = choices.contains(wanted) ? wanted : .all
                if next != self.scope {
                    self.restoring = true
                    self.scope = next // runs the search
                    self.restoring = false
                } else {
                    self.run() // results and the footer are fresh each time the window opens
                }
            }
        }
    }

    /// Whether `hits` are the first page of the search the box, scope and filter now ask for (not
    /// rows of an earlier one still waiting to be replaced).
    var hitsAreCurrent: Bool { pagesGeneration == generation }

    func run() {
        generation += 1
        let gen = generation
        loadingMore = false
        let request = IPCRequest(command: "search", query: query, limit: ResultPages.firstPage, sort: sort,
                                 descending: descending,
                                 scope: [scope.query, filter.query, showTemp ? "" : "!temp:"]
                                     .filter { !$0.isEmpty }.joined(separator: " "))
        self.request = request
        queue.async {
            let text: String
            var first: SearchResult?
            do {
                let response = try IPC.send(request)
                if let r = response.result {
                    first = r
                    text = "\(r.total.formatted()) objects  ·  \(String(format: "%.1f", r.milliseconds)) ms"
                } else {
                    text = response.error ?? "Search failed"
                }
            } catch IPCError.notRunning(_) {
                // Usually the daemon restarting (an install, a login): try again shortly
                // instead of leaving the error up until the next keystroke.
                text = "Waiting for the index service to start…"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if gen == self.generation { self.run() }
                }
            } catch {
                text = "\(error)"
            }
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                if let first { self.pages.reset(with: first) } else { self.pages = ResultPages() }
                self.pagesGeneration = gen
                self.pageError = ""
                self.milliseconds = first?.milliseconds ?? 0
                self.hits = self.pages.hits
                self.message = first == nil ? text : self.footer()
                // Already scrolled near the end (rows reused from the last search): page now.
                if self.visible.contains(where: self.pages.isNearEnd) { self.loadNextPage(attempt: 0) }
            }
        }
    }

    /// Called as rows come on screen: near the end of what is loaded, fetch the next page, so the
    /// list scrolls through every match instead of stopping at the first page.
    func rowAppeared(_ hit: SearchHit) {
        visible.insert(hit.path)
        guard pages.isNearEnd(hit.path) else { return }
        loadNextPage(attempt: 0)
    }

    func rowDisappeared(_ hit: SearchHit) { visible.remove(hit.path) }

    private func loadNextPage(attempt: Int) {
        guard pagesGeneration == generation, pages.hasMore, !loadingMore else { return }
        loadingMore = true
        let gen = generation
        var next = request
        next.offset = pages.nextOffset
        next.limit = ResultPages.nextPage
        queue.async {
            let page = (try? IPC.send(next))?.result
            DispatchQueue.main.async {
                guard gen == self.generation else { return } // run() already reset loadingMore
                self.loadingMore = false
                guard next.offset == self.pages.nextOffset else { return }
                guard let page else {
                    // Visible rows don't appear again, so retry here, a few times.
                    if attempt < 3 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            // Only for the same search and page; a new search gets its own retries.
                            guard gen == self.generation, next.offset == self.pages.nextOffset else { return }
                            self.loadNextPage(attempt: attempt + 1)
                        }
                    } else {
                        self.pageError = "  ·  could not load more rows"
                        self.message = self.footer()
                    }
                    return
                }
                let added = self.pages.append(page)
                self.pageError = ""
                self.hits = self.pages.hits
                self.message = self.footer()
                // A page of rows already shown puts nothing new on screen to ask for the next one.
                if added == 0 { self.loadNextPage(attempt: 0) }
            }
        }
    }

    private func footer() -> String {
        var text = "\(pages.total.formatted()) objects  ·  \(String(format: "%.1f", milliseconds)) ms"
        // Repeats are skipped, so loaded rows can differ from the total even when paging is done.
        if pages.hits.count != pages.total { text += "  ·  showing \(pages.hits.count.formatted())" }
        return text + pageError
    }
}

struct SearchView: View {
    @ObservedObject var model: SearchModel
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\SearchHit.name)]
    @FocusState private var fieldFocused: Bool
    @FocusState private var tableFocused: Bool
    /// The Down Arrow watcher (see watchDownArrow); removed when the view goes away.
    @State private var keyMonitor: Any?
    /// Down was pressed while the results were still those of an earlier search.
    @State private var downPending = false
    static let panelID = NSUserInterfaceItemIdentifier("MacEverything.search")
    /// Which columns are shown, their order and widths (right-click a header; drag to reorder).
    /// Defaults to Name | Type | Path, like Everything.
    @AppStorage("resultColumns.v2") private var columnsData = Data()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Scope", selection: $model.scope) {
                    ForEach(model.scopes, id: \.self) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .help("Limit results to one drive, this Mac, all synced cloud folders, or one cloud account")
                TextField("Search", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15))
                    .focused($fieldFocused)
                    .onSubmit { openSelection(reveal: false) }
                Picker("Type", selection: $model.filter) {
                    ForEach(FileFilter.allCases, id: \.self) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .help("Only show one kind of file, as in Everything's Search menu")
            }
            .padding(10)
            resultsTable
                .focused($tableFocused)
            HStack {
                Text(model.message).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("Show temp files", isOn: $model.showTemp).toggleStyle(.checkbox)
                    .help("Temp and generated files: node_modules, .git, build folders, caches, *.tmp, system temp folders")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 600, minHeight: 320)
        .onAppear {
            fieldFocused = true
            watchDownArrow()
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        // $hits sends the new rows just before `hits` changes; by then the search is marked current.
        .onReceive(model.$hits) { hits in
            guard downPending && model.hitsAreCurrent else { return }
            // Only if the box still has the keys: a click, Tab or Escape since then cancels it.
            if Self.searchBoxHasKeys(NSApp.keyWindow) { moveIntoResults(hits) } else { downPending = false }
        }
        .onChange(of: model.query) { _ in downPending = false }
        .onExitCommand { NSApp.keyWindow?.orderOut(nil) }
        .onCopyCommand {
            let paths = selection.isEmpty ? [] : Array(selection)
            return paths.isEmpty ? [] : [NSItemProvider(object: paths.joined(separator: "\n") as NSString)]
        }
    }

    // MARK: - Results table

    @available(macOS 14, *)
    private var columnCustomization: Binding<TableColumnCustomization<SearchHit>> {
        Binding(
            get: {
                (try? JSONDecoder().decode(TableColumnCustomization<SearchHit>.self, from: columnsData))
                    ?? TableColumnCustomization()
            },
            set: { columnsData = (try? JSONEncoder().encode($0)) ?? Data() })
    }

    @ViewBuilder private var resultsTable: some View {
        if #available(macOS 14, *) {
            // Right-click a header to show or hide columns; drag a header to move it.
            withBehavior(Table(model.hits, selection: $selection, sortOrder: $sortOrder,
                               columnCustomization: columnCustomization) {
                TableColumn("Name", value: \.name) { nameCell($0) }
                    .customizationID("name")
                    .disabledCustomizationBehavior(.visibility)
                TableColumn("Type") { typeCell($0) }
                    .width(min: 80, ideal: 150, max: 260)
                    .customizationID("type")
                TableColumn("Path", value: \.path) { folderCell($0) }
                    .customizationID("folder")
                TableColumn("Size", value: \.size) { sizeCell($0) }
                    .width(min: 60, ideal: 80, max: 120)
                    .customizationID("size")
                    .defaultVisibility(.hidden)
                TableColumn("Date Modified", value: \.modified) { modifiedCell($0) }
                    .width(min: 110, ideal: 140, max: 180)
                    .customizationID("modified")
                    .defaultVisibility(.hidden)
                TableColumn("Extension") { hit in Text(Self.fileExtension(hit)) }
                    .width(min: 50, ideal: 70, max: 120)
                    .customizationID("extension")
                    .defaultVisibility(.hidden)
                TableColumn("Full Path") { hit in
                    Text(hit.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .customizationID("fullpath")
                .defaultVisibility(.hidden)
            })
        } else {
            withBehavior(Table(model.hits, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { nameCell($0) }
                TableColumn("Type") { typeCell($0) }
                    .width(min: 80, ideal: 150, max: 260)
                TableColumn("Path", value: \.path) { folderCell($0) }
                TableColumn("Size", value: \.size) { sizeCell($0) }
                    .width(min: 60, ideal: 80, max: 120)
                TableColumn("Date Modified", value: \.modified) { modifiedCell($0) }
                    .width(min: 110, ideal: 140, max: 180)
            })
        }
    }

    private func typeCell(_ hit: SearchHit) -> some View {
        Text(Self.kind(hit)).foregroundStyle(.secondary).lineLimit(1)
    }

    private func nameCell(_ hit: SearchHit) -> some View {
        // The Name column is always shown, so its cells report which rows are on screen.
        Label(hit.name, systemImage: hit.isDirectory ? "folder" : "doc")
            .onAppear { model.rowAppeared(hit) }
            .onDisappear { model.rowDisappeared(hit) }
    }

    private func folderCell(_ hit: SearchHit) -> some View {
        Text((hit.path as NSString).deletingLastPathComponent)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func sizeCell(_ hit: SearchHit) -> some View {
        Text(hit.isDirectory ? "" : ByteCountFormatter.string(fromByteCount: hit.size, countStyle: .file))
            .monospacedDigit()
    }

    private func modifiedCell(_ hit: SearchHit) -> some View {
        Text(Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(hit.modified))))
            .monospacedDigit()
    }

    private static func fileExtension(_ hit: SearchHit) -> String {
        hit.isDirectory ? "" : (hit.name as NSString).pathExtension.lowercased()
    }

    private static func kind(_ hit: SearchHit) -> String {
        let ext = (hit.name as NSString).pathExtension
        if hit.isDirectory { return ext.isEmpty ? "Folder" : (UTType(filenameExtension: ext)?.localizedDescription ?? "Folder") }
        if ext.isEmpty { return "Document" }
        return UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased() + " file"
    }

    /// Sorting from the headers and the row menu, shared by both tables.
    private func withBehavior<T: View>(_ table: T) -> some View {
        table
            // Clicking a header sorts by it; clicking again flips the order. The daemon does the
            // sorting, so it covers every match, not only the rows on screen.
            .onChange(of: sortOrder) { order in
                guard let first = order.first else { return }
                let column = first.keyPath
                let key: SortKey
                if column == \SearchHit.path as PartialKeyPath<SearchHit> {
                    key = .path
                } else if column == \SearchHit.size as PartialKeyPath<SearchHit> {
                    key = .size
                } else if column == \SearchHit.modified as PartialKeyPath<SearchHit> {
                    key = .modified
                } else {
                    key = .name
                }
                let descending = first.order == .reverse
                if model.sort != key || model.descending != descending {
                    model.setSort(key, descending: descending)
                }
            }
            .contextMenu(forSelectionType: String.self) { paths in
                Button("Open") { open(paths, reveal: false) }
                Button("Reveal in Finder") { open(paths, reveal: true) }
                Button("Copy Path") { copy(paths) }
            } primaryAction: { paths in
                open(paths, reveal: false)
            }
    }

    /// Down Arrow in the search box moves into the results, as in Everything: the first row is
    /// selected (a selection still on screen is kept) and the list takes the keys, so the next
    /// Down, Up and Return work there. A local key monitor runs before the text field sees the key
    /// (SwiftUI's onKeyPress needs macOS 14). Other keys, and Down with a modifier, pass through.
    /// While the rows are still an earlier search's, the move waits for the current ones (a new
    /// keystroke in the box cancels it), so Return can't open a row that doesn't match.
    private func watchDownArrow() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // The search panel's only text field is the search box, so a text field's editor holding
            // the panel's keys means the box has focus (read from AppKit: this runs outside the
            // view's body). The identifier keeps other panels (the folder chooser) out.
            guard event.keyCode == UInt16(kVK_DownArrow), modifiers.isEmpty,
                  Self.searchBoxHasKeys(event.window) else { return event }
            if model.hitsAreCurrent {
                moveIntoResults(model.hits)
            } else {
                downPending = true
            }
            return nil
        }
    }

    /// Whether `window` is the search panel and a text field's editor (the search box: the
    /// panel's only text field) holds its keys.
    private static func searchBoxHasKeys(_ window: NSWindow?) -> Bool {
        window?.identifier == panelID && (window?.firstResponder as? NSTextView)?.delegate is NSTextField
    }

    private func moveIntoResults(_ hits: [SearchHit]) {
        downPending = false
        guard let first = hits.first else { return }
        // Keep only selected rows that are still results; none left selects the first.
        let kept = selection.intersection(hits.map(\.path))
        selection = kept.isEmpty ? [first.path] : kept
        tableFocused = true
    }

    private func openSelection(reveal: Bool) {
        if selection.isEmpty, let first = model.hits.first {
            open([first.path], reveal: reveal)
        } else {
            open(selection, reveal: reveal)
        }
    }

    private func open(_ paths: Set<String>, reveal: Bool) { open(Array(paths), reveal: reveal) }

    private func open(_ paths: [String], reveal: Bool) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        if reveal {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        } else {
            urls.forEach { NSWorkspace.shared.open($0) }
        }
    }

    private func copy(_ paths: Set<String>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.sorted().joined(separator: "\n"), forType: .string)
    }
}

/// What is indexed, and the locations added on top of the defaults (config.json extraRoots).
final class LocationsModel: ObservableObject {
    @Published var indexed: [String] = []
    @Published var added: [String] = []
    @Published var message = ""

    func refresh() {
        let config = ServiceConfig.load()
        added = config.extraRoots ?? []
        DispatchQueue.global().async {
            let roots = (try? IPC.send(IPCRequest(command: "status")))?.status?.roots
            DispatchQueue.main.async { self.indexed = roots ?? config.resolvedRoots() }
        }
    }

    func choose() {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.allowsMultipleSelection = false
        open.prompt = "Add"
        open.message = "Choose a folder, drive or network share to index"
        guard open.runModal() == .OK, let url = open.url else { return }
        add(url.path)
    }

    func add(_ path: String) {
        var config = ServiceConfig.load()
        let new = IndexService.canonical(path)
        let current = IndexService.normalizeRoots(config.resolvedRoots(), exclusions: config.exclusionSet)
        let after = IndexService.normalizeRoots(current + [new], exclusions: config.exclusionSet)
        guard after != current else {
            let outer = current.first { $0 == "/" || new == $0 || new.hasPrefix($0 + "/") } ?? "/"
            message = "Already indexed: \(new) is inside \(outer)."
            return
        }
        config.extraRoots = (config.extraRoots ?? []) + [new]
        save(config, done: "Added \(new). It is being scanned and will appear in results shortly.")
    }

    func remove(_ path: String) {
        var config = ServiceConfig.load()
        config.extraRoots = (config.extraRoots ?? []).filter { $0 != path }
        if config.extraRoots?.isEmpty == true { config.extraRoots = nil }
        save(config, done: "Removed \(path).")
    }

    private func save(_ config: ServiceConfig, done: String) {
        do {
            try config.save()
        } catch {
            message = "Could not save the settings: \(error.localizedDescription)"
            return
        }
        // The daemon restarts with the new list, keeps what it already indexed, and scans only
        // the new location.
        _ = try? IPC.send(IPCRequest(command: "reload"))
        message = done
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.refresh() }
        refresh()
    }
}

struct LocationsView: View {
    @ObservedObject var model: LocationsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Indexed now").font(.headline)
            Text("Your Mac's disk (including Google Drive, Dropbox, Box, OneDrive and iCloud folders) and every drive you plug in are indexed automatically.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(model.indexed, id: \.self) { root in
                    HStack {
                        Image(systemName: root == "/" ? "desktopcomputer" : root.hasPrefix("/Volumes/") ? "externaldrive" : "folder")
                        Text(root == "/" ? "This Mac  (/)" : root)
                        Spacer()
                        if model.added.contains(root) {
                            Button("Remove") { model.remove(root) }
                        }
                    }
                }
                ForEach(model.added.filter { !model.indexed.contains($0) }, id: \.self) { root in
                    HStack {
                        Image(systemName: "clock")
                        Text(root).foregroundStyle(.secondary)
                        Text("waiting (not mounted, or being added)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove") { model.remove(root) }
                    }
                }
            }
            HStack {
                Button("Add Folder or Drive…") { model.choose() }
                Spacer()
                Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(14)
        .frame(minWidth: 520, minHeight: 300)
    }
}
