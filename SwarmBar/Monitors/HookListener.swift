import Foundation
import Network
import Synchronization

/// One client of the hook server, over TCP or the owner-only Unix socket.
/// Every method may be called from any thread.
protocol HookClient: AnyObject, Sendable {
    /// Starts delivering what the client sends, in order, on the
    /// listener's queue. `eof` is true once the client will send no more,
    /// whether it closed or failed.
    func start(on queue: DispatchQueue, onData: @escaping @Sendable (Data?, _ eof: Bool) -> Void)
    /// Sends a response and closes the connection. The completion hears
    /// whether the bytes were handed to the client.
    func respond(_ data: Data, completion: (@Sendable (Bool) -> Void)?)
    func cancel()
    /// True once the client can no longer take an answer.
    var isGone: Bool { get }
    /// The processes above the one at the other end of a local Unix
    /// socket, nearest first, read when it connected. Empty for every
    /// other transport.
    var peerAncestry: [Int] { get }
}

extension HookClient {
    var peerAncestry: [Int] { [] }
}

/// A request read incrementally, so a client trickling bytes costs work in
/// proportion to what it sends rather than to the square of it: the header
/// terminator is searched for only in bytes not already searched, and the
/// header is parsed once.
struct HookRequestReader {
    /// A real hook request's header is a few hundred bytes.
    static let maxHeaderBytes = 16 * 1024

    private(set) var buffer = Data()
    /// Where the next search for the header terminator starts.
    private var searchFrom = 0
    private var header: (end: Int, path: String, contentLength: Int,
                         account: String?, token: String?)?
    /// Bytes examined while looking for the header's end, for tests that
    /// pin the cost of a trickled request as linear.
    private(set) var scannedBytes = 0

    mutating func append(_ chunk: Data) -> HookServer.ParseOutcome {
        buffer.append(chunk)
        if header == nil {
            let terminator = Data("\r\n\r\n".utf8)
            // Back up three bytes, so a terminator split across two chunks
            // is still found, and never search the same bytes twice beyond
            // that.
            let start = buffer.startIndex + max(0, searchFrom - 3)
            scannedBytes += buffer.endIndex - start
            guard let found = buffer.range(of: terminator, in: start..<buffer.endIndex) else {
                searchFrom = buffer.count
                return buffer.count > Self.maxHeaderBytes ? .malformed : .incomplete
            }
            let headerEnd = found.lowerBound - buffer.startIndex
            guard headerEnd <= Self.maxHeaderBytes,
                  let parsed = Self.parseHeader(buffer[buffer.startIndex..<found.lowerBound])
            else { return .malformed }
            header = (found.upperBound - buffer.startIndex, parsed.path, parsed.contentLength,
                      parsed.account, parsed.token)
        }
        guard let header else { return .incomplete }
        let available = buffer.count - header.end
        guard available >= header.contentLength else { return .incomplete }
        let bodyStart = buffer.startIndex + header.end
        let bodySlice = Data(buffer[bodyStart..<(bodyStart + header.contentLength)])
        let parsed = (try? JSONSerialization.jsonObject(with: bodySlice)) as? [String: Any]
        // An empty body is legitimate for some events; a non-empty body that is
        // not a JSON object is not, and must not be routed as if it were empty.
        if parsed == nil, !bodySlice.isEmpty { return .malformed }
        return .complete(HookServer.Request(
            path: header.path, accountLabel: header.account, token: header.token,
            body: parsed ?? [:]))
    }

    private static func parseHeader(
        _ data: Data
    ) -> (path: String, contentLength: Int, account: String?, token: String?)? {
        let headerText = String(decoding: data, as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "POST" else { return nil }

        var contentLength = 0
        var account: String?
        var token: String?
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let raw = line.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespaces)
                // A missing header means an empty body; a present but bogus,
                // negative, or oversized one is a refusal.
                guard let value = Int(raw), value >= 0, value <= HookServer.maxBodyBytes else {
                    return nil
                }
                contentLength = value
            } else if lower.hasPrefix("x-claude-account:") {
                let value = line.dropFirst("x-claude-account:".count)
                    .trimmingCharacters(in: .whitespaces)
                account = value.isEmpty ? nil : value
            } else if lower.hasPrefix("x-swarmbar-token:") {
                token = line.dropFirst("x-swarmbar-token:".count)
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return (String(parts[1]), contentLength, account, token)
    }
}

/// Reads hook requests off the main actor, within fixed limits, and hands
/// only complete, authenticated ones to the hook server.
///
/// Every connection that has not finished sending its request counts
/// against a per-transport cap and must finish within `requestTimeout`.
/// Neither applies once the request is complete: a Claude Code approval is
/// held open for as long as the person takes to decide, and is answered or
/// let go by the hook server, never by this.
///
/// The caps are per transport so that the loopback port, which every
/// local account can reach, can never crowd out the owner-only socket the
/// bridges use.
final class HookListener: Sendable {
    enum Transport: Hashable, Sendable {
        /// 127.0.0.1:48620. Anyone on this Mac can connect, so requests
        /// must carry the hook token.
        case loopback
        /// The Unix socket in the owner-only directory. Reaching it at
        /// all proves the client runs as this user.
        case ownerSocket
    }

    struct Limits: Sendable {
        var maxOpenRequests = 32
        var requestTimeout: DispatchTimeInterval = .seconds(10)
    }

    /// A request that crossed from the listener's queue to the main actor.
    /// Its body is a parsed JSON object, which is not Sendable by type but
    /// is never touched again on this side.
    struct Delivery: @unchecked Sendable {
        let request: HookServer.Request
        let client: any HookClient
    }

    let queue = DispatchQueue(label: "SwarmBar.HookListener")
    let limits: Limits
    private let deliver: @Sendable (Delivery) -> Void
    private let clientGone: @Sendable () -> Void

    private struct Reading {
        let client: any HookClient
        let transport: Transport
        let token: String?
        var reader = HookRequestReader()
        let timer: DispatchSourceTimer
    }
    /// Connections still sending their request, confined to `queue`.
    private let reading = Mutex<[ObjectIdentifier: Reading]>([:])

    init(
        limits: Limits = Limits(),
        deliver: @escaping @Sendable (Delivery) -> Void,
        clientGone: @escaping @Sendable () -> Void
    ) {
        self.limits = limits
        self.deliver = deliver
        self.clientGone = clientGone
    }

    /// How many connections on a transport have not finished sending.
    func openRequests(on transport: Transport) -> Int {
        queue.sync { reading.withLock { $0.values.filter { $0.transport == transport }.count } }
    }

    /// Takes a new connection. `token` is what its request must carry, or
    /// nil when the transport itself proves who is calling.
    func adopt(_ client: any HookClient, transport: Transport, token: String?) {
        queue.async { [self] in
            let key = ObjectIdentifier(client)
            let admitted = reading.withLock { open -> Bool in
                // Refuse the newcomer rather than evict a request already
                // being read: a flood can then only stall itself.
                guard open.values.filter({ $0.transport == transport }).count
                        < limits.maxOpenRequests
                else { return false }
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + limits.requestTimeout)
                timer.setEventHandler { [self] in
                    // Too slow to send a request: not a client that is
                    // waiting on a decision, which only starts once its
                    // request is complete.
                    finishReading(key)?.cancel()
                }
                open[key] = Reading(client: client, transport: transport, token: token, timer: timer)
                timer.resume()
                return true
            }
            guard admitted else { client.cancel(); return }
            client.start(on: queue) { [self] data, eof in
                received(data, eof: eof, key: key)
            }
        }
    }

    /// Stops tracking a connection as one still sending, returning it.
    private func finishReading(_ key: ObjectIdentifier) -> (any HookClient)? {
        reading.withLock { open in
            guard let entry = open.removeValue(forKey: key) else { return nil }
            entry.timer.cancel()
            return entry.client
        }
    }

    private func received(_ data: Data?, eof: Bool, key: ObjectIdentifier) {
        enum Next { case wait, drop, done(HookServer.Request, String?, any HookClient), gone }
        let next: Next = reading.withLock { open in
            guard var entry = open[key] else {
                // Already handed over: anything more is either the client
                // closing, which ends a held request, or noise.
                return eof ? .gone : .wait
            }
            var outcome = HookServer.ParseOutcome.incomplete
            if let data, !data.isEmpty { outcome = entry.reader.append(data) }
            open[key] = entry
            switch outcome {
            case .complete(let request): return .done(request, entry.token, entry.client)
            case .malformed: return .drop
            case .incomplete: return eof ? .drop : .wait
            }
        }
        switch next {
        case .wait:
            break
        case .gone:
            clientGone()
        case .drop:
            finishReading(key)?.cancel()
        case .done(let request, let token, let client):
            _ = finishReading(key)
            // Only bridges this app installed may change what the popover
            // shows. A wrong or missing token gets the same empty answer a
            // non-session event gets, so a misconfigured bridge fails open
            // rather than hanging, and never reaches the main actor.
            if let token, !HookToken.matches(request.token, token) {
                client.respond(Data("{}".utf8), completion: nil)
                return
            }
            deliver(Delivery(request: request, client: client))
        }
    }
}

// MARK: - Transports

/// A loopback TCP client.
final class NWHookClient: HookClient {
    let connection: NWConnection
    /// Set when the client stopped sending: closed, or failed. A held
    /// request whose client has closed can no longer take an answer, even
    /// while the connection's own state still reads ready.
    private let closed = Mutex(false)

    init(_ connection: NWConnection) { self.connection = connection }

    func start(on queue: DispatchQueue, onData: @escaping @Sendable (Data?, Bool) -> Void) {
        connection.start(queue: queue)
        receive(onData)
    }

    private func receive(_ onData: @escaping @Sendable (Data?, Bool) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            let eof = isComplete || error != nil
            if eof { self?.closed.withLock { $0 = true } }
            onData(data, eof)
            if !eof { self?.receive(onData) }
        }
    }

    func respond(_ data: Data, completion: (@Sendable (Bool) -> Void)?) {
        var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(data)
        let connection = self.connection
        connection.send(content: response, completion: .contentProcessed { error in
            completion?(error == nil)
            connection.cancel()
        })
    }

    func cancel() { connection.cancel() }

    var isGone: Bool {
        if closed.withLock({ $0 }) { return true }
        switch connection.state {
        case .cancelled, .failed: return true
        default: return false
        }
    }
}

/// A client of the owner-only Unix socket, on a plain file descriptor.
final class UnixHookClient: HookClient {
    private struct State {
        var fd: Int32
        var source: DispatchSourceRead?
        var gone = false
    }
    private let state: Mutex<State>

    let peerAncestry: [Int]

    init(fd: Int32, peerAncestry: [Int] = []) {
        state = Mutex(State(fd: fd))
        self.peerAncestry = peerAncestry
    }

    func start(on queue: DispatchQueue, onData: @escaping @Sendable (Data?, Bool) -> Void) {
        state.withLock { current in
            guard !current.gone else { return }
            let fd = current.fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    onData(Data(buffer[0..<count]), false)
                } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    self?.cancel()
                    onData(nil, true)
                }
            }
            source.setCancelHandler { close(fd) }
            current.source = source
            source.resume()
        }
    }

    func respond(_ data: Data, completion: (@Sendable (Bool) -> Void)?) {
        var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(data)
        let written: Bool = state.withLock { current in
            guard !current.gone else { return false }
            return Self.writeAll(response, to: current.fd)
        }
        completion?(written)
        cancel()
    }

    /// The response is a few hundred bytes, well inside a socket buffer,
    /// so this waits at most briefly for room and gives up after a second.
    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            var waited = 0
            while offset < raw.count {
                let count = write(fd, base + offset, raw.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EAGAIN || errno == EINTR, waited < 100 {
                    var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&poller, 1, 10)
                    waited += 1
                } else {
                    return false
                }
            }
            return true
        }
    }

    func cancel() {
        state.withLock { current in
            guard !current.gone else { return }
            current.gone = true
            if let source = current.source {
                source.cancel()
            } else {
                close(current.fd)
            }
        }
    }

    var isGone: Bool { state.withLock { $0.gone } }
}

/// The owner-only Unix socket the bridge scripts post to.
///
/// It replaces the loopback port as the bridges' way in. A port is
/// anyone's: while SwarmBar was not running, another account could bind
/// 48620, receive every hook payload with its token, and answer allow to
/// prompts the person never saw. This socket lives in a directory only
/// this user can enter, the server makes the directory owner-only before
/// binding, and every client's uid is checked again on accept, so nobody
/// else can listen in SwarmBar's place or connect to it.
final class UnixHookSocket: Sendable {
    let path: String
    private let listener = Mutex<(fd: Int32, source: DispatchSourceRead?)>((-1, nil))

    init(path: String) { self.path = path }

    /// Where the bridges find the socket. Kept in step with the scripts.
    static var defaultPath: String {
        HookToken.directory.appendingPathComponent("run/hook.sock").path
    }

    enum Failure: Error, CustomStringConvertible {
        case directory(String)
        case pathTooLong
        case occupied
        case inUse
        case system(String, Int32)

        var description: String {
            switch self {
            case .directory(let why): "Socket folder unusable: \(why)"
            case .pathTooLong: "Socket path too long"
            case .occupied: "Something other than a socket is at the socket path"
            case .inUse: "Another copy of SwarmBar is answering hooks"
            case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    func start(queue: DispatchQueue, accept: @escaping @Sendable (UnixHookClient) -> Void) throws {
        try Self.prepareDirectory((path as NSString).deletingLastPathComponent)

        var address = try Self.address(path)
        var info = stat()
        if lstat(path, &info) == 0 {
            // A socket left by an earlier run is replaced. One that still
            // answers belongs to another running copy of SwarmBar, which
            // keeps it, as the port went to whichever copy bound it first.
            // Anything else is not ours to delete.
            guard (info.st_mode & S_IFMT) == S_IFSOCK else { throw Failure.occupied }
            guard !Self.answers(&address) else { throw Failure.inUse }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.system("socket", errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw Failure.system("bind", code)
        }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else {
            let code = errno
            close(fd)
            throw Failure.system("listen", code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            while true {
                let client = Darwin.accept(fd, nil, nil)
                guard client >= 0 else { return }
                _ = fcntl(client, F_SETFD, FD_CLOEXEC)
                _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                var uid: uid_t = 0
                var gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                    close(client)
                    continue
                }
                var pid: pid_t = 0
                var length = socklen_t(MemoryLayout<pid_t>.size)
                let ancestry = getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 && pid > 0
                    ? SessionProcessRegistry.ancestry(ofPeer: Int(pid), parent: SessionProcessRegistry.parent(of:))
                    : []
                accept(UnixHookClient(fd: client, peerAncestry: ancestry))
            }
        }
        source.setCancelHandler { close(fd) }
        listener.withLock { $0 = (fd, source) }
        source.resume()
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw Failure.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// Whether something is accepting connections at the address.
    private static func answers(_ address: inout sockaddr_un) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0
    }

    func stop() {
        listener.withLock { current in
            current.source?.cancel()
            current = (-1, nil)
        }
        unlink(path)
    }

    /// Creates the socket's folder owner-only, or confirms an existing one
    /// is a real directory this user owns and makes it owner-only.
    static func prepareDirectory(_ directory: String) throws {
        if mkdir(directory, 0o700) != 0, errno != EEXIST {
            let parent = (directory as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: parent, withIntermediateDirectories: true)
            guard mkdir(directory, 0o700) == 0 || errno == EEXIST else {
                throw Failure.directory(String(cString: strerror(errno)))
            }
        }
        var info = stat()
        guard lstat(directory, &info) == 0 else {
            throw Failure.directory(String(cString: strerror(errno)))
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw Failure.directory("not a folder") }
        guard info.st_uid == getuid() else { throw Failure.directory("owned by another user") }
        guard chmod(directory, 0o700) == 0 else {
            throw Failure.directory(String(cString: strerror(errno)))
        }
    }
}
