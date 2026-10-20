import Foundation
import Testing
@testable import ReelbirdShare

@Suite(.serialized) struct KeychainTests {
    /// An item made by another program (here /usr/bin/security, as an older or self-built copy of
    /// Reelbird would) can't be deleted by this one. Clearing and saving must work regardless.
    @Test func aForeignItemDoesntBlockSaving() throws {
        let service = "app.reelbird.test.\(UUID().uuidString)"
        let add = Process()
        add.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        add.arguments = ["add-generic-password", "-s", service, "-a", "http://localhost:8788", "-w", "stale"]
        try add.run(); add.waitUntilExit()
        defer {
            let rm = Process()
            rm.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            rm.arguments = ["delete-generic-password", "-s", service, "-a", "http://localhost:8788"]
            try? rm.run(); rm.waitUntilExit()
        }
        try Keychain.set("mine", service: service, account: "https://other.example")
        try Keychain.deleteAll(service: service)   // must not throw on the foreign item
        #expect(Keychain.get(service: service, account: "https://other.example") == nil)
        try Keychain.set("new", service: service, account: "https://watch.reelbird.app")
        #expect(Keychain.get(service: service, account: "https://watch.reelbird.app") == "new")
        try Keychain.deleteAll(service: service)
        #expect(Keychain.get(service: service, account: "https://watch.reelbird.app") == nil)
    }
}
