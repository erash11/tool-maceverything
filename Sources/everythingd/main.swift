import EverythingCore
import Foundation

func logLine(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
}

let config = ServiceConfig.load()
let roots = config.roots ?? IndexService.defaultRoots(includeExternal: config.includeExternalVolumes ?? true)
var exclusions = Scanner.defaultExclusions
for extra in config.exclusions ?? [] { exclusions.insert(IndexService.canonical(extra)) }

signal(SIGPIPE, SIG_IGN)
logLine("everythingd starting; roots: \(roots.joined(separator: ", "))")
let service = IndexService(roots: roots, exclusions: exclusions, log: logLine)
let server = IPCServer { service.handle($0) }
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
