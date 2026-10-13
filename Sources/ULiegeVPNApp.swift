import AppKit
import Combine
import Foundation
import LocalAuthentication
import Security
import SwiftUI

private enum VPNConstants {
    static let helper = "/Library/PrivilegedHelperTools/be.uliege.vpn/helper"
    static let sessionService = "be.uliege.vpn.f5session.app-v2"
    static let vpnDNS = "139.165.214.214"
    // This binary includes Python + Playwright + Keychain support. No uv or
    // Python runtime is needed on the colleague's computer.
    static let authExecutable = Bundle.main.resourceURL?
        .appendingPathComponent("AuthRuntime/uliege-auth").path

}

private struct CommandResult {
    let exitCode: Int32
    let output: String
}

private enum VPNError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}

/// Never invokes a shell and never includes a session token in argv for sudo.
/// The root helper ultimately passes --session to gof5 because that is gof5's API.
private enum Commands {
    static func run(_ path: String, _ args: [String],
                    input: Data? = nil, environment: [String: String]? = nil,
                    timeout: TimeInterval = 300) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        if let environment { process.environment = environment }
        let standardOut = Pipe()
        let standardErr = Pipe()
        let standardIn = Pipe()
        process.standardOutput = standardOut
        process.standardError = standardErr
        process.standardInput = standardIn
        try process.run()
        if let input { standardIn.fileHandleForWriting.write(input) }
        try? standardIn.fileHandleForWriting.close()

        // Consume both streams concurrently to avoid an OS pipe deadlock.
        let group = DispatchGroup()
        var outData = Data()
        var errData = Data()
        group.enter()
        DispatchQueue.global().async {
            outData = standardOut.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = standardErr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.15)
        }
        if process.isRunning {
            process.terminate()
            _ = group.wait(timeout: .now() + 3)
            throw VPNError.message("A command exceeded its time limit.")
        }
        group.wait()
        process.waitUntilExit()
        let stdout = String(decoding: outData, as: UTF8.self)
        let stderr = String(decoding: errData, as: UTF8.self)
        // Don't return secret-bearing output from gof5. This is only for
        // the helper's fixed, nonsensitive status messages and auth diagnostics.
        return CommandResult(exitCode: process.terminationStatus,
                             output: stdout + (stderr.isEmpty ? "" : "\n" + stderr))
    }
}

private enum SessionStore {
    // Session persistence belongs to the native app, not to PyInstaller's
    // repeatedly re-signed Python executable. This avoids cross-app Keychain
    // access prompts, and a failed write must never block a working tunnel.
    static func save(_ value: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: VPNConstants.sessionService,
            kSecAttrAccount as String: NSUserName()
        ]
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw VPNError.message("Keychain couldn't save F5 session (status \(status)).")
        }
    }

    static func current() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: VPNConstants.sessionService,
            kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var found: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &found)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess, let data = found as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw VPNError.message("Cannot read the saved F5 session from Keychain (\(code)).")
        }
        return value
    }
}

private enum KeychainReadiness {
    // Checks ONLY for existence. Neither password nor TOTP secret is loaded.
    static func exists(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: NSUserName(),
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static var automaticLoginAvailable: Bool {
        VPNConstants.authExecutable != nil &&
        exists(service: "uliege-vpn-password") &&
        exists(service: "uliege-mfa-totp")
    }
}

private enum BrandIcon {
    private static let color: NSImage = {
        let image = NSImage(contentsOfFile: Bundle.main.path(forResource: "ULiegeColor", ofType: "png") ?? "") ?? NSImage()
        image.isTemplate = false
        return image
    }()
    private static let template: NSImage = {
        let image = NSImage(contentsOfFile: Bundle.main.path(forResource: "ULiegeTemplate", ofType: "png") ?? "") ?? NSImage()
        image.isTemplate = true
        return image
    }()
    static func image(connected: Bool) -> NSImage { connected ? color : template }
}

private enum ConnectionProbe {
    static func connected() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: VPNConstants.helper) else { return false }
        guard let helper = try? Commands.run("/usr/bin/sudo", ["-n", VPNConstants.helper, "status"], timeout: 5),
              helper.exitCode == 0, helper.output.contains("RUNNING") else { return false }
        guard let route = try? Commands.run("/sbin/route", ["-n", "get", "8.8.8.8"], timeout: 5),
              route.exitCode == 0,
              route.output.range(of: #"interface:\s+utun\d+"#, options: .regularExpression) != nil else {
            return false
        }
        guard let dns = try? Commands.run("/usr/sbin/scutil", ["--dns"], timeout: 5),
              dns.exitCode == 0, dns.output.contains(VPNConstants.vpnDNS) else { return false }
        return true
    }
}

@MainActor
final class VPNModel: ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case disconnecting
        case error(String)

        var title: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .disconnecting: return "Disconnecting…"
            case .error: return "Connection failed"
            }
        }
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var detail = "Ready"
    @Published private(set) var since: Date?
    @Published private(set) var helperInstalled = FileManager.default.isExecutableFile(atPath: VPNConstants.helper)

    @AppStorage("universityEmail") var universityEmail = ""
    @AppStorage("universityUsername") var universityUsername = ""
    @AppStorage("requireTouchID") var requireTouchID = false
    @AppStorage("showBrowser") var showBrowser = false
    @AppStorage("preferInteractiveLogin") var preferInteractiveLogin = false

    private var polling: Timer?
    private var busy = false
    private var sessionCacheWarning = false

    init() {
        polling = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    var connected: Bool { if case .connected = state { return true }; return false }
    var working: Bool { busy }
    var automaticLoginAvailable: Bool { KeychainReadiness.automaticLoginAvailable }

    func openSupportInstaller() {
        guard let installer = Bundle.main.resourceURL?
            .appendingPathComponent("Support/Install VPN Support.command"),
            FileManager.default.isExecutableFile(atPath: installer.path) else {
            state = .error("Bundled support installer is missing. Reinstall the app.")
            return
        }
        if !NSWorkspace.shared.open(installer) {
            state = .error("Could not open support installer. Open it from the app Resources/Support folder.")
            return
        }
        detail = "Approve installation in Terminal, then select Refresh status"
    }

    // The preference is a UI confirmation, not an OS security boundary.
    // Requiring Touch ID before switching it off avoids accidental bypass.
    func setTouchIDRequired(_ enabled: Bool) {
        if enabled { requireTouchID = true; return }
        guard requireTouchID else { return }
        Task {
            do {
                try await authorizeTouchID()
                requireTouchID = false
            } catch {
                detail = "Touch ID required to disable confirmation"
            }
        }
    }

    func refresh() {
        guard !busy else { return }
        let installed = FileManager.default.isExecutableFile(atPath: VPNConstants.helper)
        helperInstalled = installed
        DispatchQueue.global(qos: .utility).async {
            let online = ConnectionProbe.connected()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.busy else { return }
                if online {
                    if !self.connected { self.since = Date() }
                    self.state = .connected
                    self.detail = self.sessionCacheWarning
                        ? "Connected · Session couldn't be saved for reuse"
                        : "ULiège · Full tunnel"
                } else {
                    self.state = .disconnected
                    self.sessionCacheWarning = false
                    self.since = nil
                    self.detail = installed ? "Ready" : "One-time helper setup required"
                }
            }
        }
    }

    func connect() {
        guard !busy else { return }
        guard helperInstalled else {
            state = .error("Run the installer once to enable the VPN helper.")
            detail = "See README for installation"
            return
        }
        guard !universityEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .error("Enter your university email in Settings.")
            detail = "University email is required"
            return
        }
        busy = true
        state = .connecting
        detail = "Preparing connection…"
        Task {
            do {
                if requireTouchID { try await authorizeTouchID() }
                detail = "Checking saved session and authentication…"
                let email = universityEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                let user = universityUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                let headed = showBrowser
                let sessionCached = try await performConnect(
                    email: email, username: user,
                    headed: headed, preferInteractive: preferInteractiveLogin)
                since = Date()
                state = .connected
                sessionCacheWarning = !sessionCached
                detail = sessionCached
                    ? "ULiège · Full tunnel"
                    : "Connected · Session couldn't be saved for reuse"
            } catch {
                state = .error(error.localizedDescription)
                detail = "Check connection settings and authentication"
            }
            busy = false
        }
    }

    func disconnect() {
        guard !busy else { return }
        busy = true
        state = .disconnecting
        detail = "Stopping tunnel…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = try? Commands.run("/usr/bin/sudo", ["-n", VPNConstants.helper, "stop"], timeout: 25)
            let online = ConnectionProbe.connected()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                if online || result?.exitCode != 0 {
                    self.state = .error("Could not stop gof5. Check helper installation.")
                } else {
                    self.state = .disconnected
                    self.since = nil
                    self.detail = "Ready"
                }
            }
        }
    }

    private func authorizeTouchID() async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw error ?? VPNError.message("Touch ID unavailable. Configure it in macOS first.")
        }
        let authorized = try await context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Authorize ULiège VPN"
        )
        guard authorized else { throw VPNError.message("Touch ID cancelled.") }
    }

    private func performConnect(email: String, username: String,
                                headed: Bool, preferInteractive: Bool) async throws -> Bool {
        try await Task.detached(priority: .userInitiated) { [weak self] () throws -> Bool in
            if ConnectionProbe.connected() { return true }

            // Keychain read errors should not prevent a fresh sign-in.
            if let saved = try? SessionStore.current() {
                await MainActor.run { self?.detail = "Trying saved F5 session…" }
                // Rejected/expired cache must fall back to sign-in, not fail.
                do {
                    try Self.startHelper(session: saved)
                    if Self.waitForConnection(seconds: 20) { return true }
                } catch {
                    // Do not print cookie or pass it to an error formatter.
                }
                Self.stopHelper()
            }

            await MainActor.run {
                self?.detail = preferInteractive
                    ? "Waiting for browser sign-in…"
                    : "Signing in with Microsoft…"
            }
            let fresh = try Self.authenticate(email: email, username: username,
                                              headed: headed, preferInteractive: preferInteractive)
            await MainActor.run { self?.detail = "Starting tunnel and checking DNS…" }
            try Self.startHelper(session: fresh)
            if Self.waitForConnection(seconds: 30) {
                // Connection must work even if Keychain access is denied.
                do {
                    try SessionStore.save(fresh)
                    return true
                } catch {
                    return false
                }
            }
            let failure = Self.tunnelFailureDiagnosis()
            Self.stopHelper()
            throw VPNError.message(failure)
        }.value
    }

    nonisolated private static func startHelper(session: String) throws {
        guard !session.contains("\n") && !session.contains("\r") else {
            throw VPNError.message("Invalid F5 session format.")
        }
        let result = try Commands.run("/usr/bin/sudo", ["-n", VPNConstants.helper, "start"],
                                      input: Data((session + "\n").utf8), timeout: 15)
        guard result.exitCode == 0 else {
            throw VPNError.message("Privileged helper could not start (check one-time setup).")
        }
    }

    nonisolated private static func stopHelper() {
        _ = try? Commands.run("/usr/bin/sudo", ["-n", VPNConstants.helper, "stop"], timeout: 25)
    }

    /// Return only fixed, non-sensitive health information. Never read gof5
    /// command-line arguments or its raw log because they can contain cookies.
    nonisolated private static func tunnelFailureDiagnosis() -> String {
        let helper = try? Commands.run(
            "/usr/bin/sudo", ["-n", VPNConstants.helper, "status"], timeout: 5
        )
        guard helper?.exitCode == 0 else {
            return "VPN helper status failed. Check its one-time installation."
        }
        if !(helper?.output.contains("RUNNING") ?? false) {
            return "gof5 exited before the VPN tunnel became active."
        }
        let route = try? Commands.run("/sbin/route", ["-n", "get", "8.8.8.8"], timeout: 5)
        let routed = route?.exitCode == 0 &&
            route?.output.range(of: #"interface:\s+utun\d+"#, options: .regularExpression) != nil
        if !routed {
            return "gof5 is running, but the VPN route is missing."
        }
        let dns = try? Commands.run("/usr/sbin/scutil", ["--dns"], timeout: 5)
        if dns?.exitCode != 0 || !(dns?.output.contains(VPNConstants.vpnDNS) ?? false) {
            return "gof5 is running, but ULiège DNS is not configured."
        }
        return "The VPN helper is running, but the connection could not be verified."
    }

    nonisolated private static func waitForConnection(seconds: Int) -> Bool {
        for _ in 0 ..< seconds {
            if ConnectionProbe.connected() { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    nonisolated private static func authenticate(email: String, username: String,
                                                 headed: Bool, preferInteractive: Bool) throws -> String {
        let automatic = !preferInteractive && KeychainReadiness.automaticLoginAvailable
        guard let binary = VPNConstants.authExecutable,
              FileManager.default.isExecutableFile(atPath: binary) else {
            throw VPNError.message("Bundled authentication runtime is missing. Rebuild the app using build.sh.")
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["ULIEGE_EMAIL"] = email
        env["ULIEGE_USERNAME"] = username
        let args = automatic
            ? (["--mode", "automatic", "--emit-session", "--auth-only", "--refresh"] + (headed ? ["--headed"] : []))
            : ["--mode", "browser", "--emit-session"]
        let result: CommandResult
        do {
            result = try Commands.run(binary, args, environment: env,
                                      timeout: automatic ? 300 : 480)
        } catch {
            throw VPNError.message("Unable to start university sign-in: \(error.localizedDescription)")
        }
        guard result.exitCode == 0 else {
            let prefix = automatic ? "Automatic Microsoft sign-in failed" : "Browser sign-in was not completed"
            let diagnostic = Self.authDiagnostic(result.output)
            throw VPNError.message(prefix + ". " + diagnostic)
        }
        // Session credentials travel only over the child's private stdout
        // pipe; never forward this marker to logs or the UI.
        let prefix = "ULIEGE_F5_SESSION_B64:"
        guard let encoded = result.output.components(separatedBy: .newlines)
            .first(where: { $0.hasPrefix(prefix) })?.dropFirst(prefix.count),
              let data = Data(base64Encoded: String(encoded)),
              let session = String(data: data, encoding: .utf8),
              !session.isEmpty,
              !session.contains("\n"), !session.contains("\r") else {
            throw VPNError.message("Authentication completed, but no usable F5 session was returned.")
        }
        return session
    }

    /// Only allowlisted, nonsensitive diagnostics reach the UI. Browser
    /// exception tracebacks can contain authorization URLs and credentials.
    nonisolated private static func authDiagnostic(_ output: String) -> String {
        let messages = [
            "Sign-in timed out", "Authentication did not finish",
            "Timed out during authentication", "Could not open Google Chrome",
            "Login window closed", "Keychain error",
            "Timed out", "Could not complete", "No authentication method",
            "F5 session cookie was present", "F5 session cookie was never received"
        ]
        for line in output.components(separatedBy: .newlines).reversed() {
            if line.count < 160 && messages.contains(where: { line.localizedCaseInsensitiveContains($0) }) &&
                !line.contains("http") && !line.contains("=") {
                return String(line.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return automaticLoginFallbackHint
    }

    nonisolated private static var automaticLoginFallbackHint: String {
        "Try browser sign-in in Settings, or run a headed sign-in to troubleshoot."
    }

}

// AppKit owns the menu bar item explicitly. Unlike a purely SwiftUI
// MenuBarExtra label, the status button is created at app launch and held
// strongly for the app's full lifetime.
@MainActor
final class VPNStatusBarDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem?
    private var popover: NSPopover?
    private var model: VPNModel?
    private var observation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let model = VPNModel()
        self.model = model

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.item = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 330, height: 460)
        popover.contentViewController = NSHostingController(rootView: MenuContent(model: model))
        self.popover = popover

        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.sendAction(on: [.leftMouseUp])
            updateIcon(connected: model.connected)
            NSLog("ULiegeVPN: menu bar status item created")
        } else {
            NSLog("ULiegeVPN: ERROR: NSStatusItem has no button")
        }

        observation = model.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateIcon(connected: state == .connected)
            }
    }

    private func updateIcon(connected: Bool) {
        guard let button = item?.button else { return }
        // Copy so that size/template changes never modify the shared asset.
        let img = (BrandIcon.image(connected: connected).copy() as? NSImage) ?? NSImage()
        img.size = NSSize(width: 19, height: 19)
        img.isTemplate = !connected
        button.image = img
        button.toolTip = connected ? "ULiège VPN — Connected" : "ULiège VPN — Disconnected"
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = item?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

@main
struct ULiegeVPNApp: App {
    @NSApplicationDelegateAdaptor(VPNStatusBarDelegate.self) private var delegate

    // No main window: the AppKit delegate owns our status item and popover.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

private struct MenuContent: View {
    @ObservedObject var model: VPNModel
    @State private var settingsOpen = false
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(nsImage: BrandIcon.image(connected: true))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text("ULiège VPN").font(.headline)
                    Text("vpn-2fa.uliege.be").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(model.connected ? Color.green : Color.gray).frame(width: 9, height: 9)
            }
            if !model.helperInstalled {
                VStack(alignment: .leading, spacing: 7) {
                    Text("One-time VPN support setup").font(.headline)
                    Text("Install the bundled VPN network component before connecting. Administrator approval is required once.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Install VPN Support…") { model.openSupportInstaller() }
                        .buttonStyle(.bordered)
                    Text("Experimental installer: adds a restricted passwordless sudo permission. Read SECURITY.md before approving.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if model.universityEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Welcome · First-time setup").font(.headline)
                    Text("Enter your own ULiège email and identifier. Browser sign-in works without any TOTP setup.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Your university email", text: $model.universityEmail)
                        .textFieldStyle(.roundedBorder)
                    TextField("ULiège identifier (e.g. s123456)", text: $model.universityUsername)
                        .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.state.title).font(.title3.weight(.semibold))
                    Text(model.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.working { ProgressView().controlSize(.small) }
            }
            if model.connected, let since = model.since {
                Text("Connected for \(elapsed(since))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if case .error(let message) = model.state {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Button {
                if model.connected { model.disconnect() }
                else { model.connect() }
            } label: {
                Text(model.connected ? "Disconnect" : "Connect")
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.working || model.universityEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Divider()
            DisclosureGroup("Settings", isExpanded: $settingsOpen) {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("University email", text: $model.universityEmail)
                        .textFieldStyle(.roundedBorder)
                        TextField("ULiège identifier (optional)", text: $model.universityUsername)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Require Touch ID to connect", isOn: Binding(
                        get: { model.requireTouchID },
                        set: { model.setTouchIDRequired($0) }
                    ))
                    Toggle("Use browser sign-in (Authenticator or other MFA)", isOn: $model.preferInteractiveLogin)
                    if !model.automaticLoginAvailable && !model.preferInteractiveLogin {
                        Text("No local TOTP/password setup found. Browser sign-in will open automatically when required.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Button("Configure automatic TOTP sign-in…") { AutomaticSetupWindow.show(model: model) }
                    if model.automaticLoginAvailable {
                        Text("Automatic sign-in credentials found in this Mac’s Keychain.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Toggle("Show browser for automatic sign-in debugging", isOn: $model.showBrowser)
                    Text("With browser sign-in, you use your own university account and approved MFA. No TOTP secret needs to be configured or shared. Touch ID is an app confirmation, not a protection enforced by the privileged helper.")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }
            HStack {
                Button("Refresh status") { model.refresh() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }.font(.caption)
        }
        .padding(18)
        .frame(width: 330)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    private func elapsed(_ date: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        let hours = seconds / 3600
        return String(format: "%02d:%02d:%02d", hours, (seconds % 3600) / 60, seconds % 60)
    }
}
