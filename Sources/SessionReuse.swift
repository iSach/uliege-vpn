import Foundation

/// Only this object contains the cookie. Its encoded form belongs in Keychain,
/// never UserDefaults, diagnostics, or the observation history.
struct CachedVPNSession: Codable {
    let version: Int
    let identifier: UUID
    let token: String
    let acquiredAt: Date?
    let account: String?

    init(token: String, acquiredAt: Date?, account: String?) {
        version = 1
        identifier = UUID()
        self.token = token
        self.acquiredAt = acquiredAt
        self.account = account?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func decode(_ data: Data) -> CachedVPNSession? {
        if let record = try? JSONDecoder().decode(Self.self, from: data), record.version == 1 {
            return record
        }
        // Undated/legacy values are never assigned a made-up acquisition time.
        guard let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return CachedVPNSession(token: token, acquiredAt: nil, account: nil)
    }
}

enum SessionReusePolicy {
    static let defaultMinutes = 60
    static let maximumMinutes = 24 * 60

    static func eligible(_ session: CachedVPNSession, account: String, maximumAge: TimeInterval,
                         rejectedIdentifiers: Set<UUID>, now: Date) -> Bool {
        guard maximumAge.isFinite, maximumAge > 0,
              !rejectedIdentifiers.contains(session.identifier),
              session.account == account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let acquired = session.acquiredAt else { return false }
        let age = now.timeIntervalSince(acquired)
        return age.isFinite && age >= 0 && age < min(maximumAge, TimeInterval(maximumMinutes * 60))
    }

    static func ageDescription(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "unknown age" }
        let minutes = Int(min(seconds / 60, 1_000_000))
        if minutes < 1 { return "under 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

enum SessionValidationResult: String, Codable {
    case accepted, rejected, unknown

    var title: String {
        switch self {
        case .accepted: return "Accepted"
        case .rejected: return "Rejected"
        case .unknown: return "Unknown"
        }
    }
}

/// Deliberately cannot hold a cookie, account, URL, response body or log line.
struct SessionReuseObservation: Codable, Identifiable {
    let id: UUID
    let sessionIdentifier: UUID
    let date: Date
    let age: TimeInterval
    let result: SessionValidationResult

    init?(session: CachedVPNSession, result: SessionValidationResult, date: Date) {
        guard let acquired = session.acquiredAt else { return nil }
        let age = date.timeIntervalSince(acquired)
        guard age.isFinite, age >= 0 else { return nil }
        id = UUID()
        sessionIdentifier = session.identifier
        self.date = date
        self.age = age
        self.result = result
    }
}

struct SessionReuseHistory: Codable {
    private(set) var observations: [SessionReuseObservation] = []
    private(set) var rejectedIdentifiers: [UUID] = []
    static let preferenceKey = "sessionReuseHistory.v1"

    mutating func record(_ observation: SessionReuseObservation, now: Date = Date()) {
        if observation.result == .rejected {
            rejectedIdentifiers.removeAll { $0 == observation.sessionIdentifier }
            rejectedIdentifiers.append(observation.sessionIdentifier)
            rejectedIdentifiers = Array(rejectedIdentifiers.suffix(32))
        }
        observations.append(observation)
        prune(now: now)
    }

    mutating func prune(now: Date) {
        observations = Array(observations.filter {
            $0.age.isFinite && $0.age >= 0 &&
            now.timeIntervalSince($0.date) >= 0 && now.timeIntervalSince($0.date) <= 30 * 86400
        }.suffix(100))
        rejectedIdentifiers = Array(rejectedIdentifiers.suffix(32))
    }

    mutating func clearObservations() {
        observations.removeAll()
        // Clearing history must not make a rejected Keychain cookie usable.
    }

    static func load(_ data: Data?, now: Date = Date()) -> Self {
        guard let data, var history = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        history.prune(now: now)
        return history
    }

    var longestAcceptedAge: TimeInterval? {
        observations.filter { $0.result == .accepted }.map(\.age).max()
    }
}

struct SessionConnectionOutcome {
    let health: TunnelHealth
    /// False only for an unexpected Keychain save failure, not intentional no-cache mode.
    let cached: Bool
}

enum SessionConnectionError: LocalizedError {
    case stoppedAfterFreshLogin
    var errorDescription: String? {
        "gof5 exited after sign-in. The app did not stop the session. Check VPN support and connectivity."
    }
}

/// Injected operations allow the actual reconnect sequence to be tested with
/// synthetic sessions. There is intentionally no stop operation here.
struct SessionConnectionOperations {
    var now: () -> Date = Date.init
    let health: () -> TunnelHealth
    let load: () -> CachedVPNSession?
    let save: (CachedVPNSession) throws -> Void
    let invalidate: (UUID) -> Void
    let validate: (String) async -> SessionValidationResult
    let start: (String) throws -> Void
    let wait: () -> TunnelHealth
    let authenticate: () async throws -> String
    let observe: (SessionReuseObservation) async -> Void
    let progress: (String) async -> Void
}

enum SessionConnector {
    static func connect(account: String, maximumAge: TimeInterval, forceFresh: Bool,
                        rejectedIdentifiers: Set<UUID>, operations op: SessionConnectionOperations) async throws -> SessionConnectionOutcome {
        func protectExisting() -> SessionConnectionOutcome? {
            let health = op.health()
            return health.canDisconnect ? SessionConnectionOutcome(health: health, cached: true) : nil
        }
        if let existing = protectExisting() { return existing }

        if !forceFresh, maximumAge > 0, let saved = op.load(),
           SessionReusePolicy.eligible(saved, account: account, maximumAge: maximumAge,
                                       rejectedIdentifiers: rejectedIdentifiers, now: op.now()) {
            await op.progress("Checking recent saved sign-in…")
            let validation = await op.validate(saved.token) // Exactly one validation attempt.
            if let observation = SessionReuseObservation(session: saved, result: validation, date: op.now()) {
                await op.observe(observation)
            }
            if validation == .rejected { op.invalidate(saved.identifier) }
            if let existing = protectExisting() { return existing }
            if validation == .accepted {
                await op.progress("Saved sign-in accepted · Starting tunnel…")
                // A start error can occur after the process launches. The wait
                // must determine status before any fresh authentication attempt.
                try? op.start(saved.token)
                let health = op.wait()
                if health.canDisconnect { return SessionConnectionOutcome(health: health, cached: true) }
            }
            // Unknown network failures are not rejection, and never erase or
            // blacklist a cookie. All fallbacks require an explicitly stopped helper.
        }

        if let existing = protectExisting() { return existing }
        await op.progress("Getting a fresh university sign-in…")
        let token = try await op.authenticate()
        let fresh = CachedVPNSession(token: token, acquiredAt: op.now(), account: account)
        if let existing = protectExisting() { return existing }
        await op.progress("Starting tunnel and observing routing…")
        try op.start(token)
        let health = op.wait()
        guard health.canDisconnect else { throw SessionConnectionError.stoppedAfterFreshLogin }
        // Cookie age starts at fresh authentication, never at a successful reuse.
        var cached = true
        if maximumAge > 0 {
            do { try op.save(fresh) } catch { cached = false }
        }
        return SessionConnectionOutcome(health: health, cached: cached)
    }
}
