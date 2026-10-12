import Foundation
import ReelbirdAI
import ReelbirdCore

/// Parameters for starting a recording (shared by `reelbird record` and the MCP `start_recording` tool).
struct RecordParams: Sendable {
    var selector: SourceSelector = .mainDisplay
    var duration: Double?
    var frameRate = 60
    var quality: RecordingOptions.Quality = .high
    /// "default", a device ID, or "none".
    var microphone = "default"
    var systemAudio = true
    var camera: String?
    var keystrokes = false
    var share = false
    var out: String?
}

/// Hands out unique new-bundle URLs even when several recordings start in the same second (MCP).
enum BundleNames {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var reserved: Set<String> = []

    static func reserve(in library: ProjectLibrary) -> URL {
        lock.withLock {
            var url = library.newBundleURL()
            let base = url.deletingPathExtension().lastPathComponent
            var n = 2
            while reserved.contains(url.path) || FileManager.default.fileExists(atPath: url.path) {
                url = library.root.appendingPathComponent("\(base) \(n).\(ProjectBundle.pathExtension)")
                n += 1
            }
            reserved.insert(url.path)
            return url
        }
    }
}

/// Every CLI/MCP operation. Each returns a `Report` (JSON + human text) or throws a `CLIError`.
struct Operations: Sendable {
    let engine: any Engine
    let locator: ProjectLocator

    static func transcriptURL(_ b: ProjectBundle) -> URL { b.transcriptURL }

    // MARK: Sources

    func sources() async throws -> Report {
        let list = try await engine.sources()
        func group(_ k: SourceInfo.Kind) -> [SourceInfo] { list.filter { $0.kind == k } }
        let json: JSONValue = [
            "displays": try JSONValue.encode(group(.display)),
            "windows": try JSONValue.encode(group(.window)),
            "microphones": try JSONValue.encode(group(.microphone)),
            "cameras": try JSONValue.encode(group(.camera)),
        ]
        var lines: [String] = []
        for (title, kind) in [("Displays", SourceInfo.Kind.display), ("Windows", .window), ("Microphones", .microphone), ("Cameras", .camera)] {
            let items = group(kind)
            lines.append("\(title):")
            if items.isEmpty { lines.append("  (none)") }
            for (i, s) in items.enumerated() {
                var l = "  " + (kind == .display ? "\(i + 1). " : "") + "\(s.id.padding(toLength: max(8, s.id.count + 1), withPad: " ", startingAt: 0)) \(s.name)"
                if let d = s.detail { l += " — \(d)" }
                if let w = s.width, let h = s.height { l += "  \(w)×\(h)" }
                if s.isDefault { l += "  (default)" }
                lines.append(l)
            }
        }
        return Report(json: json, text: lines.joined(separator: "\n"))
    }

    // MARK: Recording

    func makeOptions(_ p: RecordParams) async throws -> (RecordingOptions, URL) {
        guard (1...240).contains(p.frameRate) else { throw CLIError.usage("Frame rate must be between 1 and 240.") }
        if let d = p.duration, d <= 0 { throw CLIError.usage("Duration must be more than 0 seconds.") }
        let source = try await engine.resolve(p.selector)
        var o = RecordingOptions(source: source)
        o.frameRate = p.frameRate
        o.quality = p.quality
        o.captureSystemAudio = p.systemAudio
        o.microphoneID = p.microphone.lowercased() == "none" ? nil : p.microphone
        o.cameraID = p.camera
        o.captureKeystrokes = p.keystrokes
        o.shareWhileRecording = p.share
        o.countdown = 0
        o.maxDuration = p.duration
        let url: URL
        if let out = p.out {
            var u = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
            if u.pathExtension != ProjectBundle.pathExtension { u.appendPathExtension(ProjectBundle.pathExtension) }
            guard !FileManager.default.fileExists(atPath: u.path) else {
                throw CLIError("\(Format.path(u)) already exists; choose another --out path.", code: .usage)
            }
            url = u
        } else {
            url = BundleNames.reserve(in: locator.library)
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw CLIError("Can't create \(Format.path(url.deletingLastPathComponent())): \(error.localizedDescription)")
        }
        return (o, url)
    }

    func recordingFinished(_ bundle: ProjectBundle) -> Report {
        let m = try? bundle.readManifest()
        let json: JSONValue = [
            "bundle": .string(bundle.url.path),
            "duration": JSONValue(m?.duration),
            "status": JSONValue(m?.status.rawValue),
            "shareURL": JSONValue(m?.share?.url),
        ]
        var text = bundle.url.path
        if let s = m?.share?.url { text += "\n\(s)" }
        return Report(json: json, text: text)
    }

    // MARK: Projects

    func info(_ project: String) throws -> Report { try ProjectSummary.info(try locator.resolve(project)) }

    func list(limit: Int? = nil) -> Report { ProjectSummary.list(locator, limit: limit) }

    func recover(_ project: String) throws -> Report {
        let bundle = try locator.resolve(project)
        let did = try engine.recover(bundle: bundle)
        return Report(json: ["bundle": .string(bundle.url.path), "recovered": .bool(did)],
                      text: did ? "Recovered \(Format.path(bundle.url))." : "\(Format.path(bundle.url)) didn't need recovery.")
    }

    // MARK: Edit

    func edit(_ project: String, sets: [EditSetter.Assignment], trim: String?, cuts: [String], clearCuts: Bool) throws -> Report {
        let bundle = try locator.resolve(project)
        let manifest: ProjectManifest
        do { manifest = try bundle.readManifest() } catch {
            throw CLIError("Can't read project.json: \(error.localizedDescription)", code: .dataError)
        }
        var edit: EditDocument
        do { edit = try bundle.readEdit() } catch {
            throw CLIError("Can't read edit.json: \(error.localizedDescription)", code: .dataError)
        }
        let changed = !sets.isEmpty || trim != nil || !cuts.isEmpty || clearCuts
        if !sets.isEmpty { edit = try EditSetter.apply(sets, to: edit) }
        let duration = manifest.duration > 0 ? manifest.duration : nil
        if let trim {
            if ["none", "off", "clear"].contains(trim.lowercased()) { edit.trim = nil } else {
                let r = try TimeParsing.range(trim, duration: duration)
                if let duration, r.start >= duration {
                    throw CLIError.usage("Trim starts at \(Format.seconds(r.start))s but the recording is \(Format.seconds(duration))s long.")
                }
                edit.trim = TimeRange(start: r.start, end: duration.map { min($0, r.end) } ?? r.end)
            }
        }
        if clearCuts { edit.cuts = [] }
        for c in cuts {
            let r = try TimeParsing.range(c, duration: duration)
            edit.cuts = Self.mergingCut(r, into: edit.cuts)
        }
        if changed {
            do { try bundle.writeEdit(edit) } catch {
                throw CLIError("Can't write edit.json: \(error.localizedDescription)")
            }
        }
        let timeline = EditTimeline(manifest: manifest, edit: edit)
        var json = try JSONValue.encode(edit)
        if case .object(var o) = json {
            o["outputDuration"] = JSONValue(timeline.duration)
            o["changed"] = .bool(changed)
            json = .object(o)
        }
        let text = changed
            ? "Updated \(Format.path(bundle.editURL)) (length \(Format.duration(timeline.duration)))."
            : json.serialized(pretty: true)
        return Report(json: json, text: text)
    }

    /// Adds a cut, merging overlapping or touching cuts.
    static func mergingCut(_ cut: TimeRange, into cuts: [TimeRange]) -> [TimeRange] {
        var all = (cuts + [cut]).sorted { $0.start < $1.start }
        var out: [TimeRange] = []
        for c in all where c.duration > 0 {
            if let last = out.last, c.start <= last.end { out[out.count - 1].end = max(last.end, c.end) } else { out.append(c) }
        }
        all = out
        return all
    }

    // MARK: Export

    func export(_ project: String, request: ExportRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> Report {
        let bundle = try locator.resolve(project)
        let edit = try bundle.readEdit()
        let url = try await engine.export(bundle: bundle, edit: edit, request: request, progress: progress)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        return Report(json: ["file": .string(url.path), "format": .string(request.format.rawValue), "bytes": size.map { .int(Int($0)) } ?? .null],
                      text: url.path)
    }

    // MARK: AI

    /// The audio track to transcribe or analyse: the microphone, else system audio.
    func audioTrack(_ bundle: ProjectBundle) throws -> (url: URL, startTime: Double, kind: TrackKind) {
        let m = try bundle.readManifest()
        for kind in [TrackKind.microphone, .systemAudio] {
            guard let t = m.track(kind) else { continue }
            guard let url = bundle.mediaURL(for: kind, in: m) else {
                throw CLIError("The \(kind.rawValue) track isn't finalised yet (still recording, or the app quit mid-recording).",
                               hint: "Run `reelbird recover \"\(bundle.url.path)\"` first.")
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CLIError("Missing media file \(Format.path(url)).", code: .noInput)
            }
            return (url, t.startTime, kind)
        }
        throw CLIError("This recording has no audio track (no microphone or system audio was recorded).", code: .dataError)
    }

    func captions(_ project: String, locale: String?, srt: Bool, progress: (@Sendable (Double) -> Void)?) async throws -> Report {
        let bundle = try locator.resolve(project)
        let track = try audioTrack(bundle)
        let loc = locale.map(Locale.init(identifier:))
        let availability = await Transcriber.availability(for: loc)
        switch availability {
        case .unavailable(let reason): throw CLIError(reason, code: .unavailable)
        case .unsupportedLocale(let l):
            throw CLIError("On-device transcription doesn't support \(l).", code: .unavailable, hint: "Pass another language with --locale, e.g. --locale en-US.")
        case .available, .needsDownload: break
        }
        let transcript: Transcript
        do {
            transcript = try await Transcriber.transcribe(audio: track.url, locale: loc, progress: progress).shifted(by: track.startTime)
        } catch let e as TranscriberError {
            switch e {
            case .unavailable, .unsupportedLocale, .notAuthorized: throw CLIError(e.localizedDescription, code: .unavailable)
            default: throw CLIError(e.localizedDescription)
            }
        }
        do {
            try JSONCoding.writeAtomically(transcript, to: Self.transcriptURL(bundle))
            try Data(Captions.webVTT(transcript).utf8).write(to: bundle.captionsURL, options: .atomic)
            var srtPath: String?
            if srt {
                let u = bundle.url.appendingPathComponent("captions.srt")
                try Data(Captions.srt(transcript).utf8).write(to: u, options: .atomic)
                srtPath = u.path
            }
            var edit = try bundle.readEdit()
            edit.captions.file = bundle.captionsURL.lastPathComponent
            try bundle.writeEdit(edit)
            let cues = Captions.cues(transcript).count
            let words = transcript.allWords.count
            let preview = String(transcript.text.prefix(160))
            return Report(json: [
                "captions": .string(bundle.captionsURL.path), "srt": JSONValue(srtPath),
                "transcript": .string(Self.transcriptURL(bundle).path), "locale": .string(transcript.locale),
                "track": .string(track.kind.rawValue), "cues": .int(cues), "words": .int(words), "preview": .string(preview),
            ], text: transcript.isEmpty
                ? "No speech found. Wrote an empty \(Format.path(bundle.captionsURL))."
                : "Wrote \(Format.path(bundle.captionsURL)) (\(cues) cues, \(words) words, \(transcript.locale)).")
        } catch let e as CLIError { throw e } catch {
            throw CLIError("Can't write captions: \(error.localizedDescription)")
        }
    }

    func loadOrMakeTranscript(_ bundle: ProjectBundle, locale: String?) async throws -> Transcript {
        let url = Self.transcriptURL(bundle)
        if let data = try? Data(contentsOf: url), let t = try? JSONCoding.decoder.decode(Transcript.self, from: data) { return t }
        _ = try await captions(bundle.url.path, locale: locale, srt: false, progress: nil)
        return try JSONCoding.decoder.decode(Transcript.self, from: Data(contentsOf: url))
    }

    func suggest(_ project: String, apply: Bool, locale: String?) async throws -> Report {
        let bundle = try locator.resolve(project)
        guard StorySuggester.isAvailable else {
            throw CLIError(StorySuggester.unavailableReason ?? "Apple Intelligence isn't available.", code: .unavailable)
        }
        let transcript = try await loadOrMakeTranscript(bundle, locale: locale)
        let story: (title: String, chapters: [Chapter])
        do { story = try await StorySuggester.suggest(transcript: transcript) } catch let e as StorySuggesterError {
            switch e {
            case .unavailable: throw CLIError(e.localizedDescription, code: .unavailable)
            case .emptyTranscript: throw CLIError(e.localizedDescription, code: .dataError)
            case .failed: throw CLIError(e.localizedDescription)
            }
        }
        if apply {
            var edit = try bundle.readEdit()
            edit.title = story.title
            edit.chapters = story.chapters
            try bundle.writeEdit(edit)
        }
        var lines = [story.title]
        for c in story.chapters { lines.append("  \(Format.duration(c.time).padding(toLength: 8, withPad: " ", startingAt: 0)) \(c.title)") }
        if apply { lines.append("Saved to \(Format.path(bundle.editURL)).") }
        return Report(json: [
            "title": .string(story.title),
            "chapters": .array(story.chapters.map { ["time": JSONValue($0.time), "title": .string($0.title)] }),
            "applied": .bool(apply),
        ], text: lines.joined(separator: "\n"))
    }

    func silences(_ project: String, thresholdDB: Double, minDuration: Double, padding: Double, apply: Bool) throws -> Report {
        let bundle = try locator.resolve(project)
        let track = try audioTrack(bundle)
        let ranges: [TimeRange]
        do {
            ranges = try SilenceDetector.silentRanges(audio: track.url, thresholdDB: thresholdDB, minDuration: minDuration)
                .map { TimeRange(start: $0.start + track.startTime, end: $0.end + track.startTime) }
        } catch { throw CLIError(error.localizedDescription) }
        let duration = (try? bundle.readManifest().duration) ?? nil
        let cuts = SilenceDetector.trimCuts(silences: ranges, padding: padding, duration: duration)
        if apply, !cuts.isEmpty {
            var edit = try bundle.readEdit()
            for c in cuts { edit.cuts = Self.mergingCut(c, into: edit.cuts) }
            try bundle.writeEdit(edit)
        }
        let total = cuts.reduce(0) { $0 + $1.duration }
        let rangeJSON: (TimeRange) -> JSONValue = { ["start": JSONValue($0.start), "end": JSONValue($0.end)] }
        var text = "\(ranges.count) silence\(ranges.count == 1 ? "" : "s") over \(Format.seconds(minDuration))s"
        if !cuts.isEmpty { text += "; trimming them saves \(Format.duration(total))" }
        text += apply && !cuts.isEmpty ? " (cuts added to edit.json)." : "."
        for r in ranges { text += "\n  \(Format.duration(r.start)) – \(Format.duration(r.end))" }
        return Report(json: ["silences": .array(ranges.map(rangeJSON)), "cuts": .array(cuts.map(rangeJSON)),
                             "savedSeconds": JSONValue(total), "applied": .bool(apply)], text: text)
    }

    // MARK: Share

    func share(_ project: String, polished: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> Report {
        let bundle = try locator.resolve(project)
        var manifest = try bundle.readManifest()
        if !polished, let existing = manifest.share {
            return Report(json: ["url": .string(existing.url), "polished": .bool(existing.polished), "updated": false],
                          text: existing.url)
        }
        let info = try await engine.share(bundle: bundle, edit: try bundle.readEdit(), polished: polished, progress: progress)
        manifest.share = info
        try bundle.writeManifest(manifest)
        return Report(json: ["url": .string(info.url), "polished": .bool(info.polished), "updated": true], text: info.url)
    }

    func unshare(_ project: String) async throws -> Report {
        let bundle = try locator.resolve(project)
        var manifest = try bundle.readManifest()
        guard let info = manifest.share else {
            return Report(json: ["removed": false], text: "\(Format.path(bundle.url)) has no share link.")
        }
        try await engine.unshare(bundle: bundle, info: info)
        manifest.share = nil
        try bundle.writeManifest(manifest)
        return Report(json: ["removed": true, "url": .string(info.url)], text: "Removed \(info.url).")
    }

    // MARK: Config

    func configShow() -> Report {
        guard let d = engine.shareDestination() else {
            return Report(json: ["share": .null],
                          text: "Sharing isn't set up. Run: reelbird config share --endpoint URL --bucket NAME --access-key ID --public-base URL --secret-stdin")
        }
        let secret = engine.hasShareSecret()
        return Report(json: ["share": [
            "endpoint": .string(d.endpoint), "bucket": .string(d.bucket), "region": .string(d.region),
            "accessKeyID": .string(d.accessKeyID), "publicBaseURL": .string(d.publicBaseURL), "prefix": .string(d.prefix),
            "secretStored": .bool(secret),
        ]], text: """
        Share destination
          Endpoint     \(d.endpoint)
          Bucket       \(d.bucket)  (region \(d.region), prefix \(d.prefix)/)
          Access key   \(d.accessKeyID)
          Public URL   \(d.publicBaseURL)
          Secret       \(secret ? "stored in Keychain" : "missing")
        """)
    }

    func configShare(_ d: ShareDestination, secret: String, test: Bool) async throws -> Report {
        for (name, value) in [("endpoint", d.endpoint), ("public-base", d.publicBaseURL)] {
            guard let u = URL(string: value), u.scheme == "https" || u.scheme == "http", u.host != nil else {
                throw CLIError.usage("--\(name) must be a full URL, e.g. https://example.com (got '\(value)').")
            }
        }
        guard !secret.isEmpty else { throw CLIError.usage("The secret access key is empty.") }
        if test { try await engine.testShareConnection(d, secret: secret) }
        try engine.saveShareDestination(d, secret: secret)
        return Report(json: ["saved": true, "tested": .bool(test)],
                      text: "Saved share destination \(d.bucket) at \(d.endpoint)\(test ? " (connection OK)" : "").")
    }
}
