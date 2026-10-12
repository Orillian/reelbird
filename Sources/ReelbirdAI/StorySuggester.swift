import Foundation
import FoundationModels
import ReelbirdCore

public enum StorySuggesterError: LocalizedError, Sendable, Equatable {
    /// Apple Intelligence isn't available; the message says why and what to do.
    case unavailable(String)
    case emptyTranscript
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let m), .failed(let m): return m
        case .emptyTranscript: return "The transcript is empty, so there is nothing to title. Record with a microphone or check the audio."
        }
    }
}

/// Title and chapter suggestions from a transcript, using the on-device Foundation Models LLM (macOS 26+).
///
/// The on-device model has a small context window (4k tokens on 26.0–26.3, read via `contextSize` later),
/// so long transcripts are summarised chunk by chunk and the summaries are combined. Generation is greedy,
/// so the same transcript gives the same suggestions on the same OS.
public enum StorySuggester {
    /// Whether the on-device model is ready to use.
    public static var isAvailable: Bool {
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        return false
    }

    /// Why the model is unavailable, in words a user can act on (`nil` when available).
    public static var unavailableReason: String? {
        guard #available(macOS 26, *) else { return "Titles and chapters need macOS 26 or later." }
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings to get titles and chapters."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading its model. Try again in a few minutes."
        case .unavailable: return "Apple Intelligence isn't available right now."
        }
    }

    /// Suggests a title and chapters. Chapter times are on the transcript's timeline, start at 0,
    /// and are snapped to the start of a transcript segment.
    public static func suggest(transcript: Transcript) async throws -> (title: String, chapters: [Chapter]) {
        guard !transcript.isEmpty else { throw StorySuggesterError.emptyTranscript }
        guard #available(macOS 26, *) else {
            throw StorySuggesterError.unavailable("Titles and chapters need macOS 26 or later.")
        }
        if let reason = unavailableReason { throw StorySuggesterError.unavailable(reason) }
        let lines = timestampedLines(transcript)
        let context = SystemLanguageModel.default.contextSize
        var budget = chunkCharacterBudget(contextSize: context)
        // A context overflow (token estimate too optimistic) retries once with smaller chunks.
        for attempt in 0..<2 {
            do {
                let draft = try await FMStory.run(lines: lines, chunkBudget: budget)
                return finalize(draft: draft, transcript: transcript)
            } catch let e as FMStory.Overflow where attempt == 0 {
                _ = e
                budget /= 2
            }
        }
        throw StorySuggesterError.failed("The transcript couldn't be fitted into the on-device model.")
    }

    // MARK: - Pure helpers (unit-tested)

    struct Line: Hashable, Sendable {
        var time: Double
        var text: String
        var rendered: String { "[\(Int(time.rounded(.down)))s] \(text)" }
    }

    struct Draft: Sendable {
        var title: String
        var chapters: [(time: Double, title: String)]
    }

    static func timestampedLines(_ t: Transcript) -> [Line] {
        t.segments.compactMap { s in
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : Line(time: s.range.start, text: text)
        }
    }

    /// Characters of transcript per request: about 3 characters per token (conservative for English),
    /// leaving room for instructions, the output schema and the response.
    static func chunkCharacterBudget(contextSize: Int) -> Int {
        max(1_500, (contextSize - 1_400) * 3)
    }

    /// Splits lines into chunks of at most `budget` rendered characters (a single over-long line is truncated).
    static func chunk(_ lines: [Line], budget: Int) -> [[Line]] {
        var chunks: [[Line]] = []
        var current: [Line] = []
        var size = 0
        for var line in lines {
            if line.rendered.count > budget { line.text = String(line.text.prefix(max(50, budget - 20))) }
            let n = line.rendered.count + 1
            if size + n > budget, !current.isEmpty { chunks.append(current); current = []; size = 0 }
            current.append(line); size += n
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Cleans the model's output: snaps chapter times to segment starts, sorts, forces the first chapter to 0,
    /// drops chapters closer than 10 s to the previous one, and tidies titles.
    static func finalize(draft: Draft, transcript: Transcript) -> (title: String, chapters: [Chapter]) {
        let starts = transcript.segments.map(\.range.start).sorted()
        let end = transcript.duration
        func snap(_ t: Double) -> Double {
            starts.min(by: { abs($0 - t) < abs($1 - t) }) ?? max(0, t)
        }
        var chapters: [Chapter] = []
        for c in draft.chapters.sorted(by: { $0.time < $1.time }) {
            let title = tidy(c.title)
            guard !title.isEmpty, c.time.isFinite, c.time <= end else { continue }
            let t = snap(max(0, c.time))
            if let last = chapters.last, t - last.time < 10 { continue }
            chapters.append(Chapter(time: t, title: title))
        }
        if chapters.isEmpty { chapters = [Chapter(time: 0, title: "Introduction")] }
        chapters[0].time = 0
        let title = tidy(draft.title)
        return (title.isEmpty ? "Untitled recording" : title, chapters)
    }

    static func tidy(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
        while let last = t.last, ".".contains(last) { t.removeLast() }
        if t.count > 80 { t = String(t.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return t
    }
}

// MARK: - Foundation Models

@available(macOS 26, *)
private enum FMStory {
    struct Overflow: Error {}

    static let instructions = """
    You write titles and chapter lists for screen recordings (tutorials, demos, walkthroughs). \
    Each transcript line starts with its start time in seconds, like [93s]. \
    Titles are specific and plain: what the viewer will learn or see, at most 8 words, no quotes, no emoji. \
    Chapter titles are 2 to 5 words. A chapter's start is copied from the [Ns] marker of the line where that topic begins.
    """

    static let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 500)

    static func run(lines: [StorySuggester.Line], chunkBudget: Int) async throws -> StorySuggester.Draft {
        let chunks = StorySuggester.chunk(lines, budget: chunkBudget)
        if chunks.count == 1 {
            let story: StoryOutput = try await ask(
                "Transcript:\n\(chunks[0].map(\.rendered).joined(separator: "\n"))\n\nWrite a title and 2 to 8 chapters.")
            return .init(title: story.title, chapters: story.chapters.map { (Double($0.start), $0.title) })
        }
        // Map: summarise each chunk with a few candidate chapters.
        var parts: [ChunkOutput] = []
        for (i, c) in chunks.enumerated() {
            let part: ChunkOutput = try await ask(
                "Part \(i + 1) of \(chunks.count) of a transcript:\n\(c.map(\.rendered).joined(separator: "\n"))\n\nSummarise this part in one sentence and list 1 to 3 chapters.")
            parts.append(part)
        }
        // Reduce: pick the title and the final chapter list from the candidates.
        var outline = ""
        for (i, p) in parts.enumerated() {
            outline += "Part \(i + 1): \(p.summary)\n"
            for ch in p.chapters { outline += "  [\(ch.start)s] \(ch.title)\n" }
        }
        let story: StoryOutput = try await ask(
            "Outline of a long screen recording, with candidate chapters:\n\(outline)\nWrite a title for the whole recording and choose 3 to 10 chapters from the candidates (keep their [Ns] times).")
        return .init(title: story.title, chapters: story.chapters.map { (Double($0.start), $0.title) })
    }

    static func ask<T: Generable>(_ prompt: String) async throws -> T {
        let session = LanguageModelSession(instructions: instructions)
        do {
            return try await session.respond(to: prompt, generating: T.self, options: options).content
        } catch let e as LanguageModelSession.GenerationError {
            switch e {
            case .exceededContextWindowSize: throw Overflow()
            case .guardrailViolation, .refusal:
                throw StorySuggesterError.failed("Apple Intelligence declined to summarise this recording.")
            case .unsupportedLanguageOrLocale:
                throw StorySuggesterError.failed("Apple Intelligence doesn't support this recording's language yet.")
            case .assetsUnavailable:
                throw StorySuggesterError.unavailable("Apple Intelligence's model isn't ready. Try again in a few minutes.")
            default:
                throw StorySuggesterError.failed("Apple Intelligence couldn't summarise this recording: \(e.localizedDescription)")
            }
        } catch let e as StorySuggesterError {
            throw e
        } catch {
            if #available(macOS 27, *), let lm = error as? LanguageModelError {
                if case .contextSizeExceeded = lm { throw Overflow() }
            }
            throw StorySuggesterError.failed("Apple Intelligence couldn't summarise this recording: \(error.localizedDescription)")
        }
    }
}

// Hand-written `Generable` conformances (what `@Generable` expands to). The macro plugin ships with Xcode,
// not the Command Line Tools this project builds with, so the schema is spelled out.

@available(macOS 26, *)
private struct ChapterOutput: Generable {
    var start: Int
    var title: String

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, description: "A chapter of the recording", properties: [
            .init(name: "start", description: "Start time in seconds, copied from a [Ns] marker", type: Int.self),
            .init(name: "title", description: "Chapter title, 2 to 5 words", type: String.self),
        ])
    }
    init(_ content: GeneratedContent) throws {
        start = try content.value(forProperty: "start")
        title = try content.value(forProperty: "title")
    }
    var generatedContent: GeneratedContent { GeneratedContent(properties: ["start": start, "title": title]) }
}

@available(macOS 26, *)
private struct StoryOutput: Generable {
    var title: String
    var chapters: [ChapterOutput]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, description: "Title and chapters for a screen recording", properties: [
            .init(name: "title", description: "Video title, at most 8 words", type: String.self),
            .init(name: "chapters", description: "Chapters in time order; the first starts at 0", type: [ChapterOutput].self,
                  guides: [.maximumCount(10)]),
        ])
    }
    init(_ content: GeneratedContent) throws {
        title = try content.value(forProperty: "title")
        chapters = try content.value(forProperty: "chapters")
    }
    var generatedContent: GeneratedContent { GeneratedContent(properties: ["title": title, "chapters": chapters]) }
}

@available(macOS 26, *)
private struct ChunkOutput: Generable {
    var summary: String
    var chapters: [ChapterOutput]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, description: "Summary of one part of a transcript", properties: [
            .init(name: "summary", description: "One sentence: what happens in this part", type: String.self),
            .init(name: "chapters", description: "1 to 3 chapters that start in this part", type: [ChapterOutput].self,
                  guides: [.maximumCount(3)]),
        ])
    }
    init(_ content: GeneratedContent) throws {
        summary = try content.value(forProperty: "summary")
        chapters = try content.value(forProperty: "chapters")
    }
    var generatedContent: GeneratedContent { GeneratedContent(properties: ["summary": summary, "chapters": chapters]) }
}
