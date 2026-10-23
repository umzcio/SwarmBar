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
        let line = try await request("hook_reply", ["rid": .string(rid), "body": body])
        // `request` hands back any answer, and a refused reply landed
        // nowhere, so it counts as undelivered.
        let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        guard object?["ok"] as? Bool == true else {
            throw SSHChannelError.badResponse(String(decoding: line.prefix(200), as: UTF8.self))
        }
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
    /// Told when the helper process exits, so what the Mac learned from it
    /// (which pane each agent sits in) is dropped with the holds.
    private let onHelperExited: @MainActor () -> Void
    /// The newest helper process known to have exited. Its events, and any
    /// older one's, can still be draining from the old reader, and a hold
    /// they describe died with it.
    private var exitedGeneration = 0

    /// The connection's snapshot is forgotten when its helper exits, and
    /// `onHelperExited` hears about it afterwards.
    convenience init(
        connection: RemoteHostConnection, hookServer: HookServer,
        approvalsOff: (@MainActor () -> Set<AgentTool>)? = nil,
        onHelperExited: (@MainActor () -> Void)? = nil
    ) {
        let host = connection.host
        self.init(
            hostID: host.id, hostName: host.displayName, mirror: connection.mirror,
            events: connection.channel.events, replier: connection.channel,
            hookServer: hookServer, approvalsOff: approvalsOff ?? { host.approvalsOff },
            onHelperExited: { [weak connection] in
                connection?.noteLost()
                onHelperExited?()
            })
    }

    init(
        hostID: UUID, hostName: String, mirror: RemoteMirror,
        events: AsyncStream<HelperEvent>, replier: any RemoteHookReplying,
        hookServer: HookServer, approvalsOff: @escaping @MainActor () -> Set<AgentTool>,
        onHelperExited: @escaping @MainActor () -> Void = {}
    ) {
        self.hostID = hostID
        self.hostName = hostName
        self.mirror = mirror
        self.events = events
        self.replier = replier
        self.hookServer = hookServer
        self.approvalsOff = approvalsOff
        self.onHelperExited = onHelperExited
    }

    /// Runs until the task is cancelled or the channel ends. Either way no
    /// helper is left to take a reply, so the host's holds go with it.
    func run() async {
        for await event in events {
            if Task.isCancelled { break }
            handle(event)
        }
        hookServer.dropRemote(hostID: hostID)
    }

    func handle(_ event: HelperEvent) {
        if event.name == HelperEvent.helperExited {
            exitedGeneration = max(exitedGeneration, event.generation)
            hookServer.dropRemote(hostID: hostID)
            onHelperExited()
            return
        }
        // From a process already gone: whatever it held is gone too.
        if event.generation != 0 && event.generation <= exitedGeneration { return }
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
        let respond: (Data, ((Bool) -> Void)?) -> Void = { json, completion in
            let body = (try? JSONDecoder().decode(JSONValue.self, from: json)) ?? .object([:])
            Task { @MainActor in
                do {
                    try await replier.sendHookReply(rid: rid, body: body)
                    completion?(true)
                } catch {
                    // A decision that never landed leaves the agent at its
                    // own prompt, which the row then says.
                    NSLog("SwarmBar: hook_reply for \(rid) failed: \(error)")
                    completion?(false)
                }
            }
        }
        guard let home = object["home"] as? String, let path = object["path"] as? String else {
            if held { respond(Data("{}".utf8), nil) }
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
