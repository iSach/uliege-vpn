import AppKit
import Combine
import Foundation
import LocalAuthentication
import Security
import SwiftUI

private enum VPNConstants {
    static let helper = "/Library/PrivilegedHelperTools/be.uliege.vpn/helper"
    // v3 stores the acquisition date and account with the cookie. Older v2
    // entries are preserved but never reused with an unknown age.
    static let sessionService = "be.uliege.vpn.f5session.app-v3"
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
/// The hardened root helper forwards the session through another private pipe.
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
    static func save(_ value: CachedVPNSession) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: VPNConstants.sessionService,
            kSecAttrAccount as String: NSUserName()
        ]
        let data = try JSONEncoder().encode(value)
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

    static func current() throws -> CachedVPNSession? {
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
              let value = CachedVPNSession.decode(data) else {
            throw VPNError.message("Cannot read the saved F5 session from Keychain (\(code)).")
        }
        return value
    }

    static func removeIfMatching(_ identifier: UUID) {
        guard let current = try? current(), current.identifier == identifier else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: VPNConstants.sessionService,
            kSecAttrAccount as String: NSUserName()
        ]
        _ = SecItemDelete(query as CFDictionary)
        // A denied delete cannot resurrect the cookie: the nonsecret history
        // independently blocks rejected UUIDs, even after clearing observations.
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
    static func sample() -> TunnelHealth {
        guard FileManager.default.isExecutableFile(atPath: VPNConstants.helper) else { return .stopped }
        return TunnelProbe.sample(helper: VPNConstants.helper) { path, args, timeout in
            guard let result = try? Commands.run(path, args, timeout: timeout) else { return nil }
            return ProbeResult(exitCode: result.exitCode, output: result.output)
        }
    }
}

@MainActor
final class VPNModel: ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected(TunnelQuality)
        case statusUnavailable
        case disconnecting
        case error(String)

        var title: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .connecting: return "Connecting…"
            case .connected(let quality): return quality.title
            case .statusUnavailable: return "VPN status unavailable"
            case .disconnecting: return "Disconnecting…"
            case .error: return "Connection failed"
            }
        }
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var detail = "Ready"
    @Published private(set) var since: Date?
    @Published private(set) var helperInstalled = FileManager.default.isExecutableFile(atPath: VPNConstants.helper)
    @Published private(set) var helperNeedsUpdate = false

    @AppStorage("universityEmail") var universityEmail = ""
    @AppStorage("universityUsername") var universityUsername = ""
    @AppStorage("requireTouchID") var requireTouchID = false
    @AppStorage("showBrowser") var showBrowser = false
    @AppStorage("preferInteractiveLogin") var preferInteractiveLogin = true
    @AppStorage("sessionReuseMinutes") var sessionReuseMinutes = SessionReusePolicy.defaultMinutes
    @Published private(set) var sessionReuseHistory = SessionReuseHistory()

    private var polling: Timer?
    @Published private var busy = false
    private var sessionCacheWarning = false
    private var refreshing = false
    private var operationGeneration = 0

    init() {
        sessionReuseHistory = SessionReuseHistory.load(UserDefaults.standard.data(forKey: SessionReuseHistory.preferenceKey))
        sessionReuseMinutes = max(0, min(sessionReuseMinutes, SessionReusePolicy.maximumMinutes))
        polling = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    var connected: Bool { if case .connected = state { return true }; return false }
    var canDisconnect: Bool { connected || state == .statusUnavailable }
    var verified: Bool {
        if case .connected(let quality) = state { return quality != .unverified }
        return false
    }
    var working: Bool { busy }
    var chromeInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil
    }
    var emailConfigured: Bool {
        let email = universityEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        return email.contains("@") && !email.contains(where: { $0.isWhitespace })
    }
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

    private func apply(_ health: TunnelHealth) {
        switch health {
        case .running(let quality):
            if since == nil { since = Date() }
            state = .connected(quality)
            detail = quality.detail + (sessionCacheWarning ? " Session couldn't be saved for reuse." : "")
        case .stopped:
            state = .disconnected
            sessionCacheWarning = false
            since = nil
            detail = helperInstalled ? "Ready" : "One-time helper setup required"
        case .unavailable:
            state = .statusUnavailable
            detail = "Helper status could not be read. A session may still be running; Disconnect remains available."
        }
    }

    func refresh() {
        guard !busy, !refreshing else { return }
        helperInstalled = FileManager.default.isExecutableFile(atPath: VPNConstants.helper)
        if helperInstalled, let bundled = Bundle.main.resourceURL?.appendingPathComponent("Support/helper.sh"),
           let expected = try? Data(contentsOf: bundled),
           let installed = try? Data(contentsOf: URL(fileURLWithPath: VPNConstants.helper)) {
            helperNeedsUpdate = expected != installed
        }
        refreshing = true
        let generation = operationGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let health = ConnectionProbe.sample()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshing = false
                guard !self.busy, generation == self.operationGeneration else { return }
                self.apply(health)
            }
        }
    }

    func clearSessionObservations() {
        sessionReuseHistory.clearObservations()
        persistSessionHistory()
    }

    private func record(_ observation: SessionReuseObservation) {
        sessionReuseHistory.record(observation)
        persistSessionHistory()
    }

    private func persistSessionHistory() {
        if let data = try? JSONEncoder().encode(sessionReuseHistory) {
            UserDefaults.standard.set(data, forKey: SessionReuseHistory.preferenceKey)
        }
    }

    func connect(forceFresh: Bool = false) {
        guard !busy, !canDisconnect else { return }
        guard helperInstalled else {
            state = .error("Run the installer once to enable the VPN helper.")
            detail = "See README for installation"
            return
        }
        guard emailConfigured else {
            state = .error("Enter your university email in Settings.")
            detail = "University email is required"
            return
        }
        operationGeneration += 1
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
                let maximumAge = TimeInterval(max(0, min(sessionReuseMinutes, SessionReusePolicy.maximumMinutes)) * 60)
                let rejected = Set(sessionReuseHistory.rejectedIdentifiers)
                let outcome = try await performConnect(
                    email: email, username: user,
                    headed: headed, preferInteractive: preferInteractiveLogin,
                    maximumAge: maximumAge, forceFresh: forceFresh, rejected: rejected)
                sessionCacheWarning = !outcome.cached
                apply(outcome.health)
            } catch {
                let health = await Task.detached { ConnectionProbe.sample() }.value
                if health.canDisconnect {
                    apply(health)
                } else {
                    state = .error(error.localizedDescription)
                    detail = "Check connection settings and authentication"
                }
            }
            busy = false
        }
    }

    func disconnect() {
        guard !busy else { return }
        operationGeneration += 1
        busy = true
        state = .disconnecting
        detail = "Stopping tunnel…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = try? Commands.run("/usr/bin/sudo", ["-n", VPNConstants.helper, "stop"], timeout: 25)
            let health = ConnectionProbe.sample()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                self.apply(health)
                if result?.exitCode != 0 || health.canDisconnect {
                    self.detail = "Disconnect could not be confirmed. You can retry Disconnect or check VPN support."
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
                                headed: Bool, preferInteractive: Bool, maximumAge: TimeInterval,
                                forceFresh: Bool, rejected: Set<UUID>) async throws -> SessionConnectionOutcome {
        try await Task.detached(priority: .userInitiated) { [self] () throws -> SessionConnectionOutcome in
            let operations = SessionConnectionOperations(
                health: ConnectionProbe.sample,
                load: { try? SessionStore.current() },
                save: { fresh in try SessionStore.save(fresh) },
                invalidate: SessionStore.removeIfMatching,
                validate: { await SavedSessionValidator.validate($0) },
                start: Self.startHelper,
                wait: { Self.waitForConnection(seconds: 8) },
                authenticate: {
                    try Self.authenticate(email: email, username: username,
                                          headed: headed, preferInteractive: preferInteractive)
                },
                observe: { observation in await MainActor.run { self.record(observation) } },
                progress: { message in await MainActor.run { self.detail = message } }
            )
            do {
                return try await SessionConnector.connect(account: email, maximumAge: maximumAge,
                    forceFresh: forceFresh, rejectedIdentifiers: rejected, operations: operations)
            } catch SessionConnectionError.stoppedAfterFreshLogin {
                throw VPNError.message(Self.tunnelFailureDiagnosis())
            }
        }.value
    }

    nonisolated private static func startHelper(session: String) throws {
        guard (10...4096).contains(session.utf8.count),
              session.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
            throw VPNError.message("Invalid F5 session format.")
        }
        let result = try Commands.run("/usr/bin/sudo", ["-n", VPNConstants.helper, "start"],
                                      input: Data((session + "\n").utf8), timeout: 15)
        guard result.exitCode == 0 else {
            throw VPNError.message("Privileged helper could not start (check one-time setup).")
        }
    }

    nonisolated private static func tunnelFailureDiagnosis() -> String {
        "gof5 exited before routing could be checked. The app did not stop the session. Try a fresh browser sign-in."
    }

    nonisolated private static func waitForConnection(seconds: Int) -> TunnelHealth {
        TunnelProbe.wait(seconds: TimeInterval(seconds), sample: ConnectionProbe.sample)
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
            "Sign-in timed out": "Sign-in timed out. Try browser sign-in again.",
            "Authentication did not finish": "Authentication did not finish. Try visible browser sign-in.",
            "Could not open Google Chrome": "Install Google Chrome to use university sign-in.",
            "Login window closed": "The login window closed before sign-in completed.",
            "Keychain error": "Keychain access failed. Check local sign-in setup.",
            "F5 session cookie was present": "F5 authorization could not be confirmed.",
            "F5 session cookie was never received": "F5 did not return an authenticated session."
        ]
        for (phrase, message) in messages where output.localizedCaseInsensitiveContains(phrase) {
            return message
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
    private let loginItem = LoginItemSettings()
    private let sizing = PopoverSizing()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let model = VPNModel()
        self.model = model

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.item = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        sizing.updateScreen(item.button?.window?.screen)
        popover.contentSize = NSSize(width: PopoverSizing.width, height: sizing.height)
        sizing.onResize = { [weak popover] size in popover?.contentSize = size }
        popover.contentViewController = NSHostingController(rootView:
            FittingPopoverContent(sizing: sizing) {
                MenuContent(model: model, loginItem: loginItem)
            }
        )
        self.popover = popover

        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            updateIcon(connected: model.connected)
            NSLog("ULiegeVPN: menu bar status item created")
        } else {
            NSLog("ULiegeVPN: ERROR: NSStatusItem has no button")
        }

        observation = model.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if case .connected(let quality) = state {
                    self?.updateIcon(connected: true, verified: quality != .unverified, title: quality.title)
                } else {
                    self?.updateIcon(connected: false, verified: false, title: state.title)
                }
            }
    }

    private func updateIcon(connected: Bool, verified: Bool = true, title: String = "Disconnected") {
        guard let button = item?.button else { return }
        // Copy so that size/template changes never modify the shared asset.
        let img = (BrandIcon.image(connected: connected).copy() as? NSImage) ?? NSImage()
        img.size = NSSize(width: 19, height: 19)
        let warning = (connected && !verified) || title == "VPN status unavailable"
        img.isTemplate = !connected || warning
        button.image = img
        button.contentTintColor = warning ? .systemOrange : nil
        button.toolTip = "ULiège VPN — " + title
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = item?.button, let popover else { return }
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            popover.performClose(sender)
            let menu = NSMenu()
            let quit = NSMenuItem(title: "Quit ULiège VPN", action: #selector(quitApp(_:)), keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)
            NSMenu.popUpContextMenu(menu, with: event, for: button)
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            loginItem.refresh()
            sizing.updateScreen(button.window?.screen)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func quitApp(_ sender: Any?) { NSApp.terminate(sender) }
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
    @ObservedObject var loginItem: LoginItemSettings
    @State private var settingsOpen = false
    @State private var now = Date()
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false

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
                Circle().fill(model.verified ? Color.green : (model.canDisconnect ? Color.orange : Color.gray)).frame(width: 9, height: 9)
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
            if !onboardingCompleted || !model.emailConfigured {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Welcome · First-time setup").font(.headline)
                    Text("Enter your own ULiège email and identifier. Browser sign-in works without any TOTP setup.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Your university email", text: $model.universityEmail)
                        .textFieldStyle(.roundedBorder)
                    TextField("ULiège identifier (e.g. s123456)", text: $model.universityUsername)
                        .textFieldStyle(.roundedBorder)
                    Text(model.chromeInstalled ? "Google Chrome is ready for browser sign-in." : "Install Google Chrome before your first sign-in.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.chromeInstalled {
                        Button("Get Google Chrome ↗") {
                            NSWorkspace.shared.open(URL(string: "https://www.google.com/chrome/")!)
                        }
                    }
                    Button("Finish setup") { onboardingCompleted = true }
                        .disabled(!model.emailConfigured || !model.helperInstalled || !model.chromeInstalled)
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
                if model.canDisconnect { model.disconnect() }
                else { model.connect() }
            } label: {
                Text(model.canDisconnect ? "Disconnect" : "Connect")
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.working || (!model.canDisconnect && (!model.emailConfigured || !model.helperInstalled || !model.chromeInstalled)))
            Divider()
            DisclosureGroup("Settings", isExpanded: $settingsOpen) {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("University email", text: $model.universityEmail)
                        .textFieldStyle(.roundedBorder)
                    TextField("ULiège identifier (optional)", text: $model.universityUsername)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Launch at login", isOn: Binding(
                        get: { loginItem.isOn },
                        set: { enabled in Task { await loginItem.setEnabled(enabled) } }
                    ))
                    .disabled(loginItem.changing)
                    if loginItem.requiresApproval {
                        Text("Allow ULiège VPN in macOS Login Items to finish enabling launch at login.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Button("Open Login Items…") { loginItem.openSystemSettings() }
                    }
                    if let message = loginItem.errorMessage {
                        Text(message).font(.caption2).foregroundStyle(.red)
                    }
                    Toggle("Require Touch ID to connect", isOn: Binding(
                        get: { model.requireTouchID },
                        set: { model.setTouchIDRequired($0) }
                    ))
                    SessionReuseSettings(model: model)
                    Toggle("Use browser sign-in (Authenticator or other MFA)", isOn: $model.preferInteractiveLogin)
                    if !model.automaticLoginAvailable && !model.preferInteractiveLogin {
                        Text("No local TOTP/password setup found. Browser sign-in will open automatically when required.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if model.helperNeedsUpdate {
                        Text("VPN support update available. Disconnect before updating to apply the new helper protections.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Update VPN Support…") { model.openSupportInstaller() }
                        .disabled(model.working || model.canDisconnect)
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
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }

    private func elapsed(_ date: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        let hours = seconds / 3600
        return String(format: "%02d:%02d:%02d", hours, (seconds % 3600) / 60, seconds % 60)
    }
}

private struct SessionReuseSettings: View {
    @ObservedObject var model: VPNModel

    private var reuseDuration: String {
        model.sessionReuseMinutes == 0 ? "Always fresh" :
            "Up to " + SessionReusePolicy.ageDescription(TimeInterval(model.sessionReuseMinutes) * 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Reuse saved sign-in")
                Spacer()
                Text(reuseDuration).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.caption)
            SessionMinuteSlider(value: $model.sessionReuseMinutes)
            .frame(height: 22)
            .disabled(model.working)
            HStack {
                Text("Always fresh")
                Spacer()
                Text("24 hours")
            }
            .font(.caption2).foregroundStyle(.secondary)
            Text("0 means always sign in. This limit applies only on reconnect and never stops an active VPN. It is not the university's expiry time.")
                .font(.caption2).foregroundStyle(.secondary)
            Button("Sign in again without saved session") { model.connect(forceFresh: true) }
                .disabled(model.working || model.canDisconnect || !model.helperInstalled || !model.emailConfigured || !model.chromeInstalled)
            DisclosureGroup("Observed session reuse") {
                VStack(alignment: .leading, spacing: 6) {
                    if model.sessionReuseHistory.observations.isEmpty {
                        Text("No observations yet. Results appear after reusing a recent sign-in.")
                    } else {
                        let observations = model.sessionReuseHistory.observations
                        Text("\(observations.filter { $0.result == .accepted }.count) accepted · \(observations.filter { $0.result == .rejected }.count) rejected · \(observations.filter { $0.result == .unknown }.count) unknown")
                        if let age = model.sessionReuseHistory.longestAcceptedAge {
                            Text("Longest accepted age: " + SessionReusePolicy.ageDescription(age))
                        }
                        ForEach(Array(model.sessionReuseHistory.observations.suffix(5).reversed())) { observation in
                            Text(observation.result.title + " at " + SessionReusePolicy.ageDescription(observation.age) +
                                 " · " + observation.date.formatted(date: .abbreviated, time: .shortened))
                        }
                        Button("Clear observation history") { model.clearSessionObservations() }
                            .disabled(model.working)
                    }
                    Text("Only attempted reuse is observed. Unknown means the check was inconclusive. Local history contains times, ages and results, never credentials. These results do not guarantee a session lifetime.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
                .padding(.top, 6)
            }
            .font(.caption)
        }
    }
}
