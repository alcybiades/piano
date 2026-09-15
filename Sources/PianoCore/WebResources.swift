import Foundation
import Darwin

public struct WebDownload: Sendable {
    public let url: URL
    public let mimeType: String
    public let data: Data
}

public enum PublicWebURL {
    public static func validate(_ url: URL) throws {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty,
              url.port == nil || [80, 443].contains(url.port!),
              !["localhost", "localhost.localdomain"].contains(host),
              !host.hasSuffix(".localhost"), !host.hasSuffix(".local"), !host.hasSuffix(".internal"),
              url.absoluteString.count <= 8192 else { throw PianoError("Use a public HTTP(S) URL without credentials or a custom port.") }
        let address = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if address.contains(":"), !isPublicAddress(address) { throw PianoError("Local and private network addresses are not supported.") }
        if address.allSatisfy({ $0.isNumber || $0 == "." }), !isPublicAddress(address) { throw PianoError("Local and private network addresses are not supported.") }
    }

    public static func isPublicAddress(_ text: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, text, &ipv4) == 1 {
            let value = UInt32(bigEndian: ipv4.s_addr), a = value >> 24, b = (value >> 16) & 255
            return a != 0 && a != 10 && a != 127 && a < 224 && !(a == 169 && b == 254)
                && !(a == 172 && (16...31).contains(b)) && !(a == 192 && b == 168)
                && !(a == 100 && (64...127).contains(b)) && !(a == 198 && (18...19).contains(b))
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, text, &ipv6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
        // Global unicast only. Exclude mapped IPv4, loopback, link-local and local subnets.
        return bytes[0] & 0xe0 == 0x20 && !(bytes[0] == 0x20 && bytes[1] == 0x02)
            && !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0 && bytes[3] == 0)
    }

    static func validateResolved(_ url: URL) throws {
        try validate(url)
        let host = url.host!.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { throw PianoError("Could not resolve the resource host.") }
        defer { freeaddrinfo(first) }
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0,
                  isPublicAddress(String(cString: buffer)) else { throw PianoError("Resource URLs must resolve to public internet addresses.") }
            node = current.pointee.ai_next
        }
    }
}

/// One bounded, cancellable GET. No cookies, stored credentials, browser session, or script execution.
public final class ResourceDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var session: URLSession?
    private var continuation: CheckedContinuation<WebDownload, Error>?
    private var data = Data()
    private var response: HTTPURLResponse?
    private var redirects = 0

    public init(limit: Int, configuration: URLSessionConfiguration = .ephemeral) {
        self.limit = limit; self.configuration = configuration.copy() as! URLSessionConfiguration
    }
    public func fetch(_ url: URL) async throws -> WebDownload {
        try PublicWebURL.validateResolved(url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = self.configuration
                configuration.httpShouldSetCookies = false
                configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
                configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 45
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                var request = URLRequest(url: url)
                request.setValue("Cadenza/0.2 (piano learning; resource reader)", forHTTPHeaderField: "User-Agent")
                request.setValue("text/html,text/plain,audio/midi,application/octet-stream;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
                let task = session.dataTask(with: request)
                lock.lock()
                self.continuation = continuation; self.session = session; self.task = task
                let alreadyCancelled = cancelled
                lock.unlock()
                if alreadyCancelled { finish(.failure(CancellationError())) } else { task.resume() }
            }
        } onCancel: { self.cancel() }
    }
    public func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel()
    }
    private func finish(_ result: Result<WebDownload, Error>) {
        lock.lock()
        let continuation = continuation, session = session
        self.continuation = nil; self.session = nil; self.task = nil
        lock.unlock()
        session?.invalidateAndCancel(); continuation?.resume(with: result)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish(.failure(PianoError("The resource returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0). Try another public source."))); return
        }
        guard response.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel); finish(.failure(PianoError("The resource exceeds the \(limit / 1_000_000) MB limit."))); return
        }
        self.response = http; completionHandler(.allow)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard self.data.count + data.count <= limit else { finish(.failure(PianoError("The resource exceeds the download size limit."))); return }
        self.data.append(data)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        do {
            redirects += 1
            guard redirects <= 5, let url = request.url else { throw PianoError("Too many resource redirects.") }
            try PublicWebURL.validateResolved(url)
            completionHandler(request)
        } catch { completionHandler(nil); finish(.failure(error)) }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling, nil) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        else if let response, let url = response.url { finish(.success(WebDownload(url: url, mimeType: response.mimeType ?? "", data: data))) }
        else { finish(.failure(PianoError("The resource returned no response."))) }
    }
}

public struct ResourcePage: Codable, Sendable {
    public struct Link: Codable, Equatable, Sendable {
        public var title: String
        public var url: String
        public var isMIDI: Bool
    }
    public var url: String
    public var title: String
    public var text: String
    public var links: [Link]

    public static func parse(_ html: String, url: URL) -> ResourcePage {
        func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
            (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]).matches(in: text, range: NSRange(text.startIndex..., in: text))) ?? []
        }
        func capture(_ match: NSTextCheckingResult, _ index: Int, _ text: String) -> String {
            guard let range = Range(match.range(at: index), in: text) else { return "" }; return String(text[range])
        }
        func replacing(_ pattern: String, _ text: String, _ replacement: String) -> String {
            text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        func plain(_ value: String) -> String {
            let stripped = replacing("<[^>]*>", value, " ")
            return replacing("\\s+", decodeEntities(stripped), " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let clean = replacing("(?s)<!--.*?-->|<(script|style|noscript|svg)\\b[^>]*>.*?</\\1\\s*>", html, " ")
        let title = matches("<title\\b[^>]*>(.*?)</title>", clean).first.map { plain(capture($0, 1, clean)) } ?? url.host ?? "Resource"
        let attribute = #"\b(?:href|src|data)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        var links: [Link] = [], seen = Set<String>()
        for match in matches(#"<a\b([^>]*)>(.*?)</a>|<(?:audio|source|embed|object|iframe)\b([^>]*)>"#, clean) {
            let anchorAttributes = capture(match, 1, clean)
            let attributes = anchorAttributes.isEmpty ? capture(match, 3, clean) : anchorAttributes
            for attr in matches(attribute, attributes) {
                let raw = (1...3).map { capture(attr, $0, attributes) }.first(where: { !$0.isEmpty }) ?? ""
                guard let link = URL(string: decodeEntities(raw), relativeTo: url)?.absoluteURL,
                      (try? PublicWebURL.validate(link)) != nil, seen.insert(link.absoluteString).inserted else { continue }
                let label = plain(capture(match, 2, clean))
                let midi = ["mid", "midi"].contains(link.pathExtension.lowercased()) || raw.lowercased().contains(".mid?")
                links.append(Link(title: String((label.isEmpty ? link.lastPathComponent : label).prefix(200)), url: link.absoluteString, isMIDI: midi))
            }
        }
        return ResourcePage(url: url.absoluteString, title: String(title.prefix(240)), text: plain(clean), links: links)
    }

    static func decodeEntities(_ input: String) -> String {
        var text = input
        for (entity, value) in [("&nbsp;", " "), ("&quot;", "\""), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] { text = text.replacingOccurrences(of: entity, with: value) }
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let digits = Range(match.range(at: 1), in: text), let whole = Range(match.range, in: text) else { continue }
                let value = String(text[digits]); let number = value.hasPrefix("x") ? UInt32(value.dropFirst(), radix: 16) : UInt32(value)
                if let number, let scalar = UnicodeScalar(number) { text.replaceSubrange(whole, with: String(scalar)) }
            }
        }
        return text
    }
}
