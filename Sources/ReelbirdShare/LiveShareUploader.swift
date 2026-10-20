import Foundation
import ReelbirdCore
import Synchronization

/// Uploads the quick-share stream while recording so the link plays the moment recording stops.
///
/// `begin` mints an unguessable ID and uploads the viewer page and `meta.json` (status
/// "recording") before the first frame. Segments upload in index order, a few at a time, retried
/// until they land; while uploads fall behind (offline, slow uplink) queued segments are spooled
/// to disk so memory stays flat. After each upload the EVENT playlist is rewritten to list
/// only the contiguous run of uploaded segments. `finish` appends `EXT-X-ENDLIST` and marks the
/// share ready. A small journal in `~/Library/Application Support/Reelbird/uploads/<id>.json`
/// lets `resumeIfNeeded(bundle:)` finish an interrupted upload after relaunch, from the
/// segments the recorder kept in the bundle's `share/` folder.
///
/// The live stream is revision 0 of the share. Once a publish (Update Link) is live, it owns the
/// link: this uploader never writes `meta.json` or the page over a higher revision, and deletes its
/// stream instead of finishing it when that revision plays a polished MP4.
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

    /// Tests: inject a client with short retry delays.
    init(destination: ShareDestination, client: S3Client, journalDirectory: URL) {
        self.destination = client.destination
        state = UploadState(client: client, destination: client.destination, journalDirectory: journalDirectory)
    }

    /// Tests: stop every upload without cleaning up, as if the app had crashed.
    func simulateCrash() async { await state.halt() }

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

    public func waitUntilUploaded() async -> Bool { await state.waitUntilDone() }

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

/// Live uploads running in this process, by share key, so a publish can stop the share's upload
/// before it writes (the check against the bucket's meta.json alone leaves a moment between read and write).
enum LiveUploads {
    private static let running = Mutex<[String: UploadState]>([:])

    static func add(_ key: String, _ s: UploadState) { running.withLock { $0[key] = s } }
    static func remove(_ key: String, _ s: UploadState) { running.withLock { if $0[key] === s { $0[key] = nil } } }

    /// Stops the share's live upload, if one is running here, and waits until none of its requests is in flight.
    static func retire(_ key: String) async -> UploadState? {
        guard let s = running.withLock({ $0.removeValue(forKey: key) }) else { return nil }
        await s.retire()
        return s
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
    /// Uploads in flight.
    private var tasks: [Int: Task<Void, Never>] = [:]

    /// Where a queued segment's bytes are.
    enum Payload: Sendable {
        case memory(Data)
        /// `owned`: a spool file this uploader wrote (deleted after upload); otherwise the recorder's copy.
        case file(URL, owned: Bool)
    }
    /// Segments waiting for an upload slot, uploaded lowest index first.
    private var pending: [Int: Payload] = [:]
    /// At most this many segment uploads at once (also bounds retries hammering a flaky link).
    static let maxConcurrentSegments = 4
    /// Queued segments kept in memory before new ones are spooled to disk (~1 MB each).
    static let memoryQueueLimit = 8

    private var publishedCount = 0
    private var playlistTask: Task<Void, Never>?
    private var playlistDirty = false
    private var hlsAnnounced = false
    private var pagesUploaded = false
    private var placeholderTask: Task<Void, Never>?
    private var placeholderAttempt: Task<Void, any Error>?

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
        return ShareInfo(key: layout.key, url: layout.pageURL, polished: false, updatedAt: meta?.updatedAt ?? Date(),
                         revision: meta?.revision ?? 0)
    }

    var backlog: Int { tasks.count + pending.count + (initData != nil && !initUploaded ? 1 : 0) }

    /// Queued segments held in memory (tests).
    var queuedInMemory: Int { pending.values.filter { if case .memory = $0 { true } else { false } }.count }
    var uploadsInFlight: Int { tasks.count }

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
        LiveUploads.add(l.key, self)

        // Wait a few seconds for the placeholder page; a slow or black-holed network must not hold
        // the link (and the segments queued behind it) for minutes of request timeouts.
        let attempt = Task { [client] in try await Self.uploadPlaceholder(m, layout: l, client: client) }
        switch await Self.result(of: attempt, within: beginTimeout) {
        case .success?:
            pagesUploaded = true
        case .failure(let e as ShareError)? where !e.isTransient:
            discardJournal()
            LiveUploads.remove(l.key, self)
            layout = nil
            throw e
        case .failure(let error)?:
            // Offline or flaky: keep the link and keep trying in the background; segments queue up.
            lastError = (error as? ShareError)?.message ?? error.localizedDescription
            placeholderTask = Task { await self.retryPlaceholder() }
        case nil:
            lastError = "Still reserving the link; the network is slow."
            placeholderAttempt = attempt
            placeholderTask = Task { await self.finishSlowPlaceholder(attempt) }
        }
        return ShareInfo(key: l.key, url: l.pageURL, polished: false, updatedAt: now, revision: m.revision)
    }

    /// Seconds `begin` waits for the placeholder page before returning the link anyway.
    var beginTimeout = 5.0
    func setBeginTimeout(_ t: Double) { beginTimeout = t }

    /// The task's result, or `nil` if it isn't done within `timeout` (the task keeps running).
    static func result<T: Sendable>(of task: Task<T, any Error>, within timeout: Double) async -> Result<T, any Error>? {
        let done = Mutex(false)
        return await withCheckedContinuation { (c: CheckedContinuation<Result<T, any Error>?, Never>) in
            let resume: @Sendable (Result<T, any Error>?) -> Void = { r in
                if done.withLock({ d in defer { d = true }; return !d }) { c.resume(returning: r) }
            }
            Task { resume(await task.result) }
            Task { try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1e9)); resume(nil) }
        }
    }

    private func finishSlowPlaceholder(_ attempt: Task<Void, any Error>) async {
        switch await attempt.result {
        case .success:
            pagesUploaded = true
            lastError = nil
        case .failure(let error):
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            lastError = (error as? ShareError)?.message ?? error.localizedDescription
            await retryPlaceholder()
        }
    }

    private func uploadPlaceholder(_ m: ViewerMeta, layout l: ShareLayout) async throws {
        try await Self.uploadPlaceholder(m, layout: l, client: client)
    }

    private static func uploadPlaceholder(_ m: ViewerMeta, layout l: ShareLayout, client: S3Client) async throws {
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
        // Task.isCancelled matters: finalize cancels this loop, and a cancelled sleep returns at once,
        // so without the check the loop would spin on the actor until the share completed.
        while !cancelled && !pagesUploaded && !completed && !Task.isCancelled {
            guard let m = meta, let l = layout else { return }
            if await isSuperseded() { return }
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
        guard layout != nil, tasks[index] == nil, pending[index] == nil, !uploaded.contains(index) else { return }
        pending[index] = queuedInMemory < Self.memoryQueueLimit ? .memory(data) : spool(index: index, data: data)
        pumpSegments()
    }

    private func enqueue(index: Int, payload: Payload) {
        guard tasks[index] == nil, pending[index] == nil, !uploaded.contains(index) else { return }
        pending[index] = payload
        pumpSegments()
    }

    private var spoolDirectory: URL? { layout.map { journalDirectory.appendingPathComponent("\($0.id).spool", isDirectory: true) } }

    /// Writes a queued segment to disk so it doesn't sit in memory; keeps it in memory if that fails.
    private func spool(index: Int, data: Data) -> Payload {
        guard let dir = spoolDirectory else { return .memory(data) }
        let url = dir.appendingPathComponent(String(format: "seg_%05d.m4s", index))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return .file(url, owned: true)
        } catch {
            return .memory(data)
        }
    }

    /// Starts queued uploads, lowest index first, up to the concurrency limit.
    private func pumpSegments() {
        guard !cancelled, let l = layout else { return }
        let client = self.client
        while tasks.count < Self.maxConcurrentSegments, let index = pending.keys.min(), let payload = pending.removeValue(forKey: index) {
            let data: Data
            switch payload {
            case .memory(let d): data = d
            case .file(let url, _):
                guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
                data = d
            }
            tasks[index] = Task {
                await Self.putUntilDone(client: client, key: l.segmentKey(index), data: data, contentType: "video/iso.segment",
                                        cacheControl: ShareLayout.immutable, isCancelled: { await self.isCancelled },
                                        onError: { await self.noteError($0) })
                self.segmentDidUpload(index, payload: payload)
            }
        }
    }

    private func segmentDidUpload(_ index: Int, payload: Payload) {
        tasks[index] = nil
        if case .file(let url, true) = payload { try? FileManager.default.removeItem(at: url) }
        guard !cancelled else { return }
        uploaded.insert(index)
        journal?.uploaded = uploaded.sorted()
        saveJournal()
        lastError = nil
        schedulePlaylist()
        pumpSegments()
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
                    if await !isSuperseded() {
                        try? await client.put(l.metaKey, data: m.jsonData, contentType: "application/json", cacheControl: ShareLayout.noStore)
                    }
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
        if backlog > 0, var m = meta, await !isSuperseded() {
            m.status = .processing
            m.updatedAt = Date()
            meta = m
            try? await client.put(l.metaKey, data: m.jsonData, contentType: "application/json", cacheControl: ShareLayout.noStore)
        }
        if let t = initTask { await t.value }
        while !cancelled {
            if tasks.isEmpty { pumpSegments() }
            guard let t = tasks.first?.value else { break }
            await t.value
        }
        if let t = playlistTask { await t.value }
        // Stop placeholder retries and wait for any in-flight one, so a late "recording" meta.json
        // can never land on top of the final one.
        placeholderAttempt?.cancel()
        placeholderTask?.cancel()
        _ = await placeholderAttempt?.result
        await placeholderTask?.value
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
        guard await writeFinal(m, layout: l) else { return }
        if !pagesUploaded, let card = TitleCard.jpeg(title: m.title) {
            try? await client.put(l.cardKey, data: card, contentType: "image/jpeg", cacheControl: ShareLayout.revalidate)
        }
        complete()
    }

    private func complete() {
        completed = true
        lastError = nil
        discardJournal()
        removeSpool()
        if let l = layout { LiveUploads.remove(l.key, self) }
        resumeWaiters()
    }

    /// Writes the final meta.json and pages, retrying until they land. Before each attempt it reads
    /// meta.json back; if a newer revision is live, it writes nothing and gives way to it. `true` when written.
    private func writeFinal(_ m: ViewerMeta, layout l: ShareLayout) async -> Bool {
        let html = Data(ViewerPage.html(m).utf8)
        let client = self.client
        var delay = 2.0
        while !cancelled && !Task.isCancelled {
            do {
                if let newer = try await newerRevision() {
                    await giveWay(polished: newer.video != nil)
                    return false
                }
                try await client.put(l.metaKey, data: m.jsonData, contentType: "application/json", cacheControl: ShareLayout.noStore)
                try await withThrowingTaskGroup(of: Void.self) { g in
                    for k in l.pageKeys {
                        g.addTask { try await client.put(k, data: html, contentType: "text/html; charset=utf-8", cacheControl: ShareLayout.revalidate) }
                    }
                    try await g.waitForAll()
                }
                return true
            } catch is CancellationError {
                return false
            } catch {
                noteError(error)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
                delay = min(delay * 2, 30)
            }
        }
        return false
    }

    // MARK: Newer revisions

    /// The share's meta.json if a publish since this stream (Update Link) has a higher revision: it owns
    /// the link from then on. `nil` when the bucket has this upload's own (or none); throws when unreadable.
    private func newerRevision() async throws -> ViewerMeta? {
        guard let l = layout else { return nil }
        let data: Data
        do { data = try await client.get(l.metaKey) } catch let e as ShareError where e.status == 404 { return nil }
        guard let m = try? JSONCoding.decoder.decode(ViewerMeta.self, from: data), m.revision > (meta?.revision ?? 0) else { return nil }
        return m
    }

    /// For best-effort writes: only a newer revision that was actually read counts.
    private func isSuperseded() async -> Bool { (try? await newerRevision()) != nil }

    /// A newer revision owns the link: stop without touching meta.json or the page. When it plays a
    /// polished MP4 the stream is deleted (it may show what the edit blurred or cut); if that fails the
    /// journal stays, so the next launch's resume tries again.
    private func giveWay(polished: Bool) async {
        if polished, let l = layout {
            do { try await ShareService.removeStream(l, client: client) } catch {
                noteError(error)
                halt()
                return
            }
        }
        complete()
    }

    /// A publish of this share is about to write (see `LiveUploads.retire`): stop every upload and wait
    /// until none is in flight. The journal stays until `superseded()`, so if the publish fails the next
    /// launch still finishes the stream.
    func retire() async {
        guard !cancelled, !completed else { return }
        let running = Array(tasks.values) + [initTask, playlistTask, placeholderTask, finalizeTask].compactMap { $0 }
        let attempt = placeholderAttempt
        halt()
        attempt?.cancel()
        for t in running { await t.value }
        _ = await attempt?.result
    }

    /// The publish after `retire()` is live: nothing is left to resume.
    func superseded() {
        discardJournal()
        removeSpool()
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

    /// Waits (no timeout) until the upload completes, is cancelled or halts. `true` when it completed.
    func waitUntilDone() async -> Bool {
        guard layout != nil else { return false }
        if !completed && !cancelled {
            await withCheckedContinuation { c in
                if completed || cancelled { c.resume() } else { waiters[UUID()] = c }
            }
        }
        return completed
    }

    private func resumeWaiters() {
        let w = waiters
        waiters = [:]
        w.values.forEach { $0.resume() }
    }

    func halt() {
        cancelled = true
        if let l = layout { LiveUploads.remove(l.key, self) }
        initTask?.cancel()
        tasks.values.forEach { $0.cancel() }
        playlistTask?.cancel()
        placeholderTask?.cancel()
        finalizeTask?.cancel()
        resumeWaiters()
    }

    // MARK: Cancel

    func cancel() async {
        guard !cancelled else { return }
        cancelled = true
        if let l = layout { LiveUploads.remove(l.key, self) }
        initTask?.cancel()
        tasks.values.forEach { $0.cancel() }
        playlistTask?.cancel()
        placeholderTask?.cancel()
        placeholderAttempt?.cancel()
        finalizeTask?.cancel()
        tasks = [:]
        pending = [:]
        resumeWaiters()
        discardJournal()
        removeSpool()
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

    private func removeSpool() {
        if let dir = spoolDirectory { try? FileManager.default.removeItem(at: dir) }
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
              let j = try? JSONCoding.decoder.decode(UploadJournal.self, from: data) else {
            // No journal: the upload finished (or can never resume), so nothing reads the segments again.
            if !FileManager.default.fileExists(atPath: url.path), manifest.status != .recording { bundle.removeSegments(of: .share) }
            return nil
        }
        guard j.bucket == destination.bucket else { return nil }

        layout = l
        journal = j
        recordingID = j.recordingID
        durations = j.durations
        uploaded = Set(j.uploaded)
        initUploaded = j.initUploaded
        hlsAnnounced = !j.uploaded.isEmpty
        pagesUploaded = true
        LiveUploads.add(l.key, self)

        let current = (try? await client.get(l.metaKey)).flatMap { try? JSONCoding.decoder.decode(ViewerMeta.self, from: $0) }
        // The stream is revision 0. A publish since that plays a polished MP4 (in this project's record
        // or in the bucket) replaced it for good: delete the stream instead of finishing it.
        if share.polished || ((current?.revision ?? 0) > 0 && current?.video != nil) {
            await giveWay(polished: true)
            if completed, manifest.status != .recording { bundle.removeSegments(of: .share) }
            return nil
        }
        // Start from the live meta.json if it is there (keeps createdAt and a newer title-only update,
        // whose revision it keeps); else rebuild.
        if let m = current {
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
        // Queue the recorder's own files (read when their turn comes; nothing is copied).
        removeSpool()
        for name in files {
            guard let n = HLSPlaylist.segmentNumber(name), !uploaded.contains(n), !name.hasPrefix(".") else { continue }
            if durations[n] == nil { durations[n] = fallback }
            enqueue(index: n, payload: .file(dir.appendingPathComponent(name), owned: false))
        }
        journal?.durations = durations
        saveJournal()

        // A relaunch means the recording is over, whatever the journal says.
        finished = true
        totalDuration = j.totalDuration ?? manifest.duration
        finalizeTask = Task { await self.finalize() }
        await finalizeTask?.value
        // Done: the bundle's copies of the stream (its consolidated share.mp4 stays) aren't needed any more.
        if completed, let m = try? bundle.readManifest(), m.status != .recording { bundle.removeSegments(of: .share) }
        return info
    }
}
