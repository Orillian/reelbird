import AVFoundation
import CoreGraphics
import Foundation
import ReelbirdCore

/// Publishing the polished render, unpublishing, and checking a destination.
public enum ShareService {
    /// Uploads, HEADs and deletes a tiny object, then fetches it through the public URL.
    /// Throws a `ShareError` whose message says what to fix.
    public static func testConnection(_ d: ShareDestination, secret: String) async throws {
        try await testConnection(d, secret: secret, session: nil)
    }

    static func testConnection(_ d: ShareDestination, secret: String, session: URLSession?) async throws {
        if let server = d.cloudServer {
            _ = try await CloudAPI(server: server, token: secret).me()
            return
        }
        let d = ShareSettings.normalized(d)
        try ShareSettings.validate(d, secret: secret)
        let client = S3Client(destination: d, secret: secret, session: session, maxAttempts: 2)
        let key = "\(d.prefix)/.reelbird-check-\(ShortID.make(length: 12)).txt"
        let body = Data("Reelbird connection check \(Date())".utf8)
        try await client.put(key, data: body, contentType: "text/plain; charset=utf-8", cacheControl: ShareLayout.noStore)
        do {
            guard let head = try await client.head(key), head.size == Int64(body.count) else {
                throw ShareError(status: 0, code: "CheckFailed", message: "Uploaded a test file but couldn't read it back.", key: key)
            }
            // The public URL must serve the bucket, or nobody can open the links.
            if let url = URL(string: "\(ShareLayout(id: "x", destination: d).publicBase)/\(key)") {
                var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                req.httpMethod = "GET"
                let (data, resp) = try await (session ?? client.session).data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, data == body else {
                    throw ShareError(status: status, code: "PublicURL",
                                     message: "Uploads work, but \(d.publicBaseURL) doesn't serve the bucket (HTTP \(status)). Turn on public access for the bucket and check the public URL.")
                }
            }
        } catch {
            try? await client.delete(key)
            throw error
        }
        try await client.delete(key)
    }

    /// Publishes the polished render, creating the share or updating it in place (same link)
    /// when `bundle`'s manifest already has one. Store the returned `ShareInfo` in the manifest.
    ///
    /// - Parameters:
    ///   - video: the exported MP4 (H.264 recommended for playback everywhere). `nil` updates
    ///     only the title, chapters, poster or captions of an existing share.
    ///   - captions: WebVTT on the output timeline.
    public static func publish(bundle: ProjectBundle, video: URL?, poster: CGImage?, captions: URL?,
                               destination: ShareDestination, secret: String,
                               progress: @escaping @Sendable (Double) -> Void) async throws -> ShareInfo {
        try await publish(bundle: bundle, video: video, poster: poster, captions: captions, destination: destination,
                          secret: secret, session: nil, progress: progress)
    }

    static func publish(bundle: ProjectBundle, video: URL?, poster: CGImage?, captions: URL?,
                        destination: ShareDestination, secret: String, session: URLSession?,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> ShareInfo {
        let d = ShareSettings.normalized(destination)
        let client = S3Client(destination: d, secret: secret, session: session)
        let manifest = try bundle.readManifest()
        let edit = (try? bundle.readEdit()) ?? EditDocument.initial(for: manifest)

        let layout = manifest.share.flatMap { ShareLayout(info: $0, destination: d) }
            ?? ShareLayout(id: ShortID.make(length: 14), destination: d)
        var previous: ViewerMeta?
        if manifest.share != nil {
            // Only a missing meta.json means "start over at revision 1". Any other failure (offline,
            // 403) stops here: carrying on would overwrite the immutable video.1.mp4 that caches keep.
            do {
                let data = try await client.get(layout.metaKey)
                previous = try? JSONCoding.decoder.decode(ViewerMeta.self, from: data)
            } catch let e as ShareError where e.status == 404 {
            }
        }

        let now = Date()
        let rev = (previous?.revision ?? 0) + 1
        let title = (edit.title?.isEmpty == false ? edit.title : nil) ?? manifest.title
        var meta = previous ?? ViewerMeta(id: layout.id, title: title, status: .ready, createdAt: manifest.createdAt,
                                          pageURL: layout.pageURL, baseURL: layout.baseURL)
        meta.title = title.isEmpty ? "Untitled recording" : title
        meta.pageURL = layout.pageURL
        meta.baseURL = layout.baseURL
        meta.updatedAt = now
        meta.revision = rev
        meta.status = .ready
        let timeline = EditTimeline(manifest: manifest, edit: edit)
        meta.chapters = edit.chapters.compactMap { c in
            timeline.outputTime(forSource: c.time).map { Chapter(time: $0, title: c.title) }
        }.sorted { $0.time < $1.time }

        var uploads: [String] = []   // new asset names, to protect from cleanup
        progress(0)

        if let video {
            let name = "video.\(rev).mp4"
            let info = await videoInfo(video)
            try await client.uploadFile(layout.key(name), file: video, contentType: "video/mp4",
                                        cacheControl: ShareLayout.immutable) { progress($0 * 0.9) }
            meta.video = name
            meta.videoBytes = (try? FileManager.default.attributesOfItem(atPath: video.path)[.size] as? NSNumber)?.int64Value
            meta.duration = info.duration ?? (timeline.duration > 0 ? timeline.duration : meta.duration)
            meta.width = info.width
            meta.height = info.height
            uploads.append(name)
        } else if meta.duration == nil, timeline.duration > 0 {
            meta.duration = timeline.duration
        }
        progress(0.9)

        var poster = poster
        if poster == nil, let video { poster = await posterFrame(video) }
        if let poster, let jpeg = TitleCard.jpeg(downscaled(poster, maxWidth: 1600), quality: 0.84) {
            let name = "poster.\(rev).jpg"
            try await client.put(layout.key(name), data: jpeg, contentType: "image/jpeg", cacheControl: ShareLayout.immutable)
            meta.poster = name
            uploads.append(name)
        }
        if let captions {
            let data = try Data(contentsOf: captions)
            let name = "captions.\(rev).vtt"
            try await client.put(layout.key(name), data: data, contentType: "text/vtt; charset=utf-8", cacheControl: ShareLayout.immutable)
            meta.captions = name
            meta.captionsLanguage = meta.captionsLanguage ?? Locale.current.language.languageCode?.identifier ?? "en"
            uploads.append(name)
        }
        if meta.card == nil || previous?.title != meta.title, let card = TitleCard.jpeg(title: meta.title) {
            try await client.put(layout.cardKey, data: card, contentType: "image/jpeg", cacheControl: ShareLayout.revalidate)
            meta.card = "card.jpg"
        }
        progress(0.95)

        try await client.put(layout.metaKey, data: meta.jsonData, contentType: "application/json", cacheControl: ShareLayout.noStore)
        let html = Data(ViewerPage.html(meta).utf8)
        try await withThrowingTaskGroup(of: Void.self) { g in
            for k in layout.pageKeys {
                g.addTask { try await client.put(k, data: html, contentType: "text/html; charset=utf-8", cacheControl: ShareLayout.revalidate) }
            }
            try await g.waitForAll()
        }

        // Remove assets from earlier revisions that nothing references any more.
        if let previous {
            let keep = Set([meta.video, meta.poster, meta.captions].compactMap { $0 })
            let stale = [previous.video, previous.poster, previous.captions].compactMap { $0 }.filter { !keep.contains($0) }
            for name in stale { try? await client.delete(layout.key(name)) }
        }
        progress(1)
        return ShareInfo(key: layout.key, url: layout.pageURL, polished: meta.video != nil, updatedAt: now)
    }

    /// Deletes everything under the share's prefix. The link stops working.
    public static func unpublish(_ info: ShareInfo, destination: ShareDestination, secret: String) async throws {
        try await unpublish(info, destination: destination, secret: secret, session: nil)
    }

    static func unpublish(_ info: ShareInfo, destination: ShareDestination, secret: String, session: URLSession?) async throws {
        let d = ShareSettings.normalized(destination)
        guard let layout = ShareLayout(info: info, destination: d), !layout.id.isEmpty else {
            throw ShareError(status: 0, code: "InvalidShare", message: "This share has no key to delete.")
        }
        if let server = d.cloudServer {
            // The server deletes the files and frees the link from the plan's count.
            do { try await CloudAPI(server: server, token: secret).delete(layout.id) } catch let e as ShareError where e.status == 404 {}
            return
        }
        let client = S3Client(destination: d, secret: secret, session: session)
        try await client.deletePrefix(layout.folder)
        try await client.delete(layout.key)
    }

    // MARK: Media helpers

    static func videoInfo(_ url: URL) async -> (duration: Double?, width: Int?, height: Int?) {
        let asset = AVURLAsset(url: url)
        let duration = try? await asset.load(.duration)
        var w: Int?, h: Int?
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let r = CGRect(origin: .zero, size: size).applying(transform)
            w = Int(abs(r.width).rounded()); h = Int(abs(r.height).rounded())
        }
        return (duration.map { CMTimeGetSeconds($0) }.flatMap { $0.isFinite ? $0 : nil }, w, h)
    }

    /// A frame about one second in (or the middle of very short videos).
    static func posterFrame(_ url: URL) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1600, height: 1600)
        let t = CMTime(seconds: min(1, max(0, duration / 2)), preferredTimescale: 600)
        return try? await gen.image(at: t).image
    }

    static func downscaled(_ image: CGImage, maxWidth: Int) -> CGImage {
        guard image.width > maxWidth else { return image }
        let w = maxWidth, h = Int(Double(image.height) * Double(maxWidth) / Double(image.width))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}
