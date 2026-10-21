import Foundation

private enum TestFailure: Error { case expected }

private final class ReconnectFixture {
    let account = "student@example.test"
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var saved: CachedVPNSession?
    var health: TunnelHealth = .stopped
    var healthSequence: [TunnelHealth] = []
    var waited: [TunnelHealth] = [.running(.unverified)]
    var validation: SessionValidationResult = .accepted
    var validationCalls = 0
    var loads = 0
    var authentications = 0
    var starts: [String] = []
    var writes: [CachedVPNSession] = []
    var invalidated: [UUID] = []
    var observations: [SessionReuseObservation] = []
    var saveFails = false
    var startFails = false
    var authFails = false
    var invalidationFails = false
    let freshToken = "synthetic-fresh-token-123"

    init(age: TimeInterval? = 1800) {
        saved = CachedVPNSession(token: "synthetic-cached-token-123",
                                 acquiredAt: age.map { now.addingTimeInterval(-$0) }, account: account)
    }

    var operations: SessionConnectionOperations {
        SessionConnectionOperations(
            now: { self.now },
            health: { self.healthSequence.isEmpty ? self.health : self.healthSequence.removeFirst() },
            load: { self.loads += 1; return self.saved },
            save: { record in
                if self.saveFails { throw TestFailure.expected }
                self.saved = record
                self.writes.append(record)
            },
            invalidate: { id in
                self.invalidated.append(id)
                if !self.invalidationFails { self.saved = nil }
            },
            validate: { _ in self.validationCalls += 1; return self.validation },
            start: { token in self.starts.append(token); if self.startFails { throw TestFailure.expected } },
            wait: { self.waited.isEmpty ? .running(.unverified) : self.waited.removeFirst() },
            authenticate: {
                self.authentications += 1
                if self.authFails { throw TestFailure.expected }
                return self.freshToken
            },
            observe: { self.observations.append($0) },
            progress: { _ in }
        )
    }

    func connect(age: TimeInterval = 3600, force: Bool = false, rejected: Set<UUID> = []) async throws -> SessionConnectionOutcome {
        try await SessionConnector.connect(account: account, maximumAge: age, forceFresh: force,
                                            rejectedIdentifiers: rejected, operations: operations)
    }
}

private final class ValidationProtocolFixture: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var error: URLError?
        var redirect = false
    }
    // Tests await each request before changing these fixtures. No real network.
    static var reply = Reply()
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let reply = Self.reply
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        if reply.redirect, let location = reply.headers["Location"], let url = URL(string: location, relativeTo: request.url) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: url.absoluteURL), redirectResponse: response)
        } else {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@main
struct SessionReuseTests {
    static var assertions = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        assertions += 1
        guard value() else { fatalError(label) }
    }

    static func main() async throws {
        let account = "student@example.test"
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let record = CachedVPNSession(token: "synthetic-cached-token-123", acquiredAt: now.addingTimeInterval(-1800), account: account)
        func eligible(_ value: CachedVPNSession = record, age: TimeInterval = 3600, at date: Date = now, rejected: Set<UUID> = []) -> Bool {
            SessionReusePolicy.eligible(value, account: account, maximumAge: age, rejectedIdentifiers: rejected, now: date)
        }
        check(eligible(), "reuse within the default hour")
        check(!eligible(age: 1800), "exact age boundary requires fresh sign-in")
        check(!eligible(age: 0), "zero disables reuse")
        check(!eligible(age: .nan), "NaN cannot enable reuse")
        check(!eligible(at: now.addingTimeInterval(-3600)), "clock rollback requires fresh sign-in")
        check(!eligible(CachedVPNSession(token: record.token, acquiredAt: nil, account: account)), "unknown age is never guessed")
        check(!eligible(CachedVPNSession(token: record.token, acquiredAt: record.acquiredAt, account: "other@example.test")), "account change requires fresh sign-in")
        check(!eligible(rejected: [record.identifier]), "rejected cookies never retry")
        let encoded = try JSONEncoder().encode(record)
        let decoded = CachedVPNSession.decode(encoded)!
        check(decoded.identifier == record.identifier && decoded.acquiredAt == record.acquiredAt, "Keychain record preserves identity and original age")
        let legacy = CachedVPNSession.decode(Data(record.token.utf8))!
        check(legacy.acquiredAt == nil && !eligible(legacy), "legacy raw cookie skips reuse")
        check(SessionReusePolicy.ageDescription(.infinity) == "unknown age", "invalid age formatting is safe")

        for health in [TunnelHealth.running(.unverified), .running(.universityRoute), .unavailable] {
            let f = ReconnectFixture(age: 86400)
            f.health = health
            let result = try await f.connect(age: 0, force: true)
            check(result.health == health, "existing/unknown session is preserved even for forced fresh sign-in")
            check(f.loads == 0 && f.validationCalls == 0 && f.authentications == 0 && f.starts.isEmpty, "running session bypasses all cache/auth work")
        }
        for age: TimeInterval? in [nil, 3600, 86_400, -100] {
            let f = ReconnectFixture(age: age)
            _ = try await f.connect()
            check(f.validationCalls == 0 && f.authentications == 1 && f.starts == [f.freshToken], "unknown/old/future cookie goes straight to fresh auth")
            check(f.observations.isEmpty, "a local age cutoff is not server rejection evidence")
        }
        for (limit, force) in [(TimeInterval(0), false), (3600, true)] {
            let f = ReconnectFixture()
            _ = try await f.connect(age: limit, force: force)
            check(f.loads == 0 && f.validationCalls == 0 && f.authentications == 1, "disabled/forced fresh does not read the saved cookie")
            check(limit > 0 || f.writes.isEmpty, "no-cache mode does not persist a new cookie")
        }
        do {
            let f = ReconnectFixture()
            let original = f.saved!
            let result = try await f.connect()
            check(result.health == .running(.unverified), "unverified running reuse is preserved")
            check(f.validationCalls == 1 && f.authentications == 0 && f.starts == [original.token], "one accepted cache attempt")
            check(f.writes.isEmpty && f.saved?.acquiredAt == original.acquiredAt, "successful reuse never resets acquisition time")
            check(f.observations.count == 1 && f.observations[0].result == .accepted && f.observations[0].age == 1800, "server acceptance is recorded at its actual age")
        }
        for validation in [SessionValidationResult.rejected, .unknown] {
            let f = ReconnectFixture()
            f.validation = validation
            let original = f.saved!
            _ = try await f.connect()
            check(f.validationCalls == 1 && f.authentications == 1 && f.starts == [f.freshToken], "rejected/unknown validation falls back exactly once without starting an old tunnel")
            check(f.observations.map(\.result) == [validation], "unknown is kept separate from rejection")
            check(f.invalidated == (validation == .rejected ? [original.identifier] : []), "network failures never blacklist a cookie")
            check(f.writes.first?.acquiredAt == f.now && f.writes.first?.identifier != original.identifier, "fresh sign-in gets its own timestamp and identifier")
        }
        do {
            let f = ReconnectFixture()
            f.waited = [.stopped, .running(.universityRoute)]
            _ = try await f.connect()
            check(f.validationCalls == 1 && f.authentications == 1 && f.starts.count == 2, "a cached process exit permits one fresh auth and one fresh start")
            check(f.observations.map(\.result) == [.accepted] && f.invalidated.isEmpty, "a tunnel startup failure is not cookie rejection")
        }
        do {
            let f = ReconnectFixture()
            f.startFails = true
            _ = try await f.connect()
            check(f.authentications == 0 && f.starts.count == 1, "start command errors cannot replace a process that is actually running")
        }
        do {
            let f = ReconnectFixture()
            f.waited = [.unavailable]
            let result = try await f.connect()
            check(result.health == .unavailable && f.authentications == 0, "uncertain status never triggers automatic replacement")
        }
        do {
            let f = ReconnectFixture()
            f.validation = .rejected
            f.healthSequence = [.stopped, .running(.unverified)]
            let result = try await f.connect()
            check(result.health.running && f.authentications == 0 && f.starts.isEmpty, "a concurrently started VPN is protected after validation")
        }
        do {
            let f = ReconnectFixture(age: 86400)
            f.healthSequence = [.stopped, .stopped, .unavailable]
            let result = try await f.connect()
            check(result.health == .unavailable && f.authentications == 1 && f.starts.isEmpty && f.writes.isEmpty, "concurrent/unknown state after auth is preserved without changing saved sessions")
        }
        do {
            let f = ReconnectFixture(age: 86400)
            f.saveFails = true
            let result = try await f.connect()
            check(result.health.running && !result.cached, "Keychain save failure does not disconnect")
        }
        do {
            let f = ReconnectFixture()
            f.validation = .rejected
            f.invalidationFails = true
            f.authFails = true
            do { _ = try await f.connect(); fatalError("expected auth failure") } catch TestFailure.expected {}
            let blocked = Set(f.observations.filter { $0.result == .rejected }.map(\.sessionIdentifier))
            do { _ = try await f.connect(rejected: blocked); fatalError("expected auth failure") } catch TestFailure.expected {}
            check(f.validationCalls == 1 && f.starts.isEmpty && f.authentications == 2, "a denied Keychain delete cannot cause a rejected cookie to retry")
        }
        do {
            let f = ReconnectFixture(age: 86400)
            f.waited = [.stopped]
            do { _ = try await f.connect(); fatalError("expected fresh tunnel exit") }
            catch SessionConnectionError.stoppedAfterFreshLogin {}
            check(f.authentications == 1 && f.starts.count == 1 && f.writes.isEmpty, "fresh failures do not loop or persist an unconfirmed tunnel session")
        }
        var history = SessionReuseHistory()
        let accepted = SessionReuseObservation(session: record, result: .accepted, date: now)!
        let rejected = SessionReuseObservation(session: record, result: .rejected, date: now.addingTimeInterval(300))!
        history.record(accepted, now: now)
        history.record(rejected, now: rejected.date)
        check(history.longestAcceptedAge == 1800 && history.rejectedIdentifiers.contains(record.identifier), "observed ages and blocked identifiers")
        history.clearObservations()
        check(history.observations.isEmpty && history.rejectedIdentifiers.contains(record.identifier), "clearing history does not resurrect a rejected cookie")
        for _ in 0..<110 { history.record(accepted, now: now) }
        check(history.observations.count == 100, "history is bounded")
        history.prune(now: now.addingTimeInterval(31 * 86400))
        check(history.observations.isEmpty, "30-day retention")
        history.record(accepted, now: now)
        let historyData = try JSONEncoder().encode(history)
        let historyText = String(decoding: historyData, as: UTF8.self)
        check(!historyText.contains(record.token) && !historyText.contains(account) && !historyText.contains("http"), "persisted observations contain no credentials, account or URLs")
        check(SessionReuseHistory.load(historyData, now: now).observations.count == 1, "history survives reload")
        check(SessionReuseHistory.load(Data("corrupt".utf8)).observations.isEmpty, "corrupt history is nonfatal")

        let xml = Data("<favorites type=\"VPN\"><favorite><params>resourcename=test&amp;id=1</params></favorite></favorites>".utf8)
        let classify = SessionValidationResponse.classify
        check(classify(200, nil, xml) == .accepted, "well-formed VPN profile means server acceptance")
        for path in ["/my.policy", "/my.logout.php3", "/vdesk/hangup.php3"] {
            check(classify(302, path, Data()) == .rejected, "F5's explicit login/logout redirects mean rejection")
        }
        for url in ["https://evil.test/my.policy", "https://vpn-2fa.uliege.be.evil.test/my.policy", "http://vpn-2fa.uliege.be/my.policy", "https://vpn-2fa.uliege.be:444/my.policy", "/unfamiliar"] {
            check(classify(302, url, Data()) == .unknown, "unrecognized or unsafe redirects are inconclusive")
        }
        for status in [401, 403, 500, 503] {
            check(classify(status, nil, xml) == .unknown, "generic HTTP failures are not expiration")
        }
        for text in ["<html>Sign in</html>", "<favorites type=\"VPN\"/>", "<favorites type=\"VPN\"><favorite><params>x", "<!DOCTYPE favorites [<!ENTITY x 'bad'>]><favorites type=\"VPN\"><favorite><params>&x;</params></favorite></favorites>"] {
            check(classify(200, nil, Data(text.utf8)) == .unknown, "HTML, missing profiles, broken XML and entities are not acceptance")
        }
        check(classify(200, nil, Data("Session Expired/Timeout".utf8)) == .rejected, "known F5 expiration response")
        let entityXML = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE favorites [<!ENTITY x 'profile'>]><favorites type=\"VPN\"><favorite><params>&x;</params></favorite></favorites>"
        check(classify(200, nil, entityXML.data(using: .utf16)!) == .unknown, "an alternate encoding cannot hide entity declarations")
        check(classify(200, nil, Data(("<?xml version=\"1.0\" encoding=\"UTF-7\"?>" + String(decoding: xml, as: UTF8.self)).utf8)) == .unknown, "declared non-UTF8 encoding is not parsed")
        check(classify(200, nil, Data([0xFF, 0xFE, 0xFF])) == .unknown, "malformed UTF8 is inconclusive")
        check(classify(200, nil, Data([0, 65, 0, 66])) == .unknown, "NUL-encoded content is inconclusive")
        check(classify(200, nil, Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + String(decoding: xml, as: UTF8.self)).utf8)) == .accepted, "standard UTF8 XML declaration is supported")
        check(classify(200, nil, Data(repeating: 65, count: SessionValidationResponse.maximumBytes + 1)) == .unknown, "bounded response size")

        func validate(_ reply: ValidationProtocolFixture.Reply, token: String = "synthetic-token-123") async -> SessionValidationResult {
            ValidationProtocolFixture.reply = reply
            ValidationProtocolFixture.requests = []
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ValidationProtocolFixture.self]
            return await SavedSessionValidator.validate(token, configuration: configuration)
        }
        var validation = await validate(.init(body: xml))
        check(validation == .accepted, "real URLSession path accepts profile fixture")
        check(ValidationProtocolFixture.requests.count == 1 && ValidationProtocolFixture.requests[0].url == SessionValidationResponse.endpoint, "exactly one request to the fixed F5 endpoint")
        check(ValidationProtocolFixture.requests[0].value(forHTTPHeaderField: "Cookie") == "MRHSession=synthetic-token-123", "cookie goes only in the HTTPS request header")
        validation = await validate(.init(status: 302, headers: ["Location":"https://vpn-2fa.uliege.be/my.policy"], redirect: true))
        check(validation == .rejected && ValidationProtocolFixture.requests.count == 1, "login redirects are classified without following them")
        validation = await validate(.init(status: 302, headers: ["Location":"https://evil.test/my.policy"], redirect: true))
        check(validation == .unknown && ValidationProtocolFixture.requests.count == 1, "cookie never follows cross-host redirects")
        validation = await validate(.init(error: URLError(.notConnectedToInternet)))
        check(validation == .unknown, "transport errors remain unknown")
        validation = await validate(.init(headers: ["Content-Length":"9999999"], body: xml))
        check(validation == .unknown, "declared oversized responses are stopped before parsing")
        validation = await validate(.init(body: Data(repeating: 65, count: SessionValidationResponse.maximumBytes + 1)))
        check(validation == .unknown, "streamed oversized responses are bounded")
        for token in ["short", "synthetic-token; other=1", "synthetic-token\r\nX:bad", String(repeating:"x", count:4097)] {
            validation = await validate(.init(body: xml), token: token)
            check(validation == .unknown && ValidationProtocolFixture.requests.isEmpty, "invalid token cannot inject headers or trigger network work")
        }
        print("Native session reuse: \(assertions) assertions passed")
    }
}
