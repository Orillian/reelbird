import AppKit
import ReelbirdCore
import SwiftUI

/// Snapshot scenes for the post-stop card (each sharing setup, saving, a render running, a failure) and
/// the control bar's marker flash.
@MainActor enum QuickShareScenes {
    typealias Scene = SnapshotRunner.Scene

    static func scenes(services: Services, prefs: Preferences, status: RecorderStatus) -> [Scene] {
        var out: [Scene] = []
        let thumb = MockArt.image(width: 560, height: 350, variant: .docs)
        func card(_ name: String, shareURL: String?, configured: Bool, thumbnail: Bool = true,
                  _ configure: @escaping (inout QuickShareState) -> Void = { $0.takeFinished(ok: true) }) -> Scene {
            Scene(name: "quickshare-\(name)", size: CGSize(width: 440, height: 380), backdrop: true) {
                var state = QuickShareState(shareURL: shareURL, shareConfigured: configured)
                configure(&state)
                let m = QuickShareModel.preview(state: state, title: "Checkout flow walkthrough", duration: 46.5,
                                                thumbnail: thumbnail ? thumb : nil, services: services)
                return AnyView(QuickShareCardView(model: m).padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading))
            }
        }
        let link = "https://pub-3f9a.r2.dev/r/7Hk2pQx9aB/"
        out.append(card("link", shareURL: link, configured: true))
        out.append(card("saving", shareURL: link, configured: true, thumbnail: false) { _ in })
        out.append(card("rendering", shareURL: link, configured: true) { s in
            s.takeFinished(ok: true)
            _ = s.requestCopyVideo()
            s.renderProgress(0.42)
        })
        out.append(card("copied", shareURL: link, configured: true) { s in
            s.takeFinished(ok: true)
            _ = s.requestCopyVideo()
            _ = s.renderFinished(URL(fileURLWithPath: "/tmp/Checkout flow walkthrough.mp4"))
            s.videoCopied()
            s.saved(URL(fileURLWithPath: "/tmp/Checkout flow walkthrough.mp4"))
        })
        out.append(card("share", shareURL: nil, configured: true))
        out.append(card("setup", shareURL: nil, configured: false))
        out.append(card("failed", shareURL: nil, configured: true) { s in
            s.takeFinished(ok: true)
            _ = s.requestSave()
            s.renderFailed("Couldn't make the video: the disk is full.")
        })

        out.append(Scene(name: "controlbar-marker", size: CGSize(width: 620, height: 170), backdrop: true) {
            AnyView(ControlBarView(controller: nil, prefs: prefs, status: status, phase: .recording,
                                   marker: RecordingController.MarkerFlash(number: 3, title: "Marker 3", elapsed: status.elapsed)))
        })
        return out
    }
}
