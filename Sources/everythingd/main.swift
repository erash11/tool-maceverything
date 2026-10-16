import EverythingCore
import Foundation

func logLine(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
}

let config = ServiceConfig.load()
let roots = config.resolvedRoots()
let exclusions = config.exclusionSet

signal(SIGPIPE, SIG_IGN)
logLine("everythingd starting; roots: \(roots.joined(separator: ", "))")
let excludedNames = config.excludedNames.map(Set.init) ?? Scanner.defaultExcludedNames
let service = IndexService(roots: roots, exclusions: exclusions, excludedNames: excludedNames, log: logLine)
var server: IPCServer!

/// Saves the index and exits; launchd (KeepAlive) starts the daemon again, which loads the saved
/// index and scans only locations it has not seen. Used when the set of locations changes.
func restart(_ reason: String) {
    logLine("restarting: \(reason)")
    server.stop()
    service.stop()
    exit(0)
}

server = IPCServer { request in
    if request.command == "reload" {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { restart("locations changed") }
        return IPCResponse(ok: true)
    }
    return service.handle(request)
}
do {
    try server.start()
    logLine("listening on \(server.socketPath)")
} catch {
    logLine("could not start the socket server: \(error)")
    exit(1)
}

// Full Disk Access check: without it, protected folders such as ~/Library/Mail read as empty.
let probe = NSHomeDirectory() + "/Library/Mail"
if FileManager.default.fileExists(atPath: probe), (try? FileManager.default.contentsOfDirectory(atPath: probe)) == nil {
    logLine("warning: no Full Disk Access; protected folders will be missing. Add everythingd in System Settings > Privacy & Security > Full Disk Access.")
}

// The first scan runs at normal priority: at .utility (and under launchd's Background
// process type) macOS throttles its disk reads, which made a 4M-entry scan take 24 minutes.
// Live updates afterwards run on the service's own queue.
DispatchQueue.global(qos: .userInitiated).async { service.start() }

// A drive plugged in after startup, or a location added in config.json: pick it up. Drives
// that go away are not a reason to restart; their entries stay until they come back.
let locationCheck = DispatchSource.makeTimerSource(queue: .main)
locationCheck.schedule(deadline: .now() + 30, repeating: 30)
locationCheck.setEventHandler {
    let wanted = IndexService.normalizeRoots(ServiceConfig.load().resolvedRoots(), exclusions: exclusions)
    let added = wanted.filter { !service.roots.contains($0) }
    if !added.isEmpty, service.ready, !service.scanning {
        restart("new location \(added.joined(separator: ", "))")
    }
}
locationCheck.resume()

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        logLine("stopping; saving index")
        server.stop()
        service.stop()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

dispatchMain()
