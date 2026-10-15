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
            Divider()
            Button("Rebuild Index") { _ = try? IPC.send(IPCRequest(command: "rescan")) }
            Button("Quit MacEverything") { NSApp.terminate(nil) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
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
            p.contentView = NSHostingView(rootView: SearchView())
            p.center()
            panel = p
        }
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

    private let queue = DispatchQueue(label: "MacEverything.app.search")
    private var generation = 0

    init() { run() }

    func run() {
        generation += 1
        let gen = generation
        let request = IPCRequest(command: "search", query: query, limit: 500, sort: sort, descending: descending)
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
    @StateObject private var model = SearchModel()
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
            TextField("Search", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 15))
                .padding(10)
                .focused($fieldFocused)
                .onSubmit { openSelection(reveal: false) }
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
