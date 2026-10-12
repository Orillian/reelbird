import Foundation
import ReelbirdCore

/// Uploads the quick-share stream while recording so the link plays the moment recording stops.
///
/// `begin` mints an unguessable ID and uploads the viewer page and `meta.json` (status
/// "recording") before the first frame. Segments upload in parallel as they arrive (order
/// tolerant, retried until they land); after each one the EVENT playlist is rewritten to list
/// only the contiguous run of uploaded segments. `finish` appends `EXT-X-ENDLIST` and marks the
/// share ready. A small journal in `~/Library/Application Support/Reelbird/uploads/<id>.json`
/// lets `resumeIfNeeded(bundle:)` finish an interrupted upload after relaunch, from the
/// segments the recorder kept in the bundle's `share/` folder.
public final class LiveShareUploader: ShareSegmentSink {
    public let destination: ShareDestination
    let state: UploadState

    /// - Parameters:
    ///   - journalDirectory: where resume journals live (default Application Support/Reelbird/uploads).
    ///   - session: custom URLSession (tests).
    public init(destination: ShareDestination, secret: String, journalDirectory: URL? = nil, session: URLSession? = nil) {
        let d = ShareSettings.normalized(destination)
        self.destination = d
        let dir = journalDirectory ?? ShareSettings.supportDirectory.appendingPathComponent("uploads", isDirectory: true)
        state = UploadState(client: S3Client(destination: d, secret: secret, session: session), destination: d, journalDirectory: dir)
    }

    public func begin(recordingID: String, title: String) async throws -> ShareInfo {
        try await state.begin(recordingID: recordingID, title: title)
    }

    public func initSegment(_ data: Data) async { await state.initSegment(data) }

    public func mediaSegment(index: Int, data: Data, duration: Double) async {
        await state.mediaSegment(index: index, data: data, duration: duration)
    }

    public func finish(totalDuration: Double, timeout: Double) async {
        await state.finish(totalDuration: totalDuration, timeout: timeout)
    }

    public func cancel() async { await state.cancel() }

    public var backlog: Int { get async { await state.backlog } }

    /// The share this uploader is writing, once `begin` has run.
    public var shareInfo: ShareInfo? { get async { await state.info } }

    /// The most recent upload error (cleared on the next success), for the HUD.
    public var lastError: String? { get async { await state.lastError } }

    /// Finishes an upload interrupted by a crash or quit: uploads whatever segments in the
    /// bundle's `share/` folder are missing, then writes the final playlist and marks the share
    /// ready. Returns the share if there was work to do, `nil` otherwise. Waits until done.
    @discardableResult
    public func resumeIfNeeded(bundle: ProjectBundle) async throws -> ShareInfo? {
        try await state.resume(bundle: bundle)
    }
}

/// Persistent progress of one live upload.
struct UploadJournal: Codable, Hashable, Sendable {
    var id: String
    var recordingID: String
    var title: String
    var createdAt: Date
    var bucket: String
    var initUploaded = false
    var durations: [Int: Double] = [:]
    var uploaded: [Int] = []
    var finished = false
    var totalDuration: Double?
}

actor UploadState {
    let client: S3Client
    let destination: ShareDestination
    let journalDirectory: URL

    private(set) var layout: ShareLayout?
    private var meta: ViewerMeta?
    private var journal: UploadJournal?
    private var recordingID = ""

    private var initData: Data?
    private var initUploaded = false
    private var initTask: Task<Void, Never>?
    private var durations: [Int: Double] = [:]
    private var uploaded: Set<Int> = []
    private var tasks: [Int: Task<Void, Never>] = [:]

    private var publishedCount = 0
    private var playlistTask: Task<Void, Never>?
    private var playlistDirty = false
    private var hlsAnnounced = false
    private var pagesUploaded = false
    private var placeholderTask: Task<Void, Never>?

    private var finished = false
    private var totalDuration: Double?
    private var finalizeTask: Task<Void, Never>?
    private var completed = false
    private var cancelled = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private(set) var lastError: String?

    init(client: S3Client, destination: ShareDestination, journalDirectory: URL) {
        self.client = client
        self.destination = destination
        self.journalDirectory = journalDirectory
    }

    var info: ShareInfo? {
        guard let layout else { return nil }
        return ShareInfo(key: layout.key, url: layout.pageURL, polished: false, updatedAt: meta?.updatedAt ?? Date())
    }

    var backlog: Int { tasks.count + (initData != nil && !initUploaded ? 1 : 0) }

    // MARK: Begin

    func begin(recordingID: String, title: String) async throws -> ShareInfo {
        guard layout == nil else {
            throw ShareError(status: 0, code: "AlreadyStarted", message: "This share upload has already started.")
        }
        let id = ShortID.make(length: 14)
        let l = ShareLayout(id: id, destination: destination)
        layout = l
        self.recordingID = recordingID
        let now = Date()
        let m = ViewerMeta(id: id, title: title.isEmpty ? "Untitled recording" : title, status: .recording,
                           createdAt: now, updatedAt: now, pageURL: l.pageURL, baseURL: l.baseURL, card: "card.jpg")
        meta = m
        journal = UploadJournal(id: id, recordingID: recordingID, title: m.title, createdAt: now, bucket: destination.bucket)
        saveJournal()

        do {
            try await uploadPlaceholder(m, layout: l)
            pagesUploaded = true
        } catch let e as ShareError where !e.isTransient {
            discardJournal()
            layout = nil
            throw e
        } catch {
            // Offline or flaky: keep the link and keep trying in the background; segments queue up.
            lastError = (error as? ShareError)?.message ?? error.localizedDescription
            placeholderTask = Task { await self.retryPlaceholder() }
        }
        return ShareInfo(key: l.key, url: l.pageURL, polished: false, updatedAt: now)
    }

    private func uploadPlaceholder(_ m: ViewerMeta, layout l: ShareLayout) async throws {
        let client = self.client
        let html = Data(ViewerPage.html(m).utf8)
        let card = TitleCard.jpeg(title: m.title)
        try await withThrowingTaskGroup(of: Void.self) { g in
            g.addTask { try await client.put(l.metaKey, data: m.jsonData, contentType: "application/json", cacheControl: ShareLayout.noStore) }
            for k in l.pageKeys {
                g.addTask { try await client.put(k, data: html, contentType: "text/html; charset=utf-8", cacheControl: ShareLayout.revalidate) }
            }
            if let card {
                g.addTask { try await client.put(l.cardKey, data: card, contentType: "image/jpeg", cacheControl: ShareLayout.revalidate) }
            }
            try await g.waitForAll()
        }
    }

    private func retryPlaceholder() async {
        var delay = 2.0
        while !cancelled && !pagesUploaded && !completed {
            guard let m = meta, let l = layout else { return }
            do {
                try await uploadPlaceholder(m, layout: l)
                pagesUploaded = true
                lastError = nil
                return
            } catch {
                lastError = (error as? ShareError)?.message ?? error.localizedDescription
                try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
                delay = min(delay * 2, 30)
            }
        }
    }

    // MARK: Segments

    func initSegment(_ data: Data) {
        guard !cancelled, layout != nil, initTask == nil else { return }
        initData = data
        startInitUpload(data)
    }

    private func startInitUpload(_ data: Data) {
        guard let l = layout else { return }
        let client = self.client
        initTask = Task {
            await Self.putUntilDone(client: client, key: l.initKey, data: data, contentType: "video/mp4",
                                    cacheControl: ShareLayout.immutable, isCancelled: { await self.isCancelled },
                                    onError: { await self.noteError($0) })
            self.initDidUpload()
        }
    }

    private func initDidUpload() {
        guard !cancelled else { return }
        initUploaded = true
        initData = nil
        journal?.initUploaded = true
        saveJournal()
        schedulePlaylist()
    }

    func mediaSegment(index: Int, data: Data, duration: Double) {
        guard !cancelled, layout != nil, !finished || finalizeTask == nil else { return }
        durations[index] = duration
        journal?.durations[index] = duration
        saveJournal()
        startSegmentUpload(index: index, data: data)
    }

    private func startSegmentUpload(index: Int, data: Data) {
        guard let l = layout, tasks[index] == nil, !uploaded.contains(index) else { return }
        let client = self.client
        tasks[index] = Task {
            await Self.putUntilDone(client: client, key: l.segmentKey(index), data: data, contentType: "video/iso.segment",
                                    cacheControl: ShareLayout.immutable, isCancelled: { await self.isCancelled },
                                    onError: { await self.noteError($0) })
            self.segmentDidUpload(index)
        }
    }

    private func segmentDidUpload(_ index: Int) {
        tasks[index] = nil
        guard !cancelled else { return }
        uploaded.insert(index)
        journal?.uploaded = uploaded.sorted()
        saveJournal()
        lastError = nil
        schedulePlaylist()
    }

    var isCancelled: Bool { cancelled }
    private func noteError(_ e: any Error) { lastError = (e as? ShareError)?.message ?? e.localizedDescription }

    /// PUTs with the client's own retries, then keeps retrying with a longer backoff until it
    /// lands or the upload is cancelled. Segments are idempotent, so retrying is always safe.
    static func putUntilDone(client: S3Client, key: String, data: Data, contentType: String, cacheControl: String,
                             isCancelled: @Sendable () async -> Bool, onError: @Sendable (any Error) async -> Void) async {
        var delay = 2.0
        while !(await isCancelled()) && !Task.isCancelled {
            do {
                try await client.put(key, data: data, contentType: contentType, cacheControl: cacheControl)
                return
            } catch is CancellationError {
                return
            } catch {
                await onError(error)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
                delay = min(delay * 2, 30)
            }
        }
    }

    /// Number of segments 1...n that are all uploaded.
    private var contiguousCount: Int {
        var n = 0
        while uploaded.contains(n + 1) { n += 1 }
        return n
    }

    private func schedulePlaylist() {
        guard initUploaded, !cancelled, !completed else { return }
        if playlistTask != nil { playlistDirty = true; return }
        guard contiguousCount > publishedCount else { return }
        playlistTask = Task { await self.runPlaylist() }
    }

    private func runPlaylist() async {
        repeat {
            playlistDirty = false
            let count = contiguousCount
            guard count > publishedCount, let l = layout, !cancelled else { break }
            let text = playlistText(count: count, ended: false)
            do {
                try await client.put(l.playlistKey, data: Data(text.utf8), contentType: "application/vnd.apple.mpegurl",
                                     cacheControl: ShareLayout.noStore)
                publishedCount = max(publishedCount, count)
                if !hlsAnnounced, var m = meta {
                    hlsAnnounced = true
                    m.hls = "hls/index.m3u8"
                    m.updatedAt = Date()
                    meta = m
                    try? await client.put(l.metaKey, data: m.jsonData, contentType: "application/json", cacheControl: ShareLayout.noStore)
                }
            } catch {
                noteError(error)
                if finished { break }   // finalize writes the playlist itself
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                playlistDirty = true
            }
        } while playlistDirty
        playlistTask = nil
    }

    private func playlistText(count: Int, ended: Bool) -> String {
        guard let l = layout else { return "" }
        let ds = (0..<count).map { durations[$0 + 1] ?? 2 }
        return HLSPlaylist.event(durations: ds, ended: ended, segmentName: l.segmentName)
    }

    // MARK: Finish

    func finish(totalDuration: Double, timeout: Double) async {
        guard !cancelled, layout != nil else { return }
        finished = true
        self.totalDuration = totalDuration
        journal?.finished = true
        journal?.totalDuration = totalDuration
        saveJournal()
        if finalizeTask == nil { finalizeTask = Task { await self.finalize() } }
        await waitForCompletion(timeout: timeout)
    }

    private func finalize() async {
        guard let l = layout else { return }
        if backlog > 0, var m = meta {
            m.status = .processing
            m.updatedAt = Date()
            meta = m
            try? await client.put(l.metaKey, data: m.jsonData, contentType: "application/json", cacheControl: ShareLayout.noStore)
        }
        if let t = initTask { await t.value }
        while let (_, t) = tasks.first { await t.value }
        if let t = playlistTask { await t.value }
        if let t = placeholderTask { t.cancel() }
        guard !cancelled else { return }

        let count = contiguousCount
        let hasMedia = initUploaded && count > 0
        if hasMedia {
            let text = playlistText(count: count, ended: true)
            await Self.putUntilDone(client: client, key: l.playlistKey, data: Data(text.utf8),
                                    contentType: "application/vnd.apple.mpegurl", cacheControl: ShareLayout.noStore,
                                    isCancelled: { await self.isCancelled }, onError: { await self.noteError($0) })
            publishedCount = count
        }
        guard !cancelled, var m = meta else { return }
        m.status = .ready
        m.hls = hasMedia ? "hls/index.m3u8" : nil
        let summed = (1...max(1, count)).reduce(0.0) { $0 + (durations[$1] ?? 0) }
        m.duration = hasMedia ? summed : (totalDuration ?? 0)
        m.updatedAt = Date()
        meta = m
        let html = Data(ViewerPage.html(m).utf8)
        await Self.putUntilDone(client: client, key: l.metaKey, data: m.jsonData, contentType: "application/json",
                                cacheControl: ShareLayout.noStore, isCancelled: { await self.isCancelled },
                                onError: { await self.noteError($0) })
        for k in l.pageKeys {
            await Self.putUntilDone(client: client, key: k, data: html, contentType: "text/html; charset=utf-8",
                                    cacheControl: ShareLayout.revalidate, isCancelled: { await self.isCancelled },
                                    onError: { await self.noteError($0) })
        }
        if !pagesUploaded, let card = TitleCard.jpeg(title: m.title) {
            try? await client.put(l.cardKey, data: card, contentType: "image/jpeg", cacheControl: ShareLayout.revalidate)
        }
        completed = true
        lastError = nil
        discardJournal()
        resumeWaiters()
    }

    private func waitForCompletion(timeout: Double) async {
        guard !completed && !cancelled else { return }
        let id = UUID()
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1e9))
            self.timeOut(id)
        }
        await withCheckedContinuation { c in
            if completed || cancelled { c.resume() } else { waiters[id] = c }
        }
        timer.cancel()
    }

    private func timeOut(_ id: UUID) { waiters.removeValue(forKey: id)?.resume() }

    private func resumeWaiters() {
        let w = waiters
        waiters = [:]
        w.values.forEach { $0.resume() }
    }

    // MARK: Cancel

    func cancel() async {
        guard !cancelled else { return }
        cancelled = true
        initTask?.cancel()
        tasks.values.forEach { $0.cancel() }
        playlistTask?.cancel()
        placeholderTask?.cancel()
        finalizeTask?.cancel()
        tasks = [:]
        resumeWaiters()
        discardJournal()
        guard let l = layout else { return }
        _ = try? await client.deletePrefix(l.folder)
        try? await client.delete(l.key)
    }

    // MARK: Journal + resume

    private var journalURL: URL? { layout.map { journalDirectory.appendingPathComponent("\($0.id).json") } }

    private func saveJournal() {
        guard let journal, let url = journalURL else { return }
        do {
            try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
            try JSONCoding.writeAtomically(journal, to: url)
        } catch {
            lastError = "Couldn't save the upload journal: \(error.localizedDescription)"
        }
    }

    private func discardJournal() {
        if let url = journalURL { try? FileManager.default.removeItem(at: url) }
        journal = nil
    }

    func resume(bundle: ProjectBundle) async throws -> ShareInfo? {
        let manifest = try bundle.readManifest()
        guard layout == nil, let share = manifest.share,
              let l = ShareLayout(info: share, destination: destination) else { return nil }
        let url = journalDirectory.appendingPathComponent("\(l.id).json")
        guard let data = try? Data(contentsOf: url),
              let j = try? JSONCoding.decoder.decode(UploadJournal.self, from: data) else { return nil }
        guard j.bucket == destination.bucket else { return nil }

        layout = l
        journal = j
        recordingID = j.recordingID
        durations = j.durations
        uploaded = Set(j.uploaded)
        initUploaded = j.initUploaded
        hlsAnnounced = !j.uploaded.isEmpty
        pagesUploaded = true

        // Start from the live meta.json if it is there (keeps createdAt, title edits); else rebuild.
        if let d = try? await client.get(l.metaKey), let m = try? JSONCoding.decoder.decode(ViewerMeta.self, from: d) {
            meta = m
        } else {
            meta = ViewerMeta(id: l.id, title: j.title, status: .processing, createdAt: j.createdAt, updatedAt: Date(),
                              pageURL: l.pageURL, baseURL: l.baseURL, card: "card.jpg")
            pagesUploaded = false
        }

        let dir = bundle.directory(for: .share)
        let fm = FileManager.default
        if let text = try? String(contentsOf: dir.appendingPathComponent("index.m3u8"), encoding: .utf8) {
            for (n, d) in HLSPlaylist.durations(fromPlaylist: text) where durations[n] == nil { durations[n] = d }
        }
        let fallback = manifest.track(.share)?.segmentDuration ?? 2
        let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        if !initUploaded, let d = try? Data(contentsOf: dir.appendingPathComponent("init.mp4")) {
            initData = d
            startInitUpload(d)
        }
        for name in files.sorted() {
            guard let n = HLSPlaylist.segmentNumber(name), !uploaded.contains(n) else { continue }
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(name), options: .mappedIfSafe) else { continue }
            if durations[n] == nil { durations[n] = fallback }
            startSegmentUpload(index: n, data: d)
        }
        journal?.durations = durations
        saveJournal()

        // A relaunch means the recording is over, whatever the journal says.
        finished = true
        totalDuration = j.totalDuration ?? manifest.duration
        finalizeTask = Task { await self.finalize() }
        await finalizeTask?.value
        return info
    }
}
