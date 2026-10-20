import Foundation
import ReelbirdCore
import ReelbirdShare

/// `reelbird cloud …`: sign in to Reelbird Cloud, choose where new shares go, read link stats.
enum CloudCLI {
    static let spec = CommandSpec(name: "cloud", summary: "Reelbird Pro hosted links: `cloud login`, `status`, `use`, `links`, `stats`, `logout`.",
                                  positionals: ["ACTION", "ARG?"], options: [
        .value("server", "URL", "Cloud server (default \(CloudSettings.defaultServer), or $REELBIRD_CLOUD_URL)"),
        .flag("no-open", "Don't open the browser; print the sign-in link instead"),
    ], discussion: """
    Actions:
      login            Sign in in the browser; new shares then go to Reelbird Cloud
      status           Account, plan and usage
      use cloud|bucket Send new shares to Reelbird Cloud or to your own bucket (`config share`)
      links            Your hosted links with view counts
      stats PROJECT|ID Views, unique viewers, retention and sources of one link
      logout           Sign out on this Mac
    """)

    static func run(_ rest: [String]) async throws -> Report? {
        let a = try ArgumentParser.parse(rest, spec: spec)
        if a.has("help") || a.positional(0) == nil { return Report(json: ["help": .string(spec.help)], text: spec.help) }
        switch a.positional(0)! {
        case "login": return try await login(server: a.value("server") ?? CloudSettings.defaultServer, open: !a.has("no-open"))
        case "status": return try await status()
        case "use": return try use(a.positional(1))
        case "links": return try await links()
        case "stats": return try await stats(a.positional(1), library: a.value("library"))
        case "logout":
            await CloudSettings.signOut()
            return Report(json: ["signedIn": false], text: "Signed out of Reelbird Cloud.")
        case "plan":
            // Development servers only: switch plans without billing.
            let (api, _) = try signedIn()
            guard let plan = a.positional(1), ["free", "pro"].contains(plan) else { throw CLIError.usage("Use `cloud plan free` or `cloud plan pro`.") }
            try await wrap { try await api.setPlanForDevelopment(plan) }
            try await wrap { _ = try await CloudSettings.refresh() }
            return Report(json: ["plan": .string(plan)], text: "Plan set to \(plan).")
        case let other:
            throw CLIError.usage("Unknown cloud action '\(other)'.", hint: "Run `reelbird cloud --help`.")
        }
    }

    static func signedIn() throws -> (CloudAPI, CloudAccount) {
        guard let account = CloudSettings.load(), let token = CloudSettings.token(for: account.server) else {
            throw CLIError("Not signed in to Reelbird Cloud.", code: .unavailable, hint: "Run `reelbird cloud login`.")
        }
        return (CloudAPI(server: account.server, token: token), account)
    }

    static func wrap<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let e as ShareError {
            throw CLIError(e.message, code: e.status == 401 ? .unavailable : .failure,
                           hint: e.status == 401 ? "Run `reelbird cloud login`." : nil)
        }
    }

    static func login(server: String, open: Bool) async throws -> Report {
        let start = try await wrap { try await CloudSignIn.start(server: server) }
        Console.err("Your code: \(start.userCode)")
        if open {
            Console.err("Opening \(start.verifyURL.absoluteString) — approve the code there.")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = [start.verifyURL.absoluteString]
            try? p.run()
        } else {
            Console.err("Open \(start.verifyURL.absoluteString) and approve the code.")
        }
        let account = try await wrap { try await start.wait() }
        let text = account.isPro
            ? "Signed in as \(account.email) (Pro). New shares go to Reelbird Cloud."
            : "Signed in as \(account.email). Hosted links need Reelbird Pro ($5/month): \(account.server)/upgrade"
        return Report(json: ["signedIn": true, "email": .string(account.email), "plan": .string(account.plan), "server": .string(account.server)],
                      text: text)
    }

    static func status() async throws -> Report {
        _ = try signedIn()
        guard let (account, me) = try await wrap({ try await CloudSettings.refresh() }) else { throw CLIError("Not signed in.") }
        let links = "\(me.usage.activeLinks)"
        let target = ShareSettings.fromEnvironment() != nil ? "REELBIRD_S3_* variables"
            : account.enabled && account.isPro ? "Reelbird Cloud"
            : ShareSettings.ownBucket() != nil ? "your own bucket" : "nowhere yet (Pro or `config share`)"
        return Report(json: [
            "email": .string(me.email), "plan": .string(me.plan), "server": .string(account.server), "enabled": .bool(account.enabled),
            "links": .int(me.usage.activeLinks), "linkLimit": me.limits.activeLinks.map { .int($0) } ?? .null,
            "storageBytes": .int(Int(me.usage.storageBytes)), "storageLimitBytes": .int(Int(me.limits.storageBytes)),
            "accountURL": .string(me.accountURL),
        ], text: """
        Reelbird Cloud
          Account   \(me.email) (\(me.plan == "pro" ? "Pro" : "no plan"))
          Links     \(links)
          Storage   \(Format.bytes(me.usage.storageBytes))\(me.plan == "pro" ? " of \(Format.bytes(me.limits.storageBytes))" : "")
          Shares to \(target)
          \(me.plan == "pro" ? "Manage    \(me.accountURL)" : "Upgrade   \(me.upgradeURL ?? me.accountURL)  ($5/month)")
        """)
    }

    static func use(_ target: String?) throws -> Report {
        switch target {
        case "cloud":
            let (_, account) = try signedIn()
            try CloudSettings.setEnabled(true)
            return Report(json: ["target": "cloud", "pro": .bool(account.isPro)],
                          text: account.isPro ? "New shares go to Reelbird Cloud." : "Reelbird Cloud is on; it hosts links once the account has Pro ($5/month): \(account.server)/upgrade")
        case "bucket":
            guard ShareSettings.ownBucket() != nil else {
                throw CLIError("No bucket is set up.", code: .unavailable, hint: "Run `reelbird config share …` first.")
            }
            try? CloudSettings.setEnabled(false)
            return Report(json: ["target": "bucket"], text: "New shares go to your own bucket.")
        default:
            throw CLIError.usage("Use `cloud use cloud` or `cloud use bucket`.")
        }
    }

    static func links() async throws -> Report {
        let (api, _) = try signedIn()
        let all = try await wrap { try await api.links() }
        let text = all.isEmpty ? "No hosted links yet." : all.map {
            "\(String($0.views).leftPad(5)) views  \($0.title ?? "Untitled recording")\n             \($0.url)"
        }.joined(separator: "\n")
        return Report(json: .array(all.map { ["id": .string($0.id), "title": $0.title.map { .string($0) } ?? .null, "url": .string($0.url),
                                              "views": .int($0.views), "bytes": .int(Int($0.bytes)), "createdAt": .string(Format.iso($0.createdAt))] }),
                      text: text)
    }

    static func stats(_ arg: String?, library: String?) async throws -> Report {
        guard let arg else { throw CLIError.usage("Name a project or a share ID: `cloud stats PROJECT`.") }
        let (api, _) = try signedIn()
        let id: String
        if arg.count == 14, arg.allSatisfy({ $0.isLetter || $0.isNumber }) {
            id = arg
        } else {
            let bundle = try ProjectLocator(libraryPath: library).resolve(arg)
            guard let share = try bundle.readManifest().share else { throw CLIError("\(arg) isn't shared.") }
            guard let last = share.key.split(separator: "/").last else { throw CLIError("\(arg) has no share ID.") }
            id = String(last)
        }
        let s = try await wrap { try await api.stats(id) }
        var lines = ["\(s.title ?? "Untitled recording")", "  Views            \(s.views)"]
        if s.locked {
            lines.append("  Pro shows unique viewers, retention and sources: \(s.statsURL)")
        } else {
            lines.append("  Unique viewers   \(s.uniqueViewers)")
            if let p = s.averagePercent { lines.append("  Average watched  \(Format.seconds(p))%") }
            if let c = s.completionRate { lines.append("  Watched to end   \(Format.seconds(c))%") }
            if !s.retention.isEmpty { lines.append("  Retention        \(sparkline(s.retention))") }
            if !s.referrers.isEmpty { lines.append("  From             " + s.referrers.prefix(4).map { "\($0.name) \($0.views)" }.joined(separator: ", ")) }
            lines.append("  Details          \(s.statsURL)")
        }
        return Report(json: [
            "id": .string(s.id), "views": .int(s.views), "uniqueViewers": .int(s.uniqueViewers), "locked": .bool(s.locked),
            "averagePercent": s.averagePercent.map { .double($0) } ?? .null, "completionRate": s.completionRate.map { .double($0) } ?? .null,
            "retention": .array(s.retention.map { .double($0) }), "chunkSeconds": .double(s.chunkSeconds),
            "referrers": .array(s.referrers.map { ["name": .string($0.name), "views": .int($0.views)] }),
            "statsURL": .string(s.statsURL),
        ], text: lines.joined(separator: "\n"))
    }

    /// Up to 40 block characters, resampled from the retention curve.
    static func sparkline(_ v: [Double]) -> String {
        let blocks = Array("▁▂▃▄▅▆▇█")
        let n = min(40, v.count)
        return String((0..<n).map { i -> Character in
            let x = v[min(v.count - 1, i * v.count / n)]
            return blocks[max(0, min(blocks.count - 1, Int((x * Double(blocks.count - 1)).rounded())))]
        })
    }
}

private extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
