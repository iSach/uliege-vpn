import Foundation

@main
struct TunnelHealthTests {
    static func main() {
        var assertions = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            assertions += 1
            guard value() else { fatalError(label) }
        }
        func result(_ output: String, _ code: Int32 = 0) -> ProbeResult {
            ProbeResult(exitCode: code, output: output)
        }
        func probe(status: ProbeResult? = ProbeResult(exitCode: 0, output: "RUNNING"),
                   university: String? = "utun7", internet: [String?] = ["utun7", "utun7"],
                   dns: ProbeResult? = ProbeResult(exitCode: 0, output: "  nameserver[0] : 139.165.214.214")) -> TunnelHealth {
            TunnelProbe.sample(helper: "/fixed/helper") { path, args, _ in
                if path == "/usr/bin/sudo" { return status }
                if path == "/usr/sbin/scutil" { return dns }
                let iface: String?
                switch args.last {
                case "139.165.214.214": iface = university
                case "8.8.8.8": iface = internet[0]
                default: iface = internet[1]
                }
                return iface.map { result("    interface: " + $0) }
            }
        }
        check(probe() == .running(.ipv4Routes), "sampled IPv4 routes")
        check(probe(internet: ["en0", "en0"]) == .running(.universityRoute), "split tunnel remains running")
        check(probe(dns: nil) == .running(.universityRoute), "DNS command failure remains running")
        check(probe(dns: result("nameserver[0] : 139.165.214.2140")) == .running(.universityRoute), "DNS must match exactly")
        check(probe(dns: result("nameserver[0] : 139.165.214.214", 1)) == .running(.universityRoute), "DNS exit code")
        check(probe(university: nil) == .running(.unverified), "route failure remains running")
        check(probe(university: "en0") == .running(.unverified), "LAN route is not VPN evidence")
        check(probe(internet: ["utun2", "utun2"]) == .running(.universityRoute), "another VPN cannot prove full routing")
        check(probe(internet: ["utun7", "en0"]) == .running(.universityRoute), "both internet samples required")
        check(probe(status: result("STOPPED")) == .stopped, "explicit process exit")
        check(probe(status: nil) == .unavailable, "timeout is unknown, never stopped")
        check(probe(status: result("RUNNING", 1)) == .unavailable, "helper failure is unknown")
        check(probe(status: result("NOT RUNNING")) == .unavailable, "exact helper protocol")
        check(TunnelHealth.running(.unverified).canDisconnect, "unverified session has Disconnect")
        check(TunnelHealth.unavailable.canDisconnect, "unknown state has Disconnect")
        check(!TunnelHealth.stopped.canDisconnect, "stopped state has Connect")
        var time: TimeInterval = 0
        var samples = 0
        let waited = TunnelProbe.wait(seconds: 8, now: { time }, pause: { time += 1 }) {
            samples += 1
            return .running(.unverified)
        }
        check(waited == .running(.unverified) && samples == 9 && time == 8, "deadline preserves process")
        time = 0
        let slow = TunnelProbe.wait(seconds: 8, now: { time }, pause: { time += 1 }) {
            time += 4
            return .running(.unverified)
        }
        check(slow.running && time == 9, "slow probes count toward monotonic deadline")
        time = 0
        let startup = TunnelProbe.wait(seconds: 8, now: { time }, pause: { time += 1 }) {
            time < 2 ? .stopped : .running(.universityRoute)
        }
        check(startup == .running(.universityRoute) && time == 2, "allow child exec/startup race")
        print("Native tunnel health: \(assertions) assertions passed")
    }
}
