import Foundation

enum TunnelQuality: Equatable {
    case ipv4Routes, universityRoute, unverified

    var title: String {
        switch self {
        case .ipv4Routes: return "Connected · IPv4 routes detected"
        case .universityRoute: return "Connected · University route detected"
        case .unverified: return "VPN running · Unverified"
        }
    }

    var detail: String {
        switch self {
        case .ipv4Routes:
            return "Sampled IPv4 routes and university DNS detected. IPv6 and reachability are not verified."
        case .universityRoute:
            return "University routing detected. Internet routing or DNS is unverified."
        case .unverified:
            return "gof5 is running. Routing checks are inconclusive; the session has been left running."
        }
    }
}

enum TunnelHealth: Equatable {
    case stopped, running(TunnelQuality), unavailable

    var running: Bool { if case .running = self { return true }; return false }
    var canDisconnect: Bool { self != .stopped }
}

struct ProbeResult {
    let exitCode: Int32
    let output: String
}

/// Observation only: this type cannot start or stop processes. A utun route
/// may belong to another VPN; these are routing hints, not proof of privacy.
enum TunnelProbe {
    typealias Execute = (String, [String], TimeInterval) -> ProbeResult?

    static func helperState(_ result: ProbeResult?) -> TunnelHealth {
        guard let result, result.exitCode == 0 else { return .unavailable }
        switch result.output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "RUNNING": return .running(.unverified)
        case "STOPPED": return .stopped
        default: return .unavailable
        }
    }

    static func tunnelInterface(_ result: ProbeResult?) -> String? {
        guard let result, result.exitCode == 0 else { return nil }
        for line in result.output.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            if fields.count == 2, fields[0] == "interface:",
               fields[1].range(of: #"^utun[0-9]+$"#, options: .regularExpression) != nil {
                return String(fields[1])
            }
        }
        return nil
    }

    static func sample(helper: String, execute: Execute) -> TunnelHealth {
        let state = helperState(execute("/usr/bin/sudo", ["-n", helper, "status"], 2))
        guard state.running else { return state }
        let university = tunnelInterface(execute("/sbin/route", ["-n", "get", "139.165.214.214"], 2))
        guard let university else { return .running(.unverified) }
        let internet = ["8.8.8.8", "1.1.1.1"].map {
            tunnelInterface(execute("/sbin/route", ["-n", "get", $0], 2))
        }
        let dns = execute("/usr/sbin/scutil", ["--dns"], 2)
        let universityDNS = dns?.exitCode == 0 && dns?.output.range(
            of: #"(?m)^\s*nameserver\[[0-9]+\]\s*:\s*139\.165\.214\.214\s*$"#,
            options: .regularExpression) != nil
        return .running(internet.allSatisfy { $0 == university } && universityDNS
                        ? .ipv4Routes : .universityRoute)
    }

    /// A monotonic deadline bounds the wait even when commands take time.
    /// Running at the deadline is a usable, unverified session, never failure.
    static func wait(seconds: TimeInterval, now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                     pause: () -> Void = { Thread.sleep(forTimeInterval: 1) },
                     sample: () -> TunnelHealth) -> TunnelHealth {
        let deadline = now() + seconds
        while true {
            let health = sample()
            if health == .unavailable || now() >= deadline { return health }
            if case .running(let quality) = health, quality != .unverified { return health }
            pause()
        }
    }
}
