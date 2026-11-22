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
    /// Whose session the event's id names, read from the mirror before the
    /// event reached the main actor. Nil when nothing was read ahead.
    var attribution: Attribution? = nil

    struct Attribution: Sendable, Equatable {
        let rawSessionID: String
        let tool: AgentTool?
    }

    /// The tool `raw` belongs to: the answer read ahead when there is one
    /// for this id, else read from the mirror now. The read is two tails of
    /// up to 4 MB and a JSON file of up to 16 MB, all sized by the host, so
    /// the relay reads ahead off the main actor and this fallback only runs
    /// for an event handed in some other way.
    nonisolated func tool(forRawSessionID raw: String) -> AgentTool? {
        if let attribution, attribution.rawSessionID == raw { return attribution.tool }
        return mirrorHome.flatMap { HookServer.originTool(rawSessionID: raw, home: $0) }
    }

    /// The Kimi-family process the helper found above the bridge of a
    /// PermissionRequest, which is the only process that session's keys
    /// may go to. Nil for every other event, and from an older helper.
    var agent: RemoteProcessBinding.Agent? = nil
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
    ///
    /// Each event's tool is read from the mirror first, off the main actor,
    /// and only then is the event handled here. The read's cost is set by
    /// file sizes the host chooses, and a host streaming hooks would
    /// otherwise spend it on the main actor once per event, starving the
    /// popover and every other host. Events are still taken one at a time,
    /// in order, so a hook_resolved never overtakes its hook; one that
    /// arrives faster than this keeps up queues against the channel's
    /// EventBudget, which ends the helper once it is full.
    func run() async {
        for await event in events {
            if Task.isCancelled { break }
            let attribution = await Self.attribute(event, mirror: mirror)
            if Task.isCancelled { break }
            handle(event, attribution: attribution)
        }
        hookServer.dropRemote(hostID: hostID)
    }

    /// The tool a hook event's session id belongs to, read from the mirror.
    /// Nonisolated and async, so it runs on the global executor and never
    /// on the main actor. Nil for anything that is not a hook with an id.
    nonisolated static func attribute(
        _ event: HelperEvent, mirror: RemoteMirror
    ) async -> RemoteHookOrigin.Attribution? {
        guard event.name == "hook",
              let object = (try? JSONSerialization.jsonObject(with: event.payload)) as? [String: Any],
              let home = object["home"] as? String,
              let body = object["body"] as? [String: Any],
              let raw = body["session_id"] as? String
        else { return nil }
        let tool = mirror.local(home).flatMap { HookServer.originTool(rawSessionID: raw, home: $0) }
        return RemoteHookOrigin.Attribution(rawSessionID: raw, tool: tool)
    }

    func handle(_ event: HelperEvent, attribution: RemoteHookOrigin.Attribution? = nil) {
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
            relay(object, rid: rid, attribution: attribution)
        case "hook_resolved":
            hookServer.cancelRemote(rid: rid)
        default:
            break
        }
    }

    private func relay(
        _ object: [String: Any], rid: String, attribution: RemoteHookOrigin.Attribution?
    ) {
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
                    SwarmLog.log("SwarmBar: hook_reply for \(rid) failed: \(error)")
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
            approvalsOff: approvalsOff(),
            attribution: attribution,
            agent: RemoteProcessBinding.agent(from: object["agent"]))
        hookServer.handleRemote(
            event: HookServer.eventName(fromPath: path),
            body: object["body"] as? [String: Any] ?? [:],
            accountLabel: (object["account"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            origin: origin, rid: rid, held: held, respond: respond)
    }
}
