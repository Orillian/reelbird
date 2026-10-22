import Foundation
import ReelbirdCore
import ReelbirdShare

/// Writes a guide to a folder: Markdown with images, an HTML page with Guide and Click-through (the share page,
/// without the video), or a Claude skill.
public enum GuideExport {
    public enum Format: String, CaseIterable, Sendable {
        case markdown = "md", html, skill

        public init?(name: String) {
            switch name.lowercased() {
            case "md", "markdown": self = .markdown
            case "html", "web": self = .html
            case "skill": self = .skill
            default: return nil
            }
        }
    }

    public enum ExportError: LocalizedError, Equatable {
        case noSteps
        case notEmpty(String)
        public var errorDescription: String? {
            switch self {
            case .noSteps: return "This recording has no steps: no clicks, typing or shortcuts in the kept part. Record with clicks, or turn on keystroke recording."
            case .notEmpty(let path): return "\(path) already has a guide. Choose another folder or delete it first."
            }
        }
    }

    /// Writes the guide into `folder` (created when missing) and returns the main file: `guide.md`, `index.html` or
    /// `SKILL.md`. Refuses a folder that already holds that file unless `overwrite`.
    @discardableResult
    public static func write(_ guide: BuiltGuide, title: String, createdAt: Date = Date(), format: Format, to folder: URL,
                             overwrite: Bool = false) throws -> URL {
        guard !guide.steps.isEmpty else { throw ExportError.noSteps }
        let fm = FileManager.default
        let main = folder.appendingPathComponent(format == .markdown ? "guide.md" : format == .html ? "index.html" : "SKILL.md")
        if !overwrite, fm.fileExists(atPath: main.path) { throw ExportError.notEmpty(folder.path) }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled recording" : title
        switch format {
        case .markdown, .skill:
            let images = folder.appendingPathComponent("images", isDirectory: true)
            try fm.createDirectory(at: images, withIntermediateDirectories: true)
            for (i, jpeg) in guide.markedJPEGs().enumerated() {
                if let jpeg { try jpeg.write(to: images.appendingPathComponent(imageName(i + 1)), options: .atomic) }
            }
            let body = markdown(guide.steps, imageFolder: "images")
            let text: String
            if format == .skill {
                text = """
                ---
                name: \(skillName(name))
                description: \(yamlString(oneLine("\(name): step-by-step instructions recorded on screen with Reelbird, with a screenshot of each step. Use it to repeat this task.", max: 300)))
                ---

                # \(oneLine(name, max: 200))

                Follow these steps in order. Each step has a screenshot in images/ with the place to click marked.

                \(body)
                """
            } else {
                text = "# \(oneLine(name, max: 200))\n\n\(body)"
            }
            try Data(text.utf8).write(to: main, options: .atomic)
        case .html:
            let images = folder.appendingPathComponent("steps", isDirectory: true)
            try fm.createDirectory(at: images, withIntermediateDirectories: true)
            var shared = guide.shared()
            for i in shared.steps.indices {
                guard i < shared.images.count, let jpeg = shared.images[i] else { continue }
                let file = imageName(i + 1)
                try jpeg.write(to: images.appendingPathComponent(file), options: .atomic)
                shared.steps[i].image = "steps/\(file)"
            }
            var meta = ViewerMeta(id: "guide", title: name, status: .ready, createdAt: createdAt, updatedAt: Date(),
                                  duration: guide.timeline.duration, pageURL: "./", baseURL: "./")
            meta.guide = ViewerMeta.Guide(steps: shared.steps)
            try Data(ViewerPage.html(meta).utf8).write(to: main, options: .atomic)
        }
        return main
    }

    /// The numbered steps as Markdown: a `##` heading where a section starts, the instruction, the narration as a
    /// quote and the image. Numbers carry on across sections.
    public static func markdown(_ steps: [GuideStep], imageFolder: String) -> String {
        var out: [String] = []
        for (i, s) in steps.enumerated() {
            let n = i + 1
            if let section = s.section?.trimmingCharacters(in: .whitespacesAndNewlines), !section.isEmpty {
                out.append("## \(oneLine(section, max: 120))\n")
            }
            let marker = "\(n). "
            let indent = String(repeating: " ", count: marker.count)
            var item = marker + escape(oneLine(s.text, max: 300))
            if let note = s.narration?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                item += "\n\n\(indent)> \(escape(oneLine(note, max: 400)))"
            }
            item += "\n\n\(indent)![Step \(n)](\(imageFolder)/\(imageName(n)))\n"
            out.append(item)
        }
        return out.joined(separator: "\n")
    }

    static func imageName(_ n: Int) -> String { String(format: "%02d.jpg", n) }

    /// Text on one line, at most `max` characters.
    static func oneLine(_ s: String, max: Int) -> String {
        let t = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return t.count > max ? String(t.prefix(max - 1)) + "…" : t
    }

    /// Escapes the characters that would start Markdown formatting or HTML in a line of plain text.
    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\`*_[]<>#|".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// A YAML double-quoted scalar.
    static func yamlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A skill name: lower case letters, digits and hyphens, at most 64 characters.
    static func skillName(_ title: String) -> String {
        let words = title.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : " " }.joined()
            .split(separator: " ").map(String.init)
        let slug = words.joined(separator: "-").filter { $0.isASCII }
        let trimmed = String(slug.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "recorded-guide" : trimmed
    }
}
