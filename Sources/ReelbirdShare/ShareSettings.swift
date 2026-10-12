import Foundation
import ReelbirdCore
import Security

/// Where shares go. The non-secret part (`ShareDestination`) is JSON in
/// `~/Library/Application Support/Reelbird/share.json`; the secret access key is a generic
/// password in the login Keychain (service "app.reelbird.share", account = access key ID).
///
/// For the CLI and CI, `REELBIRD_S3_*` environment variables take precedence:
/// `REELBIRD_S3_ENDPOINT`, `REELBIRD_S3_BUCKET`, `REELBIRD_S3_ACCESS_KEY_ID`,
/// `REELBIRD_S3_SECRET_ACCESS_KEY`, `REELBIRD_S3_PUBLIC_BASE_URL`, and optionally
/// `REELBIRD_S3_REGION` (default "auto") and `REELBIRD_S3_PREFIX` (default "r").
public enum ShareSettings {
    public static let keychainService = "app.reelbird.share"

    /// The configured destination: environment first, then share.json. `nil` if not set up.
    public static func load() -> ShareDestination? {
        if let env = fromEnvironment() { return env }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONCoding.decoder.decode(ShareDestination.self, from: data)
    }

    /// Saves the destination and stores the secret in the Keychain (replacing any previous one).
    public static func save(_ d: ShareDestination, secret: String) throws {
        let clean = normalized(d)
        try validate(clean, secret: secret)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.writeAtomically(clean, to: fileURL)
        try Keychain.deleteAll(service: keychainService)
        try Keychain.set(secret, service: keychainService, account: clean.accessKeyID)
    }

    /// The secret access key: `REELBIRD_S3_SECRET_ACCESS_KEY` if set, else the Keychain item
    /// for the configured access key.
    public static func secret() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let s = env["REELBIRD_S3_SECRET_ACCESS_KEY"] ?? env["REELBIRD_S3_SECRET"], !s.isEmpty { return s }
        guard let d = load() else { return nil }
        return Keychain.get(service: keychainService, account: d.accessKeyID)
    }

    /// Removes share.json and the Keychain secret.
    public static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        try? Keychain.deleteAll(service: keychainService)
    }

    /// `~/Library/Application Support/Reelbird/share.json`
    public static var fileURL: URL {
        if let override = ProcessInfo.processInfo.environment["REELBIRD_SHARE_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return supportDirectory.appendingPathComponent("share.json")
    }

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Reelbird", isDirectory: true)
    }

    /// A destination from `REELBIRD_S3_*` variables, if the required ones are present.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> ShareDestination? {
        func v(_ k: String) -> String? {
            guard let s = env["REELBIRD_S3_\(k)"]?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        guard let endpoint = v("ENDPOINT"), let bucket = v("BUCKET"), let key = v("ACCESS_KEY_ID"),
              let base = v("PUBLIC_BASE_URL") else { return nil }
        return normalized(ShareDestination(endpoint: endpoint, bucket: bucket, region: v("REGION") ?? "auto",
                                           accessKeyID: key, publicBaseURL: base, prefix: v("PREFIX") ?? "r"))
    }

    /// Trims whitespace and trailing slashes, adds https:// where missing.
    public static func normalized(_ d: ShareDestination) -> ShareDestination {
        func url(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            while t.hasSuffix("/") { t.removeLast() }
            if !t.isEmpty, !t.contains("://") { t = "https://" + t }
            return t
        }
        var prefix = d.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if prefix.isEmpty { prefix = "r" }
        let region = d.region.trimmingCharacters(in: .whitespaces)
        return ShareDestination(endpoint: url(d.endpoint), bucket: d.bucket.trimmingCharacters(in: .whitespacesAndNewlines),
                                region: region.isEmpty ? "auto" : region,
                                accessKeyID: d.accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines),
                                publicBaseURL: url(d.publicBaseURL), prefix: prefix)
    }

    /// Checks that every field is filled in and the URLs parse.
    public static func validate(_ d: ShareDestination, secret: String) throws {
        func fail(_ m: String) -> ShareError { ShareError(status: 0, code: "InvalidSettings", message: m) }
        guard let e = URL(string: d.endpoint), e.host != nil else { throw fail("Enter the S3 endpoint URL, e.g. https://<account>.r2.cloudflarestorage.com.") }
        guard !d.bucket.isEmpty else { throw fail("Enter the bucket name.") }
        guard !d.accessKeyID.isEmpty else { throw fail("Enter the access key ID.") }
        guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw fail("Enter the secret access key.") }
        guard let p = URL(string: d.publicBaseURL), p.host != nil else { throw fail("Enter the public URL that serves the bucket, e.g. https://pub-xxxx.r2.dev.") }
    }
}

/// Login-Keychain generic passwords.
enum Keychain {
    static func set(_ value: String, service: String, account: String) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        let data = Data(value.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Reelbird share secret"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let s = SecItemAdd(add as CFDictionary, nil)
            guard s == errSecSuccess else { throw error(s) }
        } else if status != errSecSuccess {
            throw error(status)
        }
    }

    static func get(service: String, account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func deleteAll(service: String) throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        let s = SecItemDelete(q as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw error(s) }
    }

    static func error(_ status: OSStatus) -> ShareError {
        let text = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
        return ShareError(status: 0, code: "Keychain\(status)", message: "Couldn't save the secret in the Keychain: \(text)")
    }
}
