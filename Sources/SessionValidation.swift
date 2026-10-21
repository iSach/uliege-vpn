import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum SessionValidationResponse {
    static let endpoint = URL(string: "https://vpn-2fa.uliege.be/vdesk/vpn/index.php3?outform=xml&client_version=2.0")!
    static let maximumBytes = 256 * 1024
    private static let declaredEncoding = try! NSRegularExpression(
        pattern: #"<\?xml\s[^?]*encoding\s*=\s*['"]([^'"]+)['"]"#, options: .caseInsensitive)

    static func validToken(_ token: String) -> Bool {
        (10...4096).contains(token.utf8.count) && token.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ||
            [43, 45, 46, 47, 61, 95, 126].contains($0)
        }
    }

    static func classify(status: Int, location: String?, body: Data) -> SessionValidationResult {
        if [301, 302, 303, 307, 308].contains(status), let location,
           let target = URL(string: location, relativeTo: endpoint)?.absoluteURL,
           target.scheme == "https", target.host == endpoint.host, target.user == nil, target.password == nil,
           target.port == nil || target.port == 443,
           ["/my.policy", "/my.logout.php3", "/vdesk/hangup.php3"].contains(target.path) {
            return .rejected
        }
        guard status == 200, !body.isEmpty, body.count <= maximumBytes else { return .unknown }
        // Inspect exactly the encoding the parser will see. UTF-16/32 or a
        // declared alternative encoding must not hide a DTD from the guard.
        guard let text = String(data: body, encoding: .utf8), !text.contains("\0") else { return .unknown }
        if let declaration = declaredEncoding.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(declaration.range(at: 1), in: text),
           !["utf-8", "utf8"].contains(text[range].lowercased()) { return .unknown }
        if text.contains("Session Expired/Timeout") { return .rejected }
        // No entity expansion or DTD loading, even from the fixed TLS endpoint.
        guard text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { return .unknown }
        let parser = XMLParser(data: body)
        let profiles = VPNProfileObserver()
        parser.delegate = profiles
        parser.shouldResolveExternalEntities = false
        return parser.parse() && profiles.vpn && profiles.hasProfile ? .accepted : .unknown
    }

    private final class VPNProfileObserver: NSObject, XMLParserDelegate {
        var depth = 0
        var vpn = false
        var hasProfile = false
        var inFavorite = false
        var params = ""
        var inParams = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            depth += 1
            if depth > 16 { parser.abortParsing(); return }
            if depth == 1 { vpn = attributes["type"] == "VPN" }
            if depth == 2, name == "favorite" { inFavorite = true }
            if depth == 3, inFavorite, name == "params" { inParams = true; params = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inParams { params += string }
        }

        func parser(_ parser: XMLParser, foundCDATA data: Data) {
            if inParams { params += String(decoding: data, as: UTF8.self) }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if depth == 3, inParams, name == "params" {
                hasProfile = hasProfile || !params.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                inParams = false
            }
            if depth == 2, name == "favorite" { inFavorite = false }
            depth -= 1
        }
    }
}

/// One bounded request on Connect only. Never follows redirects, uses shared
/// browser cookies/credentials, polls in the background or returns server text.
enum SavedSessionValidator {
    static func validate(_ token: String, configuration: URLSessionConfiguration = .ephemeral) async -> SessionValidationResult {
        guard SessionValidationResponse.validToken(token) else { return .unknown }
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 6
        configuration.waitsForConnectivity = false
        var request = URLRequest(url: SessionValidationResponse.endpoint)
        request.setValue("MRHSession=" + token, forHTTPHeaderField: "Cookie")
        // Same profile request and user agent as the bundled gof5 client.
        request.setValue("Mozilla/5.0 (X11; U; Linux i686; en-US; rv:1.9.1a2pre) Gecko/2008073000 Shredder/3.0a2pre ThunderBrowse/3.2.1.8", forHTTPHeaderField: "User-Agent")
        return await withCheckedContinuation { continuation in
            let delegate = ValidationRequest(continuation)
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
            delegate.session = session
            session.dataTask(with: request).resume()
        }
    }

    // All delegate callbacks run on one serial queue; continuation is set before
    // starting the task and resumed exactly once. The session cycle is broken on finish.
    private final class ValidationRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        var continuation: CheckedContinuation<SessionValidationResult, Never>?
        var session: URLSession?
        var response: HTTPURLResponse?
        var body = Data()

        init(_ continuation: CheckedContinuation<SessionValidationResult, Never>) {
            self.continuation = continuation
        }

        func finish(_ result: SessionValidationResult) {
            guard let continuation else { return }
            self.continuation = nil
            session?.invalidateAndCancel()
            session = nil
            continuation.resume(returning: result)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
            finish(SessionValidationResponse.classify(status: response.statusCode,
                   location: response.value(forHTTPHeaderField: "Location"), body: Data()))
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let response = response as? HTTPURLResponse else {
                completionHandler(.cancel); finish(.unknown); return
            }
            self.response = response
            if response.statusCode != 200 {
                completionHandler(.cancel)
                finish(SessionValidationResponse.classify(status: response.statusCode,
                       location: response.value(forHTTPHeaderField: "Location"), body: Data()))
            } else if response.expectedContentLength > SessionValidationResponse.maximumBytes {
                completionHandler(.cancel); finish(.unknown)
            } else { completionHandler(.allow) }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard body.count + data.count <= SessionValidationResponse.maximumBytes else { finish(.unknown); return }
            body.append(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard error == nil, let response else { finish(.unknown); return }
            finish(SessionValidationResponse.classify(status: response.statusCode,
                   location: response.value(forHTTPHeaderField: "Location"), body: body))
        }
    }
}
