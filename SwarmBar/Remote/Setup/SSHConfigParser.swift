import Foundation
import Darwin

/// Reads host aliases out of an ssh_config, because the setup wizard offers
/// the user's own aliases rather than asking them to type hostnames. It is
/// deliberately lenient: anything it does not understand is skipped, since
/// a missing candidate costs one typed alias and a thrown error costs the
/// whole list.
enum SSHConfigParser {
    /// Include nesting stops here, so a file that includes itself ends.
    static let maxIncludeDepth = 8

    /// `read` and `list` are injected so tests run on in-memory files. `list`
    /// expands one glob pattern to sorted absolute paths and is only asked
    /// about patterns that actually contain a wildcard.
    static func aliases(
        in text: String,
        baseDirectory: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        read: (URL) -> String?,
        list: (String) -> [String] = SSHConfigParser.glob
    ) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        collect(text, depth: 0, base: baseDirectory, home: home, read: read, list: list,
                result: &result, seen: &seen)
        return result
    }

    private static func collect(
        _ text: String, depth: Int, base: URL, home: URL,
        read: (URL) -> String?, list: (String) -> [String],
        result: inout [String], seen: inout Set<String>
    ) {
        // A Match line ends any Host block and its contents are conditional,
        // so nothing under it (an Include included) is followed. A later Host
        // line starts a fresh block and counts again.
        var inMatch = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard let (keyword, value) = split(String(rawLine)) else { continue }
            switch keyword {
            case "match":
                inMatch = true
            case "host":
                inMatch = false
                for name in tokens(value) where !name.hasPrefix("!")
                    && !name.contains("*") && !name.contains("?") {
                    if seen.insert(name).inserted { result.append(name) }
                }
            case "include":
                guard !inMatch, depth < maxIncludeDepth else { continue }
                for pattern in tokens(value) {
                    for url in expand(pattern, base: base, home: home, list: list) {
                        guard let body = read(url) else { continue }
                        collect(body, depth: depth + 1, base: base, home: home, read: read,
                                list: list, result: &result, seen: &seen)
                    }
                }
            default:
                break
            }
        }
    }

    /// Splits `Keyword value` or `Keyword=value` (spaces allowed around the
    /// `=`) into a lowercased keyword and the raw remainder.
    private static func split(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let end = trimmed.firstIndex(where: { $0 == "=" || $0 == " " || $0 == "\t" }) else {
            return (trimmed.lowercased(), "")
        }
        var rest = trimmed[end...].drop(while: { $0 == " " || $0 == "\t" })
        if rest.first == "=" { rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" }) }
        return (trimmed[..<end].lowercased(), String(rest))
    }

    /// Whitespace-separated words where double quotes group a word. An
    /// unquoted `#` ends the line, as ssh treats it.
    private static func tokens(_ value: String) -> [String] {
        var out: [String] = []
        var current = ""
        var started = false
        var quoted = false
        for ch in value {
            if ch == "\"" {
                quoted.toggle()
                started = true
            } else if !quoted && (ch == " " || ch == "\t") {
                if started { out.append(current) }
                current = ""
                started = false
            } else if !quoted && ch == "#" && !started {
                break
            } else {
                current.append(ch)
                started = true
            }
        }
        if started { out.append(current) }
        return out
    }

    private static func expand(
        _ pattern: String, base: URL, home: URL, list: (String) -> [String]
    ) -> [URL] {
        let absolute: String
        if pattern.hasPrefix("~/") {
            absolute = home.appendingPathComponent(String(pattern.dropFirst(2))).path
        } else if pattern.hasPrefix("/") {
            absolute = pattern
        } else {
            absolute = base.appendingPathComponent(pattern).path
        }
        guard absolute.contains(where: { "*?[".contains($0) }) else {
            return [URL(fileURLWithPath: absolute)]
        }
        return list(absolute).map { URL(fileURLWithPath: $0) }
    }

    /// glob(3) already sorts, which keeps Include order stable.
    static func glob(_ pattern: String) -> [String] {
        var g = glob_t()
        defer { globfree(&g) }
        guard Darwin.glob(pattern, 0, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_pathc)).compactMap { g.gl_pathv[$0].map { String(cString: $0) } }
    }
}

/// What `ssh -G` says an alias resolves to. Only the fields the wizard uses
/// to tell hosts apart.
struct SSHResolved: Equatable, Sendable {
    let hostname: String
    let user: String
    let port: Int

    /// `ssh -G` prints lowercase `keyword value` lines. A missing field makes
    /// the whole parse nil rather than guessing a default.
    static func parse(_ sshGOutput: String) -> SSHResolved? {
        var hostname: String?, user: String?, port: Int?
        for line in sshGOutput.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch parts[0] {
            case "hostname": hostname = hostname ?? value
            case "user": user = user ?? value
            case "port": port = port ?? Int(value)
            default: break
            }
        }
        guard let hostname, let user, let port else { return nil }
        return SSHResolved(hostname: hostname, user: user, port: port)
    }
}
