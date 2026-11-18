import Foundation

@main enum CoreTests {
    static func main() throws {
        for invalid in ["", "1.2.3", "1.2.3.256", "01.2.3.4", "-1.2.3.4", "1.2.3.4 ", "1.2.3.4/24", "::1"] {
            assert(IPv4(invalid) == nil, invalid)
        }
        for value in ["0.0.0.0", "1.2.3.4", "255.255.255.255"] { assert(IPv4(value)?.text == value) }
        for local in ["127.0.0.1", "10.1.2.3", "192.168.1.1", "172.16.0.1", "100.64.0.1", "169.254.0.1", "224.0.0.1", "255.255.255.255"] {
            assert(!IPv4(local)!.isPublic, local)
        }
        for publicIP in ["8.8.8.8", "1.1.1.1", "172.15.255.255", "172.32.0.0", "100.128.0.1"] {
            assert(IPv4(publicIP)!.isPublic, publicIP)
        }
        var parser = NetTopParser()
        assert(parser.consume(",interface,state,bytes_in,bytes_out,") == nil)
        assert(parser.consume("Browser Helper.42,,,0,0,") == nil)
        let first = parser.consume("tcp4 192.168.1.2:5000<->8.8.8.8:443,utun8,Established,1,2,")!
        assert(first.pid == 42 && first.ip.text == "8.8.8.8" && first.interface == "utun8" && first.transport == "TCP")
        assert(parser.consume("udp4 *:*<->*:*,en0,,0,0,") == nil)
        assert(parser.consume("tcp4 *:80<->*:*,en0,Listen,0,0,") == nil)
        assert(parser.consume("tcp6 ::1.5000<->2606:4700::1111.443,utun8,Established,1,2,") == nil)
        assert(parser.ipv6Peers.count == 1)
        assert(parser.consume("udp6 *.5000<->::ffff:1.1.1.1.443,en0,,1,2,")?.ip.text == "1.1.1.1")
        assert(parser.consume("tcp4 x:5000<->300.1.1.1:443,en0,Established,1,2,") == nil)
        assert(parser.malformedRows == 1)
        _ = parser.consume(",bytes_in,interface,state,bytes_out,")
        _ = parser.consume("\"Name, commas.43\",0,,,0,")
        let udp = parser.consume("udp4 *:5000<->1.1.1.1:443,0,en0,,2,")!
        assert(udp.process == "Name, commas" && udp.interface == "en0" && udp.transport == "UDP")
        _ = parser.consume(",interface,state,bytes_in,bytes_out,")
        assert(parser.consume("tcp4 x:5000<->8.8.8.8:443,en0,Established,1,2,") == nil)

        let app = AppIdentity(id: "/A.app", name: "A", path: "/A.app")
        let other = AppIdentity(id: "/B.app", name: "B", path: "/B.app")
        let date = Date(timeIntervalSince1970: 1)
        var observation = Observation(key: ObservationKey(app: app, ip: first.ip), firstSeen: date, lastSeen: date)
        observation.add(first, at: date)
        observation.add(first, at: date.addingTimeInterval(1))
        assert(observation.count == 2 && observation.ports == ["443"] && observation.firstSeen == date)
        let duplicate = Observation(key: ObservationKey(app: other, ip: first.ip), firstSeen: date, lastSeen: date)
        let local = Observation(key: ObservationKey(app: app, ip: IPv4("127.0.0.1")!), firstSeen: date, lastSeen: date)
        let groups = Processor.groups([observation, duplicate, local], includeLocal: false)
        assert(groups.count == 2 && groups[0].ips == groups[1].ips)
        assert(Set(groups.flatMap { $0.ips }).count == 1)
        assert(Processor.groups([local], includeLocal: false).isEmpty)
        assert(Processor.groups([local], includeLocal: true).count == 1)

        func addresses(_ strings: [String]) -> Set<IPv4> { Set(strings.map { IPv4($0)! }) }
        assert(Processor.lines(addresses(["8.8.8.0", "8.8.8.1"]), compact: true) == ["8.8.8.0/31"])
        assert(Processor.lines(addresses(["8.8.8.1", "8.8.8.2"]), compact: true) == ["8.8.8.1", "8.8.8.2"])
        assert(Processor.lines(addresses(["8.8.8.0", "8.8.8.2"]), compact: true) == ["8.8.8.0", "8.8.8.2"])
        assert(Processor.lines(addresses(["255.255.255.254", "255.255.255.255"]), compact: true) == ["255.255.255.254/31"])
        assert(Processor.lines(addresses(["0.0.0.0", "0.0.0.1"]), compact: true) == ["0.0.0.0/31"])
        assert(Processor.lines([], compact: true).isEmpty)
        assert(Processor.lines(addresses(["8.8.8.8", "1.1.1.1", "8.8.8.8"]), compact: false) == ["1.1.1.1", "8.8.8.8"])
        // Exhaust every subset of a small range, including gaps and prefix-boundary crossings.
        for mask in 0..<4096 {
            let input = Set((0..<12).filter { mask & (1 << $0) != 0 }.map { IPv4(value: 0x080808fa + UInt32($0)) })
            var expanded = Set<IPv4>()
            for line in Processor.lines(input, compact: true) {
                let components = line.split(separator: "/")
                let start = IPv4(String(components[0]))!.value
                let prefix = components.count == 2 ? Int(components[1])! : 32
                for offset in 0..<(1 << (32 - prefix)) { expanded.insert(IPv4(value: start + UInt32(offset))) }
            }
            assert(expanded == input, "CIDR changed the address set")
        }
        let json = try Processor.exportJSON(["8.8.8.0/31", "1.1.1.1"])
        let entries = try JSONSerialization.jsonObject(with: json) as! [[String: Any]]
        assert(entries[0]["hostname"] as? String == "8.8.8.0/31")
        assert(entries[0]["ip"] as? String == "8.8.8.0/31")
        assert(entries[0]["ips"] as? [String] == ["8.8.8.0/31"])

        if CommandLine.arguments.count > 1 {
            var live = NetTopParser()
            let file = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
            var peers = 0
            for line in file.components(separatedBy: .newlines) { if live.consume(line) != nil { peers += 1 } }
            assert(live.sawHeader && peers > 0 && live.malformedRows == 0)
            print("Real nettop fixture: \(peers) peers; 0 malformed rows")
        }
        print("PASS: parser, IPv4 validation/filtering, grouping, JSON schema, 4096 exact CIDR round trips")
    }
}
