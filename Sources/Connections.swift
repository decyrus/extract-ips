import Foundation

struct IPv4: Hashable, Comparable {
    let value: UInt32

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let byte = UInt8(part), part == String(byte) else { return nil }
            value = (value << 8) | UInt32(byte)
        }
        self.value = value
    }

    init(value: UInt32) { self.value = value }
    var text: String { [24, 16, 8, 0].map { String((value >> $0) & 255) }.joined(separator: ".") }
    static func < (lhs: IPv4, rhs: IPv4) -> Bool { lhs.value < rhs.value }

    var isPublic: Bool {
        let excluded: [(UInt32, UInt32)] = [
            (0x00000000, 8), (0x0a000000, 8), (0x64400000, 10),
            (0x7f000000, 8), (0xa9fe0000, 16), (0xac100000, 12),
            (0xc0000000, 24), (0xc0000200, 24), (0xc0a80000, 16),
            (0xc6120000, 15), (0xc6336400, 24), (0xcb007100, 24),
            (0xe0000000, 3)
        ]
        return !excluded.contains { base, prefix in
            let mask = UInt32.max << (32 - prefix)
            return value & mask == base
        }
    }
}

struct AppIdentity: Hashable {
    let id: String
    let name: String
    let path: String
}

struct Peer {
    let pid: Int32
    let process: String
    let ip: IPv4
    let port: String
    let transport: String
    let interface: String
}

struct NetTopParser {
    private var pid: Int32?
    private var process = ""
    private var columns: [String] = []
    private(set) var sawHeader = false
    private(set) var ipv6Peers = Set<String>()
    private(set) var malformedRows = 0
    private(set) var diagnostic = ""

    // nettop quotes CSV fields containing commas; process names are untrusted input.
    static func csv(_ line: String) -> [String] {
        var result: [String] = [], field = ""
        var quoted = false
        var chars = line.makeIterator()
        while let char = chars.next() {
            if char == "\"" { quoted.toggle() }
            else if char == "," && !quoted { result.append(field); field = "" }
            else { field.append(char) }
        }
        result.append(field)
        return result
    }

    mutating func consume(_ line: String) -> Peer? {
        let fields = Self.csv(line.trimmingCharacters(in: .newlines))
        guard let label = fields.first, !line.isEmpty else { return nil }
        if label.isEmpty && fields.contains("interface") {
            columns = fields
            pid = nil
            sawHeader = true
            return nil
        }
        let isConnection = ["tcp4 ", "udp4 ", "tcp6 ", "udp6 "].contains { label.hasPrefix($0) }
        if !isConnection {
            if let dot = label.lastIndex(of: "."), let parsed = Int32(label[label.index(after: dot)...]), parsed > 0 {
                pid = parsed
                process = String(label[..<dot])
            } else {
                pid = nil
                if !label.isEmpty { diagnostic = String(line.prefix(300)) }
            }
            return nil
        }
        guard let pid, let separator = label.range(of: "<->"), sawHeader else {
            malformedRows += 1
            return nil
        }
        let endpoint = String(label[separator.upperBound...])
        let isV6 = label.hasPrefix("tcp6") || label.hasPrefix("udp6")
        guard let split = endpoint.lastIndex(of: isV6 ? "." : ":") else {
            malformedRows += 1
            return nil
        }
        var address = String(endpoint[..<split])
        let port = String(endpoint[endpoint.index(after: split)...])
        if address == "*" { return nil }
        if address.hasPrefix("::ffff:") { address = String(address.dropFirst(7)) }
        guard let ip = IPv4(address) else {
            if isV6 { ipv6Peers.insert(address) } else { malformedRows += 1 }
            return nil
        }
        guard let portNumber = UInt16(port), portNumber > 0 else { return nil }
        let interfaceIndex = columns.firstIndex(of: "interface")
        let interface = interfaceIndex.flatMap { $0 < fields.count ? fields[$0] : nil } ?? ""
        return Peer(pid: pid, process: process, ip: ip, port: port,
                    transport: label.hasPrefix("tcp") ? "TCP" : "UDP", interface: interface)
    }
}

struct ObservationKey: Hashable {
    let app: AppIdentity
    let ip: IPv4
}

struct Observation {
    let key: ObservationKey
    var ports = Set<String>()
    var transports = Set<String>()
    var interfaces = Set<String>()
    var processes = Set<String>()
    var count = 0
    let firstSeen: Date
    var lastSeen: Date

    mutating func add(_ peer: Peer, at date: Date) {
        ports.insert(peer.port)
        transports.insert(peer.transport)
        if !peer.interface.isEmpty { interfaces.insert(peer.interface) }
        processes.insert("\(peer.process) (\(peer.pid))")
        count += 1
        lastSeen = date
    }
}

struct ConnectionGroup {
    let app: AppIdentity
    let observations: [Observation]
    var ips: Set<IPv4> { Set(observations.map { $0.key.ip }) }
}

enum Processor {
    static func groups(_ observations: [Observation], includeLocal: Bool) -> [ConnectionGroup] {
        let filtered = observations.filter { includeLocal || $0.key.ip.isPublic }
        return Dictionary(grouping: filtered, by: { $0.key.app }).map { app, values in
            ConnectionGroup(app: app, observations: values.sorted { $0.key.ip < $1.key.ip })
        }.sorted {
            let comparison = $0.app.name.localizedStandardCompare($1.app.name)
            return comparison == .orderedSame ? $0.app.id < $1.app.id : comparison == .orderedAscending
        }
    }

    // Merge only fully observed, aligned ranges. A gap must never enlarge the whitelist.
    static func lines(_ ips: Set<IPv4>, compact: Bool) -> [String] {
        let sorted = ips.sorted()
        guard compact else { return sorted.map(\.text) }
        var result: [String] = []
        var index = 0
        while index < sorted.count {
            let start = UInt64(sorted[index].value)
            var end = index
            while end + 1 < sorted.count && UInt64(sorted[end + 1].value) == UInt64(sorted[end].value) + 1 { end += 1 }
            var cursor = start
            let last = UInt64(sorted[end].value)
            while cursor <= last {
                var bits = min(cursor == 0 ? 32 : cursor.trailingZeroBitCount, 32)
                while (UInt64(1) << bits) > last - cursor + 1 { bits -= 1 }
                let ip = IPv4(value: UInt32(cursor)).text
                result.append(bits == 0 ? ip : "\(ip)/\(32 - bits)")
                cursor += UInt64(1) << bits
            }
            index = end + 1
        }
        return result
    }

    static func exportJSON(_ lines: [String]) throws -> Data {
        let entries = lines.map { ["hostname": $0, "ip": $0, "ips": [$0]] as [String: Any] }
        return try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
