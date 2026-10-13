import AppKit
import ReelbirdCore

extension AppModel {
    /// Asks, then moves a recording to the Trash: closes its editor first and, if it was shared,
    /// can delete the share link too. Restorable from the Trash in Finder.
    func moveToTrash(_ bundle: ProjectBundle) {
        let manifest = try? bundle.readManifest()
        let editTitle = (try? bundle.readEdit())?.title
        let title = (editTitle?.isEmpty == false ? editTitle : nil) ?? manifest?.title
            ?? bundle.url.deletingPathExtension().lastPathComponent

        let alert = NSAlert()
        alert.messageText = "Move “\(title)” to the Trash?"
        alert.informativeText = "You can put it back from the Trash in Finder."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        var unshare: NSButton?
        if manifest?.share != nil, services.share.loadDestination() != nil {
            let box = NSButton(checkboxWithTitle: "Also delete its share link", target: nil, action: nil)
            box.state = .on
            alert.accessoryView = box
            unshare = box
        }
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        windows.closeEditor(for: bundle)
        do {
            try FileManager.default.trashItem(at: bundle.url, resultingItemURL: nil)
        } catch {
            present(error, title: "Couldn't move the recording to the Trash")
            return
        }
        library.reload()
        if unshare?.state == .on, let info = manifest?.share,
           let dest = services.share.loadDestination(), let secret = services.share.secret() {
            let share = services.share
            Task {
                do { try await share.unpublish(info, destination: dest, secret: secret) } catch {
                    self.present(error, title: "The recording is in the Trash, but its link couldn't be deleted")
                }
            }
        }
    }
}
