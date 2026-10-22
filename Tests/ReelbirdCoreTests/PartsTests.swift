import Foundation
import Testing
@testable import ReelbirdCore

@Suite struct PartsTests {
    let cuts = [TimeRange(start: 20, end: 24)]

    @Test func partsAreBoundedBySplitsCutsAndTrim() {
        #expect(Parts.part(containing: 5, duration: 40, trim: nil, splits: [], cuts: []) == TimeRange(start: 0, end: 40))
        #expect(Parts.part(containing: 12, duration: 40, trim: nil, splits: [9, 15], cuts: cuts) == TimeRange(start: 9, end: 15))
        #expect(Parts.part(containing: 17, duration: 40, trim: nil, splits: [9, 15], cuts: cuts) == TimeRange(start: 15, end: 20))
        #expect(Parts.part(containing: 30, duration: 40, trim: TimeRange(start: 1, end: 35), splits: [9, 15], cuts: cuts) == TimeRange(start: 24, end: 35))
    }

    @Test func draggingAnEdgeInwardCutsWhatItPasses() {
        let r = Parts.trimEdge(of: TimeRange(start: 9, end: 15), leading: true, to: 11, duration: 40, trim: nil, cuts: cuts)
        #expect(r.cuts == [TimeRange(start: 9, end: 11), TimeRange(start: 20, end: 24)])
        #expect(r.part == TimeRange(start: 11, end: 15))
        // Up to the cut after it: the cuts join.
        let e = Parts.trimEdge(of: TimeRange(start: 15, end: 20), leading: false, to: 18, duration: 40, trim: nil, cuts: cuts)
        #expect(e.cuts == [TimeRange(start: 18, end: 24)])
        #expect(e.part == TimeRange(start: 15, end: 18))
    }

    @Test func draggingOutwardBringsBackCutFootageOnly() {
        // The part after the cut reaches back into it.
        let r = Parts.trimEdge(of: TimeRange(start: 24, end: 40), leading: true, to: 21, duration: 40, trim: nil, cuts: cuts)
        #expect(r.cuts == [TimeRange(start: 20, end: 21)])
        #expect(r.part == TimeRange(start: 21, end: 40))
        // All the way back: the cut is gone.
        let all = Parts.trimEdge(of: TimeRange(start: 24, end: 40), leading: true, to: 10, duration: 40, trim: nil, cuts: cuts)
        #expect(all.cuts.isEmpty && all.part == TimeRange(start: 20, end: 40))
        // Next to a split with nothing cut, the edge can't move outward.
        let blocked = Parts.trimEdge(of: TimeRange(start: 9, end: 15), leading: true, to: 7, duration: 40, trim: nil, cuts: cuts)
        #expect(blocked.cuts == cuts && blocked.part == TimeRange(start: 9, end: 15))
    }

    @Test func theOuterEdgesMoveTheTrimAndPartsKeepAMinimumLength() {
        let r = Parts.trimEdge(of: TimeRange(start: 0, end: 9), leading: true, to: 2, duration: 40, trim: nil, cuts: [])
        #expect(r.trim == TimeRange(start: 2, end: 40))
        let back = Parts.trimEdge(of: TimeRange(start: 2, end: 9), leading: true, to: -5, duration: 40, trim: TimeRange(start: 2, end: 40), cuts: [])
        #expect(back.trim == nil && back.part == TimeRange(start: 0, end: 9))
        let tiny = Parts.trimEdge(of: TimeRange(start: 9, end: 15), leading: false, to: 2, duration: 40, trim: nil, cuts: [])
        #expect(abs(tiny.part.duration - Parts.minDuration) < 1e-9)
    }

    @Test func cutsCloseUpOnTheTimeline() {
        let space = CutSpace(duration: 40, cuts: cuts + [TimeRange(start: 30, end: 32)])
        #expect(space.collapsedDuration == 34)
        #expect(space.collapsed(10) == 10)
        #expect(space.collapsed(22) == 20)       // inside a cut: its join
        #expect(space.collapsed(26) == 22)
        #expect(space.collapsed(35) == 29)
        #expect(space.source(20) == 24)          // a join lands just after its cut
        #expect(space.source(22) == 26)
        #expect(space.source(29) == 35)
        for t in stride(from: 0.0, through: 40, by: 0.5) where !space.cuts.contains(where: { $0.start < t && t < $0.end }) && !space.cuts.contains(where: { $0.start == t }) {
            #expect(abs(space.source(space.collapsed(t)) - t) < 1e-9)
        }
    }

    @Test func splitsAreSavedAndReadLeniently() throws {
        var e = EditDocument()
        e.splits = [9, 15]
        let back = try JSONCoding.decoder.decode(EditDocument.self, from: JSONCoding.encoder.encode(e))
        #expect(back.splits == [9, 15])
        let messy = try JSONCoding.decoder.decode(EditDocument.self, from: Data(#"{"splits": [15, -1, 9]}"#.utf8))
        #expect(messy.splits == [9, 15])
        #expect(try JSONCoding.decoder.decode(EditDocument.self, from: Data(#"{"splits": "x"}"#.utf8)).splits.isEmpty)
    }
}

@Suite struct BlurOptionTests {
    @Test func blurShapeSoftnessAndSolidRoundTrip() throws {
        var a = Annotation(kind: .blur, range: TimeRange(start: 0, end: 2), rect: NormRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1))
        #expect(a.blurShape == .rounded && a.blurSoftness == 0 && a.blurStyle == .blur)
        a.style = .solid; a.shape = .oval; a.softness = 0.4
        let back = try JSONCoding.decoder.decode(Annotation.self, from: JSONCoding.encoder.encode(a))
        #expect(back.blurStyle == .solid && back.blurShape == .oval && back.blurSoftness == 0.4)
        #expect(back.title == "Redact")
        // Unknown shapes and out-of-range softness read safely.
        let odd = #"{"kind":"blur","range":{"start":0,"end":1},"rect":{"x":0,"y":0,"width":1,"height":1},"shape":"star","softness":7}"#
        let o = try JSONCoding.decoder.decode(Annotation.self, from: Data(odd.utf8))
        #expect(o.blurShape == .rounded && o.blurSoftness == 1)
    }
}
