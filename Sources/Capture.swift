import AppKit

struct CaptureSnapshot {
    var observations: [Observation] = []
    var ipv6Count = 0
    var malformedRows = 0
    var hasHeader = false
}

final class CaptureService {
    private var process: Process?
    private var requestedStop = false
    var onUpdate: ((CaptureSnapshot) -> Void)?
    var onFinish: ((CaptureSnapshot, String?) -> Void)?

    func start() throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // shortcut: sampling may miss sub-second connections; use a Network Extension if packet-complete capture becomes required.
        process.arguments = ["-L", "0", "-n", "-x", "-s", "1", "-J", "interface,state,bytes_in,bytes_out"]
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        requestedStop = false
        try process.run()
        self.process = process
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var parser = NetTopParser()
            var observations: [ObservationKey: Observation] = [:]
            var identities: [Int32: (AppIdentity, Date)] = [:]
            var pending = Data()
            var lastUpdate = Date.distantPast
            var streamError: String?
            func snapshot() -> CaptureSnapshot {
                CaptureSnapshot(observations: Array(observations.values), ipv6Count: parser.ipv6Peers.count,
                                malformedRows: parser.malformedRows, hasHeader: parser.sawHeader)
            }
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                pending.append(data)
                while let newline = pending.firstIndex(of: 10) {
                    let line = String(decoding: pending[..<newline], as: UTF8.self)
                    pending.removeSubrange(...newline)
                    guard let peer = parser.consume(line) else { continue }
                    let now = Date()
                    let app: AppIdentity
                    if let cached = identities[peer.pid], now.timeIntervalSince(cached.1) < 2 { app = cached.0 }
                    else {
                        app = Self.identity(pid: peer.pid, fallback: peer.process)
                        identities[peer.pid] = (app, now)
                    }
                    let key = ObservationKey(app: app, ip: peer.ip)
                    var value = observations[key] ?? Observation(key: key, firstSeen: now, lastSeen: now)
                    value.add(peer, at: now)
                    observations[key] = value
                }
                if pending.count > 1_048_576 {
                    streamError = "capture_parse_error"
                    process.terminate()
                    break
                }
                if Date().timeIntervalSince(lastUpdate) >= 0.4 {
                    let update = snapshot()
                    DispatchQueue.main.async { self?.onUpdate?(update) }
                    lastUpdate = Date()
                }
            }
            // SIGTERM can interrupt a CSV row; only complete rows are observations.
            if !parser.sawHeader && !pending.isEmpty { _ = parser.consume(String(decoding: pending, as: UTF8.self)) }
            process.waitUntilExit()
            let final = snapshot()
            let diagnostic = parser.diagnostic
            let error = streamError
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                let failure: String?
                if let error { failure = L10n.text(error) }
                else if !final.hasHeader {
                    failure = L10n.text("capture_start_error", diagnostic)
                } else if !self.requestedStop {
                    failure = L10n.text("capture_interrupted", process.terminationStatus, diagnostic)
                } else { failure = nil }
                self.onFinish?(final, failure)
            }
        }
    }

    func stop() {
        requestedStop = true
        if let process, process.isRunning { process.terminate() }
    }

    static func identity(pid: Int32, fallback: String) -> AppIdentity {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = count > 0 ? String(cString: buffer) : ""
        // The outer .app owns nested browser helpers; matching names alone would join unrelated processes.
        if let range = path.range(of: ".app/") {
            let appPath = String(path[..<range.upperBound].dropLast())
            let bundle = Bundle(path: appPath)
            let name = [bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                        bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
                ?? URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
            return AppIdentity(id: appPath, name: name, path: appPath)
        }
        if !path.isEmpty { return AppIdentity(id: path, name: URL(fileURLWithPath: path).lastPathComponent, path: path) }
        return AppIdentity(id: "pid:\(pid):\(fallback)", name: fallback, path: "PID \(pid)")
    }
}
