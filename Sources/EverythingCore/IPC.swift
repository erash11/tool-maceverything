import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One JSON line in, one JSON line out, over a Unix domain socket.
public struct IPCRequest: Codable {
    public var command: String          // "search", "status", "rescan", "save"
    public var query: String?
    public var limit: Int?
    public var offset: Int?
    public var sort: SortKey?
    public var descending: Bool?

    public init(command: String, query: String? = nil, limit: Int? = nil, offset: Int? = nil,
                sort: SortKey? = nil, descending: Bool? = nil) {
        self.command = command
        self.query = query
        self.limit = limit
        self.offset = offset
        self.sort = sort
        self.descending = descending
    }
}

public struct IPCStatus: Codable {
    public var ready: Bool
    public var entries: Int
    public var roots: [String]
    public var scanning: Bool
    public var lastScanSeconds: Double?
    public var memoryBytes: Int?
    /// Roots whose change stream is not running; their results may be stale.
    public var unwatchedRoots: [String]?
    /// While a scan runs: the root being scanned and entries found so far in this scan.
    public var scanningRoot: String?
    public var scannedSoFar: Int?
}

public struct IPCResponse: Codable {
    public var ok: Bool
    public var error: String?
    public var result: SearchResult?
    public var status: IPCStatus?

    public init(ok: Bool, error: String? = nil, result: SearchResult? = nil, status: IPCStatus? = nil) {
        self.ok = ok
        self.error = error
        self.result = result
        self.status = status
    }
}

public enum IPCError: Error, CustomStringConvertible {
    case socket(String), notRunning(String), badResponse

    public var description: String {
        switch self {
        case .socket(let s): return "socket error: \(s)"
        case .notRunning(let path): return "the everythingd daemon is not running (no socket at \(path))"
        case .badResponse: return "the daemon sent an unreadable response"
        }
    }
}

public enum IPC {
    public static var defaultSocketPath: String {
        FileIndex.defaultDirectory.appendingPathComponent("ev.sock").path
    }

    static func makeAddress(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw IPCError.socket("socket path too long: \(path)") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    /// A peer that hangs up must fail only its own request, not kill the process with SIGPIPE.
    static func disableSigPipe(_ fd: Int32) {
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    /// Largest request line the daemon accepts. Real requests are a few hundred bytes.
    static let maxRequestBytes = 64 * 1024

    /// Reads up to a newline. Returns nil on EOF, error, timeout, or a line over `maxBytes`.
    static func readLine(_ fd: Int32, maxBytes: Int = .max) -> Data? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return data.isEmpty ? nil : data }
            if let nl = buf[0..<n].firstIndex(of: 10) {
                data.append(contentsOf: buf[0..<nl])
                return data.count <= maxBytes ? data : nil
            }
            data.append(contentsOf: buf[0..<n])
            if data.count > maxBytes { return nil }
        }
    }

    /// Gives up on a client that stops sending, so it cannot hold a worker forever.
    static func setReadTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var payload = data
        payload.append(10)
        return payload.withUnsafeBytes { raw -> Bool in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    /// Sends one request to the daemon and waits for its reply.
    public static func send(_ request: IPCRequest, socketPath: String = defaultSocketPath) throws -> IPCResponse {
        guard FileManager.default.fileExists(atPath: socketPath) else { throw IPCError.notRunning(socketPath) }
        #if canImport(Darwin)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw IPCError.socket(String(cString: strerror(errno))) }
        defer { close(fd) }
        disableSigPipe(fd)
        var addr = try makeAddress(socketPath)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw IPCError.notRunning(socketPath) }
        guard writeAll(fd, try JSONEncoder().encode(request)) else { throw IPCError.socket("write failed") }
        guard let line = readLine(fd) else { throw IPCError.badResponse }
        return try JSONDecoder().decode(IPCResponse.self, from: line)
    }
}

/// Accepts connections and answers each with `handler`. One request per connection.
public final class IPCServer {
    public let socketPath: String
    private var fd: Int32 = -1
    private let handler: (IPCRequest) -> IPCResponse
    private let workers = DispatchQueue(label: "MacEverything.ipc", attributes: .concurrent)

    public init(socketPath: String = IPC.defaultSocketPath, handler: @escaping (IPCRequest) -> IPCResponse) {
        self.socketPath = socketPath
        self.handler = handler
    }

    public func start() throws {
        try FileManager.default.createDirectory(
            atPath: (socketPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(socketPath)
        #if canImport(Darwin)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw IPCError.socket(String(cString: strerror(errno))) }
        var addr = try IPC.makeAddress(socketPath)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw IPCError.socket("bind \(socketPath): \(String(cString: strerror(errno)))") }
        chmod(socketPath, 0o600)
        guard listen(fd, 64) == 0 else { throw IPCError.socket("listen failed") }
        let listener = fd
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 {
                    switch errno {
                    case EINTR, ECONNABORTED, EAGAIN:
                        continue // a client gave up, or a signal: keep serving
                    case EMFILE, ENFILE, ENOBUFS, ENOMEM:
                        usleep(100_000) // out of descriptors or buffers: back off, keep serving
                        continue
                    default:
                        return // the listening socket was closed (stop())
                    }
                }
                guard let self else { close(client); return }
                IPC.disableSigPipe(client)
                IPC.setReadTimeout(client, seconds: 5)
                self.workers.async { self.serve(client) }
            }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        guard let line = IPC.readLine(client, maxBytes: IPC.maxRequestBytes) else {
            if let data = try? JSONEncoder().encode(IPCResponse(ok: false, error: "request too large or incomplete")) {
                _ = IPC.writeAll(client, data)
            }
            return
        }
        let response: IPCResponse
        if let request = try? JSONDecoder().decode(IPCRequest.self, from: line) {
            response = handler(request)
        } else {
            response = IPCResponse(ok: false, error: "malformed request")
        }
        if let data = try? JSONEncoder().encode(response) { _ = IPC.writeAll(client, data) }
    }

    public func stop() {
        if fd >= 0 { close(fd); fd = -1 }
        unlink(socketPath)
    }
}
