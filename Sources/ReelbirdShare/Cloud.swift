import Foundation
import ReelbirdCore
import Synchronization

// Reelbird Cloud: hosted share links, so Share works without setting up a bucket.
//
// The app uploads exactly what it uploads to your own bucket. The difference is the keys: the
// server hands out short-lived R2 keys limited to one share's folder (`r/<id>/`), fetched the first
// time a share is written and renewed before they expire. The account token is the "secret" of a
// cloud `ShareDestination`.

/// The signed-in Cloud account. `~/Library/Application Support/Reelbird/cloud.json`; the token is a
/// generic password in the login Keychain (service "app.reelbird.cloud", account = server URL).
public struct CloudAccount: Codable, Hashable, Sendable {
    public struct Storage: Codable, Hashable, Sendable {
        public var endpoint: String
        public var bucket: String
        public var region: String
        public var prefix: String
        public var publicBaseURL: String
    }

    public var server: String
    public var email: String
    public var plan: String
    public var storage: Storage
    /// Share to Reelbird Cloud (true) or to your own bucket (false). Signing in turns it on.
    public var enabled: Bool

    public var isPro: Bool { plan == "pro" }

    /// The share destination for this account.
    public var destination: ShareDestination {
        ShareDestination(endpoint: storage.endpoint, bucket: storage.bucket, region: storage.region,
                         accessKeyID: "cloud", publicBaseURL: storage.publicBaseURL, prefix: storage.prefix,
                         cloudServer: server)
    }
}

public enum CloudSettings {
    public static let keychainService = "app.reelbird.cloud"

    /// Set to true when the hosted service is live. Until then Reelbird Cloud is hidden everywhere,
    /// except with `REELBIRD_CLOUD_URL` set (development against a local server).
    public static let launched = false

    /// Whether to show Reelbird Cloud at all.
    public static var isAvailable: Bool {
        launched || ProcessInfo.processInfo.environment["REELBIRD_CLOUD_URL"]?.isEmpty == false
    }

    /// The server the app signs in to. `REELBIRD_CLOUD_URL` overrides it.
    /// TODO(launch): https://watch.reelbird.app once the hosted service is live.
    public static var defaultServer: String {
        let env = ProcessInfo.processInfo.environment["REELBIRD_CLOUD_URL"]?.trimmingCharacters(in: .whitespaces)
        return normalizedServer(env?.isEmpty == false ? env! : "http://localhost:8788")
    }

    public static func normalizedServer(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        if !t.isEmpty, !t.contains("://") { t = "https://" + t }
        return t
    }

    public static var fileURL: URL {
        if let override = ProcessInfo.processInfo.environment["REELBIRD_CLOUD_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return ShareSettings.supportDirectory.appendingPathComponent("cloud.json")
    }

    /// The signed-in account, if there is one and its token is in the Keychain.
    public static func load() -> CloudAccount? {
        guard let data = try? Data(contentsOf: fileURL),
              let a = try? JSONCoding.decoder.decode(CloudAccount.self, from: data),
              token(for: a.server) != nil else { return nil }
        return a
    }

    public static func token(for server: String) -> String? {
        Keychain.get(service: keychainService, account: server)
    }

    public static func save(_ account: CloudAccount, token: String? = nil) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.writeAtomically(account, to: fileURL)
        if let token {
            try Keychain.deleteAll(service: keychainService)
            try Keychain.set(token, service: keychainService, account: account.server)
        }
    }

    /// Chooses between Reelbird Cloud and your own bucket for new shares.
    public static func setEnabled(_ on: Bool) throws {
        guard var a = load() else { return }
        a.enabled = on
        try save(a)
    }

    /// Signs out: revokes the token on the server (best effort) and forgets it here.
    public static func signOut() async {
        if let a = load(), let t = token(for: a.server) {
            try? await CloudAPI(server: a.server, token: t).logout()
        }
        try? FileManager.default.removeItem(at: fileURL)
        try? Keychain.deleteAll(service: keychainService)
        CloudKeys.forgetAll()
    }

    /// Refreshes plan and usage from the server and saves them.
    @discardableResult
    public static func refresh() async throws -> (account: CloudAccount, me: CloudAPI.Me)? {
        guard var a = load(), let t = token(for: a.server) else { return nil }
        let me = try await CloudAPI(server: a.server, token: t).me()
        a.email = me.email
        a.plan = me.plan
        a.storage = me.storage
        try save(a)
        return (a, me)
    }
}

/// Device sign-in, as used by the app's Sign In button and `reelbird cloud login`.
public struct CloudSignIn: Sendable {
    public var server: String
    public var userCode: String
    public var verifyURL: URL
    let deviceCode: String
    let interval: Double
    let expires: Date

    /// Asks the server for a code. Show `userCode` and open `verifyURL`, then call `wait()`.
    public static func start(server: String = CloudSettings.defaultServer, deviceName: String? = Host.current().localizedName) async throws -> CloudSignIn {
        let s = CloudSettings.normalizedServer(server)
        struct Start: Decodable { var deviceCode: String; var userCode: String; var verifyURL: String; var interval: Double; var expiresIn: Double }
        let r: Start = try await CloudAPI(server: s, token: nil).request("POST", "/api/device", body: ["name": deviceName ?? "Mac"])
        guard let url = URL(string: r.verifyURL) else { throw CloudAPI.error(0, "BadResponse", "The server sent an invalid sign-in link.") }
        return CloudSignIn(server: s, userCode: r.userCode, verifyURL: url, deviceCode: r.deviceCode,
                           interval: max(1, r.interval), expires: Date().addingTimeInterval(r.expiresIn))
    }

    /// Polls until the code is approved in the browser, then saves the account and turns Cloud on.
    public func wait() async throws -> CloudAccount {
        struct Token: Decodable { var token: String }
        let api = CloudAPI(server: server, token: nil)
        while Date() < expires {
            try Task.checkCancellation()
            do {
                let t: Token = try await api.request("POST", "/api/device/token", body: ["deviceCode": deviceCode])
                let me = try await CloudAPI(server: server, token: t.token).me()
                let account = CloudAccount(server: server, email: me.email, plan: me.plan, storage: me.storage, enabled: true)
                try CloudSettings.save(account, token: t.token)
                CloudKeys.forgetAll()
                return account
            } catch let e as ShareError where e.status == 428 {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        throw CloudAPI.error(410, "Expired", "The sign-in code expired. Try again.")
    }
}

/// The Reelbird Cloud HTTP API.
public struct CloudAPI: Sendable {
    public var server: String
    var token: String?

    public init(server: String, token: String?) {
        self.server = CloudSettings.normalizedServer(server)
        self.token = token
    }

    public struct Limits: Decodable, Sendable { public var activeLinks: Int?; public var storageBytes: Int64; public var analytics: Bool }
    public struct Usage: Decodable, Sendable { public var activeLinks: Int; public var storageBytes: Int64 }
    public struct Me: Decodable, Sendable {
        public var email: String
        public var plan: String
        public var limits: Limits
        public var usage: Usage
        public var accountURL: String
        /// Where Free accounts go to pay for Pro (the server sends them on to Stripe).
        public var upgradeURL: String?
        public var storage: CloudAccount.Storage
    }

    public struct Keys: Decodable, Sendable {
        var accessKeyId: String
        var secretAccessKey: String
        var sessionToken: String
        var expiresAt: Date
    }

    public struct Link: Decodable, Sendable, Hashable {
        public var id: String
        public var title: String?
        public var url: String
        public var createdAt: Date
        public var bytes: Int64
        public var views: Int
    }

    public struct Stats: Decodable, Sendable, Hashable {
        public struct Count: Decodable, Sendable, Hashable { public var name: String; public var views: Int }
        public struct Day: Decodable, Sendable, Hashable { public var day: String; public var views: Int }
        public var id: String
        public var title: String?
        public var views: Int
        public var opens: Int
        public var uniqueViewers: Int
        public var watchSeconds: Int
        public var averagePercent: Double?
        public var completionRate: Double?
        public var retention: [Double]
        public var chunkSeconds: Double
        public var duration: Double?
        public var byDay: [Day]
        public var referrers: [Count]
        public var devices: [Count]
        public var countries: [Count]
        public var locked: Bool
        public var statsURL: String
    }

    public func me() async throws -> Me { try await request("GET", "/api/me") }
    public func links() async throws -> [Link] { try await request("GET", "/api/shares") }
    public func stats(_ id: String) async throws -> Stats { try await request("GET", "/api/shares/\(id)/stats") }
    public func keys(_ id: String) async throws -> Keys { try await request("POST", "/api/shares/\(id)/credentials", body: [String: String]()) }
    public func sync(_ id: String) async throws { try await requestEmpty("POST", "/api/shares/\(id)/sync") }
    public func delete(_ id: String) async throws { try await requestEmpty("DELETE", "/api/shares/\(id)") }
    public func logout() async throws { try await requestEmpty("POST", "/api/logout") }
    /// Development servers only: switch plans without billing.
    public func setPlanForDevelopment(_ plan: String) async throws { try await requestEmpty("POST", "/api/dev/plan", body: ["plan": plan]) }

    // MARK: Transport

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpCookieStorage = nil
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s)) ?? (try? Date.ISO8601FormatStyle().parse(s)) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "Bad date \(s)"))
        }
        return d
    }()

    static func error(_ status: Int, _ code: String, _ message: String) -> ShareError {
        ShareError(status: status, code: code, message: message)
    }

    func raw(_ method: String, _ path: String, body: (any Encodable & Sendable)? = nil) async throws -> Data {
        guard let url = URL(string: server + path) else { throw Self.error(0, "BadServer", "The Reelbird Cloud address \(server) isn't valid.") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await Self.session.data(for: req)
        } catch let e as URLError {
            if e.code == .cancelled { throw CancellationError() }
            throw Self.error(0, "Offline", "Can't reach Reelbird Cloud (\(e.localizedDescription)).")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            struct Err: Decodable { var error: String; var message: String }
            if let e = try? JSONDecoder().decode(Err.self, from: data) { throw Self.error(status, e.error, e.message) }
            throw Self.error(status, "HTTP\(status)", "Reelbird Cloud answered HTTP \(status).")
        }
        return data
    }

    func request<T: Decodable>(_ method: String, _ path: String, body: (any Encodable & Sendable)? = nil) async throws -> T {
        let data = try await raw(method, path, body: body)
        do { return try Self.decoder.decode(T.self, from: data) } catch {
            throw Self.error(0, "BadResponse", "Reelbird Cloud sent a response this version of Reelbird doesn't understand.")
        }
    }

    func requestEmpty(_ method: String, _ path: String, body: (any Encodable & Sendable)? = nil) async throws {
        _ = try await raw(method, path, body: body)
    }
}

/// Short-lived upload keys per share, shared by every `S3Client` for the same account. Fetched on
/// the first request for a share and renewed five minutes before they expire.
public final class CloudKeys: Sendable {
    let api: CloudAPI
    let region: String
    private let cache = Mutex<[String: (signer: SigV4Signer, expires: Date)]>([:])
    private let inFlight = Mutex<[String: Task<(SigV4Signer, Date), any Error>]>([:])

    private static let shared = Mutex<[String: CloudKeys]>([:])

    /// One instance per server + token, so a live upload and a later publish reuse keys.
    static func shared(server: String, token: String, region: String) -> CloudKeys {
        let k = server + "\n" + token
        return shared.withLock { all in
            if let c = all[k] { return c }
            let c = CloudKeys(api: CloudAPI(server: server, token: token), region: region)
            all[k] = c
            return c
        }
    }

    static func forgetAll() { shared.withLock { $0.removeAll() } }

    init(api: CloudAPI, region: String) {
        self.api = api
        self.region = region
    }

    /// The share ID in a key or prefix like "r/<id>/hls/seg_00001.m4s" or "r/<id>".
    static func shareID(in key: String) -> String? {
        let parts = key.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return String(parts[1])
    }

    /// A signer for requests touching `key` (an object key, or a listing prefix).
    func signer(for key: String) async throws -> SigV4Signer {
        guard let id = Self.shareID(in: key) else {
            throw ShareError(status: 0, code: "NoShare", message: "Reelbird Cloud only writes inside a share's folder.", key: key)
        }
        if let c = cache.withLock({ $0[id] }), c.expires > Date().addingTimeInterval(300) { return c.signer }
        let task: Task<(SigV4Signer, Date), any Error> = inFlight.withLock { all in
            if let t = all[id] { return t }
            let api = self.api, region = self.region
            let t = Task { () throws -> (SigV4Signer, Date) in
                let k = try await api.keys(id)
                return (SigV4Signer(accessKeyID: k.accessKeyId, secretAccessKey: k.secretAccessKey, region: region,
                                    sessionToken: k.sessionToken), k.expiresAt)
            }
            all[id] = t
            return t
        }
        defer { _ = inFlight.withLock { $0.removeValue(forKey: id) } }
        let (signer, expires) = try await task.value
        cache.withLock { $0[id] = (signer, expires) }
        return signer
    }

    /// Drops cached keys for a share (after the storage service refused them).
    func invalidate(_ key: String) {
        guard let id = Self.shareID(in: key) else { return }
        _ = cache.withLock { $0.removeValue(forKey: id) }
    }

    /// Tells the server a share changed (title, size). Best effort.
    func didUpdate(_ key: String) {
        guard let id = Self.shareID(in: key) else { return }
        let api = self.api
        Task { try? await api.sync(id) }
    }
}
