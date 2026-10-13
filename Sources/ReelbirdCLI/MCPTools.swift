import Foundation

/// MCP tool definitions (JSON Schema 2020-12 input schemas), in a fixed order.
enum MCPTools {
    private static let project: JSONValue = [
        "type": "string",
        "description": "A .reelbird project path, a project name from list_projects, or \"latest\".",
    ]
    private static func object(_ props: [String: JSONValue], required: [String] = []) -> JSONValue {
        var o: [String: JSONValue] = ["type": "object", "properties": .object(props), "additionalProperties": false]
        if !required.isEmpty { o["required"] = .array(required.map(JSONValue.string)) }
        if props.isEmpty { o.removeValue(forKey: "properties") }
        return .object(o)
    }
    private static func tool(_ name: String, _ title: String, _ description: String, _ schema: JSONValue,
                             readOnly: Bool = false, destructive: Bool = false, openWorld: Bool = false) -> JSONValue {
        [
            "name": .string(name), "title": .string(title), "description": .string(description), "inputSchema": schema,
            "annotations": ["readOnlyHint": .bool(readOnly), "destructiveHint": .bool(destructive), "openWorldHint": .bool(openWorld)],
        ]
    }

    static let definitions: JSONValue = [
        tool("list_sources", "List capture sources",
             "Lists displays, windows, microphones and cameras with the IDs start_recording accepts.",
             object([:]), readOnly: true),
        tool("start_recording", "Start recording",
             "Starts recording the screen and returns a session_id; recording continues in the background until stop_recording (or `duration` elapses). Records the main display when no source is given.",
             object([
                "display": ["type": "string", "description": "Display index (\"1\" = main) or display ID."],
                "window": ["type": "string", "description": "Window ID from list_sources."],
                "area": object([
                    "x": ["type": "number"], "y": ["type": "number"],
                    "width": ["type": "number", "exclusiveMinimum": 0], "height": ["type": "number", "exclusiveMinimum": 0],
                ], required: ["x", "y", "width", "height"]),
                "duration": ["type": "number", "exclusiveMinimum": 0, "description": "Stop automatically after this many seconds."],
                "fps": ["type": "integer", "minimum": 1, "maximum": 240, "default": 60],
                "quality": ["type": "string", "enum": ["high", "max", "compact"], "default": "high"],
                "microphone": ["type": "string", "description": "\"default\", a microphone ID, or \"none\".", "default": "default"],
                "system_audio": ["type": "boolean", "default": true],
                "camera": ["type": "string", "description": "Camera ID to record alongside the screen."],
                "keystrokes": ["type": "boolean", "default": false, "description": "Record key presses for a keystroke overlay."],
                "share": ["type": "boolean", "default": false, "description": "Upload while recording so the link works when it stops."],
                "out": ["type": "string", "description": "Bundle path; default is a new project in the library."],
             ])),
        tool("stop_recording", "Stop recording",
             "Stops a recording started by start_recording, saves the project and returns its path (and share link).",
             object([
                "session_id": ["type": "string"],
                "discard": ["type": "boolean", "default": false, "description": "Delete the recording instead of saving it."],
             ], required: ["session_id"])),
        tool("list_projects", "List projects", "Lists projects in the library, newest first.",
             object(["limit": ["type": "integer", "minimum": 0]]), readOnly: true),
        tool("project_info", "Project details",
             "Shows a project's tracks, length, edit summary, chapters, captions and share link.",
             object(["project": project], required: ["project"]), readOnly: true),
        tool("set_edit", "Edit a project",
             "Changes edit.json. `set` maps dotted keys to values, e.g. {\"zoom.intensity\": 0.7, \"zoom.mode\": \"auto\", \"background.kind\": \"solid\", \"background.colors\": [\"#1B1B1F\"], \"background.padding\": 0.06, \"cursor.size\": 1.5, \"camera.corner\": \"bottomLeft\", \"canvas.aspect\": \"16:9\", \"captions.burnIn\": true, \"title\": \"Demo\"}. Times are seconds or m:ss. Returns the full edit.",
             object([
                "project": project,
                "set": ["type": "object", "description": "Dotted edit keys to new values.", "additionalProperties": true],
                "trim": ["type": "string", "description": "Keep only START-END (END may be \"end\"); \"none\" removes the trim."],
                "cuts": ["type": "array", "items": ["type": "string"], "description": "Ranges to remove, each \"START-END\"."],
                "clear_cuts": ["type": "boolean", "default": false, "description": "Remove existing cuts before adding new ones."],
             ], required: ["project"])),
        tool("export", "Export video", "Renders the edited project to a video file and returns its path.",
             object([
                "project": project,
                "format": ["type": "string", "enum": ["mp4", "hevc", "prores", "gif"], "default": "mp4"],
                "height": ["type": "integer", "minimum": 16, "maximum": 8640, "description": "Output height in pixels; default is the source size."],
                "fps": ["type": "integer", "minimum": 1, "maximum": 240],
                "out": ["type": "string", "description": "Output file path; default is the project's exports folder."],
             ], required: ["project"])),
        tool("enhance_voice", "Enhance voice",
             "Cleans up the voice (noise removal, leveling, de-essing, presence EQ) into the project's voice stem and turns Enhance voice on. The raw microphone is never changed; turn it off with set_edit audio.enhance=false.",
             object([
                "project": project,
                "strength": ["type": "string", "enum": ["light", "medium", "strong", "max"], "description": "How much noise to remove; default is the project's setting (medium)."],
                "mix": ["type": "number", "minimum": 0, "maximum": 1, "description": "0 = original, 1 = fully enhanced; default is the project's setting (1)."],
             ], required: ["project"])),
        tool("generate_captions", "Generate captions",
             "Transcribes the project on-device, writes captions.vtt and a word-timed transcript.json, and links the captions in edit.json.",
             object([
                "project": project,
                "locale": ["type": "string", "description": "Spoken language, e.g. \"en-US\"; default is the system language."],
                "srt": ["type": "boolean", "default": false, "description": "Also write captions.srt."],
             ], required: ["project"])),
        tool("suggest_story", "Suggest title and chapters",
             "Suggests a title and chapters from the transcript with on-device Apple Intelligence (transcribes first if needed).",
             object([
                "project": project,
                "apply": ["type": "boolean", "default": true, "description": "Save the suggestions to edit.json."],
                "locale": ["type": "string"],
             ], required: ["project"])),
        tool("detect_silences", "Detect silences",
             "Finds silent stretches in the project's audio; with apply, adds cuts that remove them (keeping a little air around speech).",
             object([
                "project": project,
                "threshold_db": ["type": "number", "default": -45],
                "min_duration": ["type": "number", "exclusiveMinimum": 0, "default": 1.2],
                "apply": ["type": "boolean", "default": false],
             ], required: ["project"])),
        tool("share", "Share link",
             "Publishes the project to the configured bucket and returns its link (or returns the existing link). polished renders the current edit and replaces the quick version; the link stays the same.",
             object([
                "project": project,
                "polished": ["type": "boolean", "default": false],
             ], required: ["project"]), openWorld: true),
        tool("unshare", "Remove share link", "Deletes the project's uploaded files; the link stops working.",
             object(["project": project], required: ["project"]), destructive: true, openWorld: true),
    ]

    static let names: Set<String> = Set((definitions.arrayValue ?? []).compactMap { $0["name"]?.stringValue })
}
