import Foundation
import FoundationModels
import ReelbirdCore

/// Words guide steps with the on-device Foundation Models LLM (macOS 26+): one short instruction per step from
/// what was clicked, the action and what the narrator said. The model only words steps; which steps exist and
/// what they point at come from the event log and the screen. A sentence that drops the step's label isn't used
/// (`GuideSteps.resolve` falls back to the template), so the model can't send a reader to a different button.
public enum StepWriter {
    public static var isAvailable: Bool { StorySuggester.isAvailable }

    /// Steps per request: the 4k-token window of macOS 26 holds 12 steps with their narration comfortably.
    static let batch = 12

    /// One sentence per step, for steps with narration: the model's value is the purpose the narrator gave, so a
    /// step nobody talked about keeps the template (as do typing steps, so typed text never reaches the model).
    /// `nil` where the template stays.
    public static func write(steps: [GuideStep], narration: [String?],
                             progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [String?] {
        guard #available(macOS 26, *), isAvailable else { throw StorySuggesterError.unavailable(StorySuggester.unavailableReason ?? "Apple Intelligence isn't available.") }
        var out = [String?](repeating: nil, count: steps.count)
        let wordable = steps.indices.filter { i in
            steps[i].kind != .type && !(narration[i]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        guard !wordable.isEmpty else { progress(1); return out }
        let chunks = stride(from: 0, to: wordable.count, by: batch).map { Array(wordable[$0..<min($0 + batch, wordable.count)]) }
        for (done, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let lines = chunk.enumerated().map { j, i in describe(steps[i], number: j + 1, narration: narration[i]) }
            let written = try await FMSteps.run(lines: lines)
            for w in written {
                guard w.number >= 1, w.number <= chunk.count else { continue }
                let i = chunk[w.number - 1]
                let text = tidy(w.text, label: steps[i].label)
                if !text.isEmpty { out[i] = text }
            }
            progress(Double(done + 1) / Double(chunks.count))
        }
        return out
    }

    /// One step as the model reads it, e.g. `3. click on "Save" (said: "now save it")`.
    static func describe(_ s: GuideStep, number: Int, narration: String?) -> String {
        let action: String
        switch s.kind {
        case .click: action = "click"
        case .doubleClick: action = "double-click"
        case .rightClick: action = "right-click"
        case .drag: action = "drag"
        case .shortcut, .key: action = "press \(s.keys ?? "a key")"
        case .type: action = "type"
        }
        var line = "\(number). \(action)"
        if let label = s.label { line += " on \"\(label)\"" } else if s.isPointer { line += " (no text on the target)" }
        if s.count > 1 { line += " \(s.count) times" }
        if let n = narration?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            line += " (narrator said: \"\(String(n.suffix(240)))\")"
        }
        return line
    }

    /// One line, no surrounding quotes, no final full stop, the label in straight double quotes, at most 160
    /// characters; empty when it doesn't start with a word (an instruction starts with its verb).
    static func tidy(_ s: String, label: String?) -> String {
        var t = tidy(s)
        if let label, !label.isEmpty {
            for q in ["'", "‘", "’", "“", "”", "`"] {
                t = t.replacingOccurrences(of: "\(q)\(label)\(q)", with: "\"\(label)\"")
                t = t.replacingOccurrences(of: "‘\(label)’", with: "\"\(label)\"")
            }
        }
        guard let first = t.first, first.isLetter else { return "" }
        return t
    }

    static func tidy(_ s: String) -> String {
        var t = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        t = t.trimmingCharacters(in: .whitespaces)
        if t.count > 2, t.hasPrefix("\""), t.hasSuffix("\""), t.dropFirst().dropLast().contains("\"") == false {
            t = String(t.dropFirst().dropLast())
        }
        while let last = t.last, ".".contains(last) { t.removeLast() }
        t = t.replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
        return t.count > 160 ? String(t.prefix(160)).trimmingCharacters(in: .whitespaces) : t
    }
}

// MARK: - Foundation Models

@available(macOS 26, *)
private enum FMSteps {
    static let instructions = """
    You write the steps of a how-to guide made from a screen recording. \
    Each input line is one step: what the person did, the text on what they clicked, and what they said. \
    For each step write one instruction a reader can follow, at most 14 words, starting with a verb. \
    Copy the clicked text exactly, in double quotes. Add the purpose only when the narrator gave it. \
    Never invent buttons, menus, values or text that isn't in the line. No emoji.
    """

    #if compiler(>=6.4)
    static let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 700)
    #else
    static let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 700)
    #endif

    static func run(lines: [String]) async throws -> [StepLineOutput] {
        let session = LanguageModelSession(instructions: instructions)
        let prompt = "Steps:\n" + lines.joined(separator: "\n") + "\n\nWrite one instruction for each numbered step."
        do {
            return try await session.respond(to: prompt, generating: StepsOutput.self, options: options).content.steps
        } catch let e as LanguageModelSession.GenerationError {
            throw StorySuggesterError.failed("Apple Intelligence couldn't word the steps: \(e.localizedDescription)")
        }
    }
}

// Hand-written `Generable` conformances: the macro plugin ships with Xcode, not the Command Line Tools.
@available(macOS 26, *)
private struct StepLineOutput: Generable {
    var number: Int
    var text: String

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, description: "The instruction for one step", properties: [
            .init(name: "number", description: "The step's number from the input", type: Int.self),
            .init(name: "text", description: "The instruction, at most 14 words, the clicked text in double quotes", type: String.self),
        ])
    }
    init(_ content: GeneratedContent) throws {
        number = try content.value(forProperty: "number")
        text = try content.value(forProperty: "text")
    }
    var generatedContent: GeneratedContent { GeneratedContent(properties: ["number": number, "text": text]) }
}

@available(macOS 26, *)
private struct StepsOutput: Generable {
    var steps: [StepLineOutput]

    static var generationSchema: GenerationSchema {
        GenerationSchema(type: Self.self, description: "Instructions for the guide's steps", properties: [
            .init(name: "steps", description: "One entry per input step, in order", type: [StepLineOutput].self,
                  guides: [.maximumCount(StepWriter.batch)]),
        ])
    }
    init(_ content: GeneratedContent) throws {
        steps = try content.value(forProperty: "steps")
    }
    var generatedContent: GeneratedContent { GeneratedContent(properties: ["steps": steps]) }
}
