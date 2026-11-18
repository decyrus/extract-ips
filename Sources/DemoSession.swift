import Foundation

enum DemoSession {
    // Documentation-only addresses; the explicit demo flag never starts a network capture.
    static func snapshot() -> CaptureSnapshot {
        let apps: [(String, String, [String])] = [
            ("Example Browser", "/Applications/Example Browser.app", ["192.0.2.16", "192.0.2.17", "192.0.2.18", "192.0.2.19", "198.51.100.24"]),
            ("Example Editor", "/Applications/Example Editor.app", ["198.51.100.24", "198.51.100.25"]),
            ("Example Music", "/Applications/Example Music.app", ["203.0.113.40", "203.0.113.41"])
        ]
        let now = Date()
        let observations = apps.flatMap { name, path, addresses in
            addresses.map { address -> Observation in
                let app = AppIdentity(id: path, name: name, path: path)
                var observation = Observation(key: ObservationKey(app: app, ip: IPv4(address)!), firstSeen: now, lastSeen: now)
                observation.add(Peer(pid: 100, process: name, ip: IPv4(address)!, port: "443", transport: "TCP", interface: "en0"), at: now)
                return observation
            }
        }
        return CaptureSnapshot(observations: observations, hasHeader: true)
    }
}
