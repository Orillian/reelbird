import AppKit
import ReelbirdCore

extension AppModel {
    /// Asks, then moves a recording to the Trash (see `moveToTrash(_:)` for several).
    func moveToTrash(_ bundle: ProjectBundle) { moveToTrash([bundle]) }

    /// Asks once, then moves recordings to the Trash: closes their editors first and, if any were
    /// shared, can delete their share links too. Restorable from the Trash in Finder.
    func moveToTrash(_ bundles: [ProjectBundle]) {
        guard !bundles.isEmpty else { return }
        let manifests = bundles.map { try? $0.readManifest() }
        let shared = manifests.compactMap { $0?.share }

        let alert = NSAlert()
        if bundles.count == 1, let only = bundles.first {
            let editTitle = (try? only.readEdit())?.title
            let title = (editTitle?.isEmpty == false ? editTitle : nil) ?? manifests.first??.title
                ?? only.url.deletingPathExtension().lastPathComponent
            alert.messageText = "Move “\(title)” to the Trash?"
            alert.informativeText = "You can put it back from the Trash in Finder."
        } else {
            alert.messageText = "Move \(bundles.count) recordings to the Trash?"
            alert.informativeText = "You can put them back from the Trash in Finder."
        }
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        var unshare: NSButton?
        if !shared.isEmpty, services.share.loadDestination() != nil {
            let label = bundles.count == 1 ? "Also delete its share link"
                : shared.count == 1 ? "Also delete the share link" : "Also delete their \(shared.count) share links"
            let box = NSButton(checkboxWithTitle: label, target: nil, action: nil)
            box.state = .on
            alert.accessoryView = box
            unshare = box
        }
        alert.present { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performTrash(bundles, manifests: manifests, deleteLinks: unshare?.state == .on)
        }
    }

    private func performTrash(_ bundles: [ProjectBundle], manifests: [ProjectManifest?], deleteLinks: Bool) {
        bundles.forEach { windows.closeEditor(for: $0) }
        // Each shared recording's link and where the bundle went (original place first, then the Trash).
        var trashedShares: [(info: ShareInfo, places: [URL])] = []
        var failure: (any Error)?
        var failed = 0
        var trashed: Set<URL> = []
        for (bundle, manifest) in zip(bundles, manifests) {
            do {
                var inTrash: NSURL?
                try FileManager.default.trashItem(at: bundle.url, resultingItemURL: &inTrash)
                trashed.insert(bundle.url)
                if let info = manifest?.share { trashedShares.append((info, [inTrash as URL?, bundle.url].compactMap { $0 })) }
            } catch {
                failure = failure ?? error
                failed += 1
            }
        }
        library.selectNeighbour(afterRemoving: trashed)
        library.reload()
        if let failure {
            present(failure, title: failed == bundles.count
                ? (failed == 1 ? "Couldn't move the recording to the Trash" : "Couldn't move the recordings to the Trash")
                : "Couldn't move \(failed) of the \(bundles.count) recordings to the Trash")
        }

        guard deleteLinks, !trashedShares.isEmpty,
              let dest = services.share.loadDestination(), let secret = services.share.secret() else { return }
        let share = services.share
        Task {
            var firstError: (any Error)?
            var errors = 0
            for (info, places) in trashedShares {
                do {
                    try await share.unpublish(info, destination: dest, secret: secret)
                    // The link is gone: forget it, so putting the recording back doesn't show a dead link.
                    Self.forgetShare(info, at: places)
                } catch {
                    firstError = firstError ?? error
                    errors += 1
                }
            }
            if let firstError {
                let title = trashedShares.count == 1
                    ? "The recording is in the Trash, but its link couldn't be deleted"
                    : "The recordings are in the Trash, but \(errors) of their links couldn't be deleted"
                self.present(firstError, title: title)
            }
        }
    }
}

extension AppModel {
    /// Clears `info` from the manifest of whichever copy of the bundle still has it (in the Trash, or
    /// already put back). Leaves bundles pointing at another link alone.
    nonisolated static func forgetShare(_ info: ShareInfo, at places: [URL]) {
        for url in places {
            let b = ProjectBundle(url: url)
            guard var m = try? b.readManifest(), m.share?.key == info.key else { continue }
            m.share = nil
            try? b.writeManifest(m)
        }
    }
}

extension NSAlert {
    /// Shows the alert as a sheet on the window the person is using (so it appears on their screen and
    /// Space), or as a standalone alert when no suitable window is in front.
    @MainActor func present(_ completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        if let host = NSApp.keyWindow ?? NSApp.mainWindow, host.isVisible, host.attachedSheet == nil,
           host.styleMask.contains(.titled), !(host is NSPanel) {
            beginSheetModal(for: host) { response in MainActor.assumeIsolated { completion(response) } }
        } else {
            NSApp.activate()
            completion(runModal())
        }
    }
}
