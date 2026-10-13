import AVFoundation
import CoreMedia
import Foundation
import ReelbirdCore
import Speech

/// Why transcription can't run, or failed.
public enum TranscriberError: LocalizedError, Sendable, Equatable {
    /// The OS or device has no on-device speech model.
    case unavailable(String)
    case unsupportedLocale(String)
    /// The speech model for the locale could not be downloaded or installed.
    case modelDownloadFailed(String)
    /// Speech Recognition permission is missing (macOS 15 fallback only).
    case notAuthorized(String)
    case unreadableAudio(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let m), .modelDownloadFailed(let m), .notAuthorized(let m), .unreadableAudio(let m), .failed(let m):
            return m
        case .unsupportedLocale(let l):
            return "On-device transcription doesn't support \(l) on this Mac."
        }
    }
}

/// Whether transcription can run for a locale right now.
public enum TranscriberAvailability: Sendable, Hashable {
    /// Ready; `locale` is the exact locale that will be used.
    case available(locale: String)
    /// Supported, but the speech model downloads on first use.
    case needsDownload(locale: String)
    case unsupportedLocale(String)
    case unavailable(reason: String)

    public var canTranscribe: Bool {
        switch self {
        case .available, .needsDownload: return true
        default: return false
        }
    }
}

/// On-device speech-to-text with word timings.
///
/// macOS 26+: `SpeechAnalyzer` + `SpeechTranscriber` (models managed by `AssetInventory`, downloaded on
/// first use; no permission prompt). macOS 15: `SFSpeechRecognizer` with on-device recognition only
/// (needs Speech Recognition permission, which only an app bundle with a usage description can request).
public enum Transcriber {
    /// Whether this OS and device can transcribe on-device at all. Use `availability(for:)` for a locale-specific answer.
    public static var isAvailable: Bool {
        if #available(macOS 26, *) {
            return SpeechTranscriber.isAvailable
        }
        return SFSpeechRecognizer(locale: .current)?.supportsOnDeviceRecognition ?? false
    }

    /// Detailed availability for a locale (default: the user's current locale).
    public static func availability(for locale: Locale? = nil) async -> TranscriberAvailability {
        let requested = locale ?? .current
        if #available(macOS 26, *) {
            guard SpeechTranscriber.isAvailable else {
                return .unavailable(reason: "This Mac has no on-device speech model.")
            }
            guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
                return .unsupportedLocale(requested.identifier(.bcp47))
            }
            let id = resolved.identifier(.bcp47)
            let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
            return installed.contains(id) ? .available(locale: id) : .needsDownload(locale: id)
        }
        guard let r = SFSpeechRecognizer(locale: requested) else { return .unsupportedLocale(requested.identifier(.bcp47)) }
        guard r.supportsOnDeviceRecognition else {
            return .unavailable(reason: "On-device recognition for \(requested.identifier(.bcp47)) isn't installed. Turn on Dictation in System Settings › Keyboard to download it.")
        }
        return .available(locale: r.locale.identifier(.bcp47))
    }

    /// Transcribes an audio (or audio+video) file. Times are relative to the start of the file.
    /// - Parameters:
    ///   - locale: Spoken language; `nil` = the user's current locale.
    ///   - progress: Called with 0...1 as audio is processed (and while a model downloads, if needed).
    public static func transcribe(audio: URL, locale: Locale? = nil,
                                  progress: (@Sendable (Double) -> Void)? = nil) async throws -> Transcript {
        try await transcribe(audio: audio, locale: locale, input: .automatic, progress: progress)
    }

    /// How audio is fed to `SpeechAnalyzer` (tests force `.audioFile` to cover the macOS 26 path on 27).
    enum InputPath: Sendable { case automatic, audioFile }

    static func transcribe(audio: URL, locale: Locale?, input: InputPath,
                           progress: (@Sendable (Double) -> Void)?) async throws -> Transcript {
        guard FileManager.default.fileExists(atPath: audio.path) else {
            throw TranscriberError.unreadableAudio("Audio file not found: \(audio.path)")
        }
        if #available(macOS 26, *) {
            return try await AnalyzerTranscription.run(url: audio, locale: locale ?? .current, input: input, progress: progress)
        }
        return try await LegacyTranscription.run(url: audio, locale: locale ?? .current)
    }

    /// Groups words into sentence-like segments (sentence punctuation or a pause ends a segment).
    static func segments(from words: [Transcript.Word], pause: Double = 0.8) -> [Transcript.Segment] {
        var out: [Transcript.Segment] = []
        var current: [Transcript.Word] = []
        func flush() {
            guard let f = current.first, let l = current.last else { return }
            out.append(.init(range: TimeRange(start: f.range.start, end: l.range.end),
                             text: current.map(\.text).joined(separator: " "), words: current))
            current = []
        }
        for w in words {
            if let last = current.last, w.range.start - last.range.end >= pause { flush() }
            current.append(w)
            if let c = w.text.last, ".?!".contains(c) { flush() }
        }
        flush()
        return out
    }
}

// MARK: - macOS 26+: SpeechAnalyzer

@available(macOS 26, *)
private enum AnalyzerTranscription {
    static func run(url: URL, locale requested: Locale, input: Transcriber.InputPath,
                    progress: (@Sendable (Double) -> Void)?) async throws -> Transcript {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriberError.unavailable("This Mac has no on-device speech model.")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw TranscriberError.unsupportedLocale(requested.identifier(.bcp47))
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        try await ensureModel(for: transcriber, locale: locale, progress: progress)

        let duration = await AudioDecoding.duration(of: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: .init(priority: .userInitiated, modelRetention: .whileInUse))
        let results = transcriber.results
        let collector = Task { () throws -> [Transcript.Segment] in
            var segments: [Transcript.Segment] = []
            for try await result in results {
                if let seg = segment(from: result) { segments.append(seg) }
                if duration > 0 { progress?(min(1, result.range.end.seconds / duration)) }
            }
            return segments
        }

        var temporary: URL?
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        do {
            let last: CMTime?
            if #available(macOS 27, *), input == .automatic {
                let provider = try await AssetInputSequenceProvider.provider(from: AVURLAsset(url: url), compatibleWith: [transcriber])
                last = try await analyzer.analyzeSequence(provider.analyzerInputs)
            } else {
                let file: AVAudioFile
                if let f = try? AVAudioFile(forReading: url) {
                    file = f
                } else {
                    let pcm = try await AudioDecoding.decodeToTemporaryPCM(url)
                    temporary = pcm
                    file = try AVAudioFile(forReading: pcm)
                }
                last = try await analyzer.analyzeSequence(from: file)
            }
            if let last {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw map(error, url: url)
        }
        let segments: [Transcript.Segment]
        do { segments = try await collector.value } catch { throw map(error, url: url) }
        progress?(1)
        return Transcript(segments: segments, locale: locale.identifier(.bcp47))
    }

    /// Makes sure the locale's model is installed, downloading it if needed.
    static func ensureModel(for transcriber: SpeechTranscriber, locale: Locale,
                            progress: (@Sendable (Double) -> Void)?) async throws {
        let request: AssetInstallationRequest?
        do {
            request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        } catch {
            throw TranscriberError.modelDownloadFailed(
                "Couldn't prepare the \(locale.identifier(.bcp47)) speech model: \(error.localizedDescription)")
        }
        guard let request else { return }
        let observation = request.progress.observe(\.fractionCompleted) { p, _ in
            // Model download counts as the first 10% of the job.
            progress?(min(0.1, p.fractionCompleted * 0.1))
        }
        defer { observation.invalidate() }
        do {
            try await request.downloadAndInstall()
        } catch {
            throw TranscriberError.modelDownloadFailed(
                "Downloading the \(locale.identifier(.bcp47)) speech model failed: \(error.localizedDescription). Check your internet connection and free disk space, then try again.")
        }
    }

    static func segment(from result: SpeechTranscriber.Result) -> Transcript.Segment? {
        var words: [Transcript.Word] = []
        for run in result.text.runs {
            let piece = String(result.text[run.range].characters)
            let token = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            if let tr = run.audioTimeRange, tr.start.isNumeric, tr.end.isNumeric {
                words.append(.init(range: TimeRange(start: tr.start.seconds, end: tr.end.seconds),
                                   text: token, confidence: run.transcriptionConfidence))
            } else if !words.isEmpty {
                // Untimed text (e.g. punctuation split into its own run) joins the previous word.
                words[words.count - 1].text += token
            }
        }
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let start = words.first?.range.start ?? result.range.start.seconds
        let end = words.last?.range.end ?? result.range.end.seconds
        return .init(range: TimeRange(start: start, end: end), text: text, words: words)
    }

    static func map(_ error: any Error, url: URL) -> any Error {
        if error is TranscriberError || error is CancellationError { return error }
        if let e = error as? AudioDecoding.LoadError { return TranscriberError.unreadableAudio(e.message) }
        let ns = error as NSError
        if ns.domain == AVFoundationErrorDomain || ns.domain == NSOSStatusErrorDomain {
            return TranscriberError.unreadableAudio("Can't read audio from \(url.lastPathComponent): \(error.localizedDescription)")
        }
        return TranscriberError.failed("Transcription failed: \(error.localizedDescription)")
    }
}

// MARK: - macOS 15: SFSpeechRecognizer (on-device only)

private enum LegacyTranscription {
    static func run(url: URL, locale: Locale) async throws -> Transcript {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw TranscriberError.unsupportedLocale(locale.identifier(.bcp47))
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriberError.unavailable(
                "On-device recognition for \(locale.identifier(.bcp47)) isn't installed. Turn on Dictation in System Settings › Keyboard to download it.")
        }
        try await authorize()

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation

        let box = ResultBox<[Transcript.Word]>()
        let words: [Transcript.Word] = try await withCheckedThrowingContinuation { cont in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    let words = result.bestTranscription.segments.map {
                        Transcript.Word(range: TimeRange(start: $0.timestamp, end: $0.timestamp + $0.duration),
                                        text: $0.substring, confidence: Double($0.confidence))
                    }
                    if box.trySet(.success(words)) { cont.resume(returning: words) }
                } else if let error {
                    let mapped = TranscriberError.failed("Transcription failed: \(error.localizedDescription)")
                    if box.trySet(.failure(mapped)) { cont.resume(throwing: mapped) }
                }
            }
            _ = task
        }
        return Transcript(segments: Transcriber.segments(from: words), locale: locale.identifier(.bcp47))
    }

    static func authorize() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return
        case .denied, .restricted:
            throw TranscriberError.notAuthorized(
                "Speech Recognition is turned off for Reelbird. Allow it in System Settings › Privacy & Security › Speech Recognition.")
        case .notDetermined:
            // Asking without a usage description crashes the process, so only app bundles may ask.
            guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
                throw TranscriberError.notAuthorized(
                    "Speech Recognition permission hasn't been granted yet. Generate captions once in the Reelbird app to grant it.")
            }
            let status = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
            }
            guard status == .authorized else {
                throw TranscriberError.notAuthorized(
                    "Speech Recognition permission was declined. Allow it in System Settings › Privacy & Security › Speech Recognition.")
            }
        @unknown default:
            throw TranscriberError.notAuthorized("Speech Recognition permission is unavailable.")
        }
    }
}
