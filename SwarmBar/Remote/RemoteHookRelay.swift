import Foundation

/// Where a relayed hook event came from, which is everything HookServer
/// needs beyond the event itself to route it as it would a local one.
struct RemoteHookOrigin: Sendable {
    let hostID: UUID
    /// The host's display name, which relayed rows carry as their `host`.
    let hostName: String
    /// The home's path on the host, spelled exactly as the helper sends it.
    /// The same spelling names the home in every snapshot, so a row a hook
    /// creates and the row discovery finds get the same id.
    let home: String
    /// That home's place in the mirror, where its Grok and Kimi state can be
    /// read to tell whose session this is. Nil when the mirror refuses the
    /// path.
    let mirrorHome: URL?
    /// The process names from the bridge up through its ancestors, as the
    /// helper read them off the socket's peer.
    let peer: [String]
    let approvalsOff: Set<AgentTool>
}

/// Sends a decision back for a request the helper is holding. The channel
/// in the app, a recorder in tests.
protocol RemoteHookReplying: Sendable {
    func sendHookReply(rid: String, body: JSONValue) async throws
}

extension SSHChannel: RemoteHookReplying {
    func sendHookReply(rid: String, body: JSONValue) async throws {
        _ = try await request("hook_reply", ["rid": .string(rid), "body": body])
    }
}

/// Turns one host's relayed hook events into the store updates and held
/// approvals a local hook produces, and sends each decision back as a
/// hook_reply. One per running host, started and cancelled with its
/// monitor, and the only reader of its channel's events.
@MainActor
final class RemoteHookRelay {
    private let hostID: UUID
    private let hostName: String
    private let mirror: RemoteMirror
    private let events: AsyncStream<HelperEvent>
    private let replier: any RemoteHookReplying
    private let hookServer: HookServer
    /// Read per event rather than once, so switching approvals off for a
    /// host in Settings applies to its next prompt without a restart.
    private let approvalsOff: @MainActor () -> Set<AgentTool>

    convenience init(
        connection: RemoteHostConnection, hookServer: HookServer,
        approvalsOff: (@MainActor () -> Set<AgentTool>)? = nil
    ) {
        let host = connection.host
        self.init(
            hostID: host.id, hostName: host.displayName, mirror: connection.mirror,
            events: connection.channel.events, replier: connection.channel,
            hookServer: hookServer, approvalsOff: approvalsOff ?? { host.approvalsOff })
    }

    init(
        hostID: UUID, hostName: String, mirror: RemoteMirror,
        events: AsyncStream<HelperEvent>, replier: any RemoteHookReplying,
        hookServer: HookServer, approvalsOff: @escaping @MainActor () -> Set<AgentTool>
    ) {
        self.hostID = hostID
        self.hostName = hostName
        self.mirror = mirror
        self.events = events
        self.replier = replier
        self.hookServer = hookServer
        self.approvalsOff = approvalsOff
    }

    /// Runs until the task is cancelled or the channel ends.
    func run() async {
        for await event in events {
            if Task.isCancelled { return }
            handle(event)
        }
    }

    func handle(_ event: HelperEvent) {
        guard let object = (try? JSONSerialization.jsonObject(with: event.payload)) as? [String: Any],
              let rid = object["rid"] as? String
        else { return }
        switch event.name {
        case "hook":
            relay(object, rid: rid)
        case "hook_resolved":
            hookServer.cancelRemote(rid: rid)
        default:
            break
        }
    }

    private func relay(_ object: [String: Any], rid: String) {
        // Only a request the helper is holding can take a reply. Anything
        // else it has already answered {}, and must be left alone.
        let held = object["held"] as? Bool == true
        let replier = replier
        let respond: (Data) -> Void = { json in
            let body = (try? JSONDecoder().decode(JSONValue.self, from: json)) ?? .object([:])
            Task {
                do {
                    try await replier.sendHookReply(rid: rid, body: body)
                } catch {
                    // The helper drops its holds when its Mac goes away, and
                    // the row is released when the hold window runs out.
                    NSLog("SwarmBar: hook_reply for \(rid) failed: \(error)")
                }
            }
        }
        guard let home = object["home"] as? String, let path = object["path"] as? String else {
            if held { respond(Data("{}".utf8)) }
            return
        }
        let origin = RemoteHookOrigin(
            hostID: hostID, hostName: hostName, home: home,
            mirrorHome: mirror.local(home),
            peer: object["peer"] as? [String] ?? [],
            approvalsOff: approvalsOff())
        hookServer.handleRemote(
            event: HookServer.eventName(fromPath: path),
            body: object["body"] as? [String: Any] ?? [:],
            accountLabel: (object["account"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            origin: origin, rid: rid, held: held, respond: respond)
    }
}
