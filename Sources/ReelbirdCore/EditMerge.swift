import Foundation

/// Three-way merge of edit documents, for an editor that finds `edit.json` changed by someone else
/// (`reelbird edit`, MCP `set_edit`) while it has its own unsaved changes.
///
/// Works on the JSON form, recursively through objects: a value only one side changed takes that
/// side's change; arrays and plain values are replaced whole. Where both sides changed the same value
/// differently, ours (the editor's, which the person is looking at) wins and the path is reported as
/// a conflict, so the caller can keep their version somewhere instead of losing it silently.
public enum EditMerge {
    public struct Result: Sendable {
        public var edit: EditDocument
        /// JSON paths both sides changed differently, e.g. `["zoom.intensity"]`.
        public var conflicts: [String]
    }

    public static func merge(base: EditDocument, ours: EditDocument, theirs: EditDocument) -> Result {
        guard let b = object(base), let o = object(ours), let t = object(theirs) else { return Result(edit: ours, conflicts: []) }
        var conflicts: [String] = []
        let merged = mergeObjects(b, o, t, path: "", conflicts: &conflicts)
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              let edit = try? JSONCoding.decoder.decode(EditDocument.self, from: data) else { return Result(edit: ours, conflicts: conflicts) }
        return Result(edit: edit, conflicts: conflicts)
    }

    private static func object(_ e: EditDocument) -> [String: Any]? {
        guard let data = try? JSONCoding.encoder.encode(e) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case (let x?, let y?): (x as AnyObject).isEqual(y)
        default: false
        }
    }

    private static func mergeObjects(_ b: [String: Any], _ o: [String: Any], _ t: [String: Any], path: String,
                                     conflicts: inout [String]) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in Set(b.keys).union(o.keys).union(t.keys).sorted() {
            let p = path.isEmpty ? key : "\(path).\(key)"
            let bv = b[key], ov = o[key], tv = t[key]
            let value: Any?
            if same(ov, bv) {
                value = tv
            } else if same(tv, bv) || same(ov, tv) {
                value = ov
            } else if let bo = bv as? [String: Any], let oo = ov as? [String: Any], let to = tv as? [String: Any] {
                value = mergeObjects(bo, oo, to, path: p, conflicts: &conflicts)
            } else {
                conflicts.append(p)
                value = ov
            }
            if let value { out[key] = value }
        }
        return out
    }
}
