import AppKit
import Carbon.HIToolbox
import EverythingCore
import SwiftUI

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
    @Published var sort = SortKey.name { didSet { run() } }
    @Published var descending = false { didSet { run() } }
    /// What the scope menu offers: All, This Mac, Cloud, then each indexed drive.
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

    private static let scopeKey = "searchScope"
    private let queue = DispatchQueue(label: "MacEverything.app.search")
    private var generation = 0

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

    func run() {
        generation += 1
        let gen = generation
        let request = IPCRequest(command: "search", query: query, limit: 500, sort: sort, descending: descending,
                                 scope: [scope.query, filter.query].filter { !$0.isEmpty }.joined(separator: " "))
        queue.async {
            let text: String
            var newHits: [SearchHit] = []
            do {
                let response = try IPC.send(request)
                if let r = response.result {
                    newHits = r.hits
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
                self.hits = newHits
                self.message = text
            }
        }
    }
}

struct SearchView: View {
    @ObservedObject var model: SearchModel
    @State private var selection = Set<String>()
    @FocusState private var fieldFocused: Bool

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
                .help("Limit results to one drive, this Mac, or synced cloud folders")
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
            Table(model.hits, selection: $selection) {
                TableColumn("Name") { hit in
                    Label(hit.name, systemImage: hit.isDirectory ? "folder" : "doc")
                }
                TableColumn("Folder") { hit in
                    Text((hit.path as NSString).deletingLastPathComponent)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                TableColumn("Size") { hit in
                    Text(hit.isDirectory ? "" : ByteCountFormatter.string(fromByteCount: hit.size, countStyle: .file))
                        .monospacedDigit()
                }
                .width(min: 60, ideal: 80, max: 120)
                TableColumn("Modified") { hit in
                    Text(Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(hit.modified))))
                        .monospacedDigit()
                }
                .width(min: 110, ideal: 140, max: 180)
            }
            .contextMenu(forSelectionType: String.self) { paths in
                Button("Open") { open(paths, reveal: false) }
                Button("Reveal in Finder") { open(paths, reveal: true) }
                Button("Copy Path") { copy(paths) }
            } primaryAction: { paths in
                open(paths, reveal: false)
            }
            HStack {
                Text(model.message).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Sort", selection: $model.sort) {
                    Text("Name").tag(SortKey.name)
                    Text("Path").tag(SortKey.path)
                    Text("Size").tag(SortKey.size)
                    Text("Modified").tag(SortKey.modified)
                }
                .pickerStyle(.menu)
                .frame(width: 150)
                Toggle("Descending", isOn: $model.descending).toggleStyle(.checkbox)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 600, minHeight: 320)
        .onAppear { fieldFocused = true }
        .onExitCommand { NSApp.keyWindow?.orderOut(nil) }
        .onCopyCommand {
            let paths = selection.isEmpty ? [] : Array(selection)
            return paths.isEmpty ? [] : [NSItemProvider(object: paths.joined(separator: "\n") as NSString)]
        }
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
