import Foundation
import ReelbirdCore

/// The static viewer page uploaded to `r/<id>/index.html`.
///
/// Self-contained (inline CSS and JS, no fonts to fetch; the only images are the share's own step
/// images). hls.js is loaded from jsDelivr, pinned and integrity-checked, only when the share has no
/// polished MP4 yet and the browser can't play HLS natively. Open Graph and Twitter tags are baked
/// into the HTML because link unfurlers (Slack, iMessage) don't run JavaScript.
///
/// With `meta.guide` the page also has a Guide and a Click-through view (`#guide`, `#demo`), and with
/// `meta.text` a Copy text mode that lays the text read from the video over the paused frame. Every
/// value from the meta and the text layer is checked in the page script before use: file names must
/// match the same pattern the server allows, numbers are clamped, and text only ever goes in as text.
public enum ViewerPage {
    /// hls.js release used by the page (npm "latest" on 2026-10-12, released 2026-09-11).
    public static let hlsVersion = "1.7.3"
    static let hlsURL = "https://cdn.jsdelivr.net/npm/hls.js@1.7.3/dist/hls.light.min.js"
    static let hlsIntegrity = "sha384-y8wQxRLtNclrHbMBLBLTEkgUrdFu6uWzZiobE1wBE09nt2wHIZlBPvPepdZU4+MM"

    public static func html(_ meta: ViewerMeta) -> String {
        let title = meta.title.isEmpty ? "Untitled recording" : meta.title
        let duration = meta.duration.map(formatDuration)
        let image = meta.url(meta.poster) ?? meta.url(meta.card)
        let description: String = {
            switch meta.status {
            case .recording: return "A screen recording in progress. Open to watch."
            case .processing, .ready: return duration.map { "A \($0) screen recording." } ?? "A screen recording."
            }
        }()

        var head: [String] = [
            tag("title", text: title),
            named("description", description),
            named("robots", "noindex, nofollow"),
            #"<link rel="canonical" href="\#(attr(meta.pageURL))">"#,
            property("og:site_name", "Reelbird"),
            property("og:type", meta.video != nil ? "video.other" : "website"),
            property("og:title", title),
            property("og:description", description),
            property("og:url", meta.pageURL),
            named("twitter:card", "summary_large_image"),
            named("twitter:title", title),
            named("twitter:description", description),
        ]
        if let image {
            head.append(property("og:image", image))
            head.append(named("twitter:image", image))
            head.append(property("og:image:alt", title))
            if meta.poster == nil {
                head.append(property("og:image:width", "1200"))
                head.append(property("og:image:height", "630"))
            }
        }
        if let video = meta.url(meta.video) {
            head.append(property("og:video", video))
            if video.hasPrefix("https://") { head.append(property("og:video:secure_url", video)) }
            head.append(property("og:video:type", "video/mp4"))
            if let w = meta.width, let h = meta.height {
                head.append(property("og:video:width", String(w)))
                head.append(property("og:video:height", String(h)))
            }
        }

        let ratio: String = {
            guard let w = meta.width, let h = meta.height, w > 0, h > 0 else { return "16 / 9" }
            return "\(w) / \(h)"
        }()
        let ratioNumber: String = {
            guard let w = meta.width, let h = meta.height, w > 0, h > 0 else { return "1.7778" }
            return String(format: "%.4f", Double(w) / Double(h))
        }()
        let subline = [duration, formatDate(meta.createdAt)].compactMap { $0 }.joined(separator: " · ")
        let json = String(decoding: meta.jsonData, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")

        // One pass: text that came from the user (title, chapters) can't pull in another placeholder.
        return fill(template, [
            "HEAD": head.joined(separator: "\n"),
            "TITLE": text(title),
            "SUBLINE": text(subline),
            "RATIO": ratio,
            "RATIO_N": ratioNumber,
            "POSTER": meta.url(meta.poster).map { #" poster="\#(attr($0))""# } ?? "",
            "HLS_URL": hlsURL,
            "HLS_SRI": hlsIntegrity,
            "SITE": ReelbirdInfo.websiteURL,
            "META": json,
        ])
    }

    /// Replaces each `{{NAME}}` in `template` with `values[NAME]`, without looking inside inserted values.
    /// Unknown `{{…}}` stay as they are.
    static func fill(_ template: String, _ values: [String: String]) -> String {
        var out = ""
        out.reserveCapacity(template.utf8.count + 4096)
        var rest = template[...]
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            let after = rest[open.upperBound...]
            if let close = after.range(of: "}}"), let value = values[String(after[..<close.lowerBound])] {
                out += value
                rest = after[close.upperBound...]
            } else {
                out += "{{"
                rest = after
            }
        }
        out += rest
        return out
    }

    static func formatDuration(_ s: Double) -> String {
        let t = Int(max(0, s).rounded())
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func formatDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: d)
    }

    static func text(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func attr(_ s: String) -> String { text(s) }
    static func tag(_ name: String, text t: String) -> String { "<\(name)>\(text(t))</\(name)>" }
    static func named(_ name: String, _ content: String) -> String { #"<meta name="\#(name)" content="\#(attr(content))">"# }
    static func property(_ p: String, _ content: String) -> String { #"<meta property="\#(p)" content="\#(attr(content))">"# }

    // MARK: Template

    static let template = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
{{HEAD}}
<meta name="theme-color" media="(prefers-color-scheme: light)" content="#fff4e8">
<meta name="theme-color" media="(prefers-color-scheme: dark)" content="#1a1512">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%22100 100 824 824%22%3E%3Cpath d=%22M924 512L924 640.59C924 722.19 924 763 910.11 806.92C892.66 854.88 854.88 892.66 806.92 910.11C763 924 722.19 924 640.59 924L383.41 924C301.81 924 261 924 217.08 910.11C169.12 892.66 131.34 854.88 113.89 806.92C100 763 100 722.19 100 640.59L100 383.41C100 301.81 100 261 113.89 217.08C131.34 169.12 169.12 131.34 217.08 113.89C261 100 301.81 100 383.41 100L640.59 100C722.19 100 763 100 806.92 113.89C854.88 131.34 892.66 169.12 910.11 217.08C924 261 924 301.81 924 383.41Z%22 fill=%22%231A1512%22/%3E%3Cg transform=%22translate(118 104) scale(3.15)%22%3E%3Cpath d=%22M204 70C196 54 182 45 164 45C144 45 130 55 120 67C96 88 50 128 22 166Q15 177 28 181L72 177C86 201 108 213 132 213C176 213 206 182 210 140C212 120 210 106 205 98L230.5 88.6Q236 86.4 230.6 84.2Z%22 fill=%22%23FFF4E8%22/%3E%3Ccircle cx=%22146%22 cy=%22149%22 r=%2240%22 fill=%22%23FF5A36%22/%3E%3Ccircle cx=%22177%22 cy=%2280%22 r=%229%22 fill=%22%231A1512%22/%3E%3C/g%3E%3C/svg%3E">
<style>
:root{color-scheme:light;--bg:#fff4e8;--raise:#fffaf4;--pill:#fffaf4;--text:#1a1512;--muted:#6e645c;--faint:#6e645c;--line:rgba(26,21,18,.12);--hover:rgba(26,21,18,.055);--accent:#ff5a36;--accent-hover:#ff6c4b;--accent-text:#c93a1e;--on-accent:#1a1512;--stage:#0e0b0a;--ring:0 0 0 1px rgba(60,40,20,.07);--lift:0 1px 2px rgba(60,40,20,.05),0 18px 50px -24px rgba(60,40,20,.35)}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){color-scheme:dark;--bg:#1a1512;--raise:#2a2320;--pill:#3a322d;--text:#fff4e8;--muted:#a69c93;--faint:#a69c93;--line:rgba(255,244,232,.12);--hover:rgba(255,244,232,.06);--accent:#ff5a36;--accent-hover:#ff6c4b;--accent-text:#ff5a36;--on-accent:#1a1512;--stage:#0e0b0a;--ring:0 0 0 1px rgba(255,236,214,.07);--lift:0 24px 70px -30px rgba(0,0,0,.8)}}
:root[data-theme=dark]{color-scheme:dark;--bg:#1a1512;--raise:#2a2320;--pill:#3a322d;--text:#fff4e8;--muted:#a69c93;--faint:#a69c93;--line:rgba(255,244,232,.12);--hover:rgba(255,244,232,.06);--accent:#ff5a36;--accent-hover:#ff6c4b;--accent-text:#ff5a36;--on-accent:#1a1512;--stage:#0e0b0a;--ring:0 0 0 1px rgba(255,236,214,.07);--lift:0 24px 70px -30px rgba(0,0,0,.8)}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%;text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;-webkit-font-smoothing:antialiased;min-height:100vh;display:flex;flex-direction:column}
main{width:100%;max-width:1120px;margin:0 auto;padding:clamp(16px,4vw,40px) clamp(16px,3vw,32px) 24px;flex:1}
.views{display:flex;justify-content:center;margin:0 auto 18px}
.seg{display:inline-flex;gap:2px;padding:3px;border-radius:999px;background:var(--hover);box-shadow:inset 0 0 0 1px var(--line)}
.seg button{appearance:none;margin:0;border:0;display:inline-flex;align-items:center;justify-content:center;height:30px;padding:0 16px;border-radius:999px;background:none;color:var(--muted);font:inherit;font-size:14px;font-weight:560;line-height:1;white-space:nowrap;cursor:pointer;transition:background-color .15s,color .15s,box-shadow .15s;-webkit-tap-highlight-color:transparent}
.seg button:hover{color:var(--text)}
.seg button[aria-selected=true]{background:var(--pill);color:var(--text);box-shadow:var(--ring),0 1px 3px rgba(40,25,10,.14)}
.views[hidden],.seg button[hidden],.stage[hidden],.guide[hidden],.demo[hidden]{display:none}
.stage{position:relative;width:min(100%,calc(76vh * {{RATIO_N}}));aspect-ratio:{{RATIO}};margin:0 auto;background:var(--stage);border-radius:14px;overflow:hidden;box-shadow:var(--ring),var(--lift)}
video{display:block;width:100%;height:100%;object-fit:contain;background:var(--stage)}
video::cue{background:rgba(12,10,9,.78);color:#f7f2eb;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Roboto,sans-serif;line-height:1.35}
.veil{position:absolute;inset:0;display:grid;place-content:center;justify-items:center;gap:6px;padding:24px;text-align:center;color:#fff4e8;background:radial-gradient(120% 90% at 18% 0%,rgba(255,90,54,.12),transparent 55%),var(--stage)}
.veil[hidden]{display:none}
.veil h2{margin:10px 0 0;font-size:17px;font-weight:600;letter-spacing:-.01em}
.veil p{margin:0;max-width:34ch;color:rgba(255,244,232,.62);font-size:14px}
.veil .mark{width:44px;height:44px;border-radius:50%;display:grid;place-items:center;background:rgba(255,90,54,.14);color:var(--accent)}
.veil .btn{margin-top:14px}
.tl{position:absolute;z-index:2;overflow:hidden;cursor:text;color:transparent;line-height:1;white-space:pre;-webkit-user-select:text;user-select:text}
.tl[hidden],.tl-bar[hidden]{display:none}
.tl span{position:absolute;transform-origin:0 0;border-radius:2px}
.tl span:hover{background:rgba(255,90,54,.1)}
.tl ::selection{background:rgba(255,90,54,.42);color:transparent}
.tl.reveal span{animation:reveal 1.2s ease-out}
@keyframes reveal{0%{background:rgba(255,90,54,0)}22%{background:rgba(255,90,54,.24)}100%{background:rgba(255,90,54,0)}}
.tl-bar{position:absolute;z-index:3;left:50%;bottom:12px;transform:translateX(-50%);display:flex;align-items:center;gap:4px;max-width:calc(100% - 24px);padding:4px 4px 4px 14px;border-radius:999px;background:rgba(26,21,18,.94);color:#fff4e8;font-size:13.5px;white-space:nowrap;box-shadow:0 0 0 1px rgba(255,244,232,.1),0 14px 34px -14px rgba(0,0,0,.75)}
.tl-msg{min-width:0;overflow:hidden;text-overflow:ellipsis;padding-right:8px;color:rgba(255,244,232,.72)}
.tl-bar .btn{height:30px;padding:0 13px;border:0;background:rgba(255,244,232,.1);color:#fff4e8;font-size:13.5px}
.tl-bar .btn:hover{background:rgba(255,244,232,.18)}
.tl-bar .btn.primary{background:#fff4e8;color:#1a1512}
.tl-bar .btn.primary:hover{background:#fff}
.tl-bar.empty .btn:not(.primary){display:none}
.bar{display:flex;flex-wrap:wrap;align-items:flex-start;justify-content:space-between;gap:14px 24px;max-width:calc(76vh * {{RATIO_N}});margin:22px auto 0}
.info{min-width:0;flex:1 1 320px}
h1{margin:0;font-size:clamp(20px,2.3vw,25px);line-height:1.25;font-weight:650;letter-spacing:-.018em;text-wrap:balance;overflow-wrap:anywhere}
.sub{margin-top:5px;display:flex;flex-wrap:wrap;align-items:center;gap:6px 10px;color:var(--muted);font-size:14px;font-variant-numeric:tabular-nums}
.live{display:inline-flex;align-items:center;gap:7px;color:var(--accent-text);font-weight:600}
.live::before{content:"";width:7px;height:7px;border-radius:50%;background:currentColor;animation:breathe 2.4s ease-in-out infinite}
.live[hidden]{display:none}
@keyframes breathe{50%{opacity:.35}}
.actions{display:flex;flex-wrap:wrap;gap:8px}
.btn{appearance:none;display:inline-flex;align-items:center;justify-content:center;gap:7px;height:36px;padding:0 15px;border-radius:999px;border:1px solid var(--line);background:var(--raise);color:var(--text);font:inherit;font-size:14px;font-weight:560;line-height:1;white-space:nowrap;cursor:pointer;text-decoration:none;transition:background-color .15s,border-color .15s,color .15s;-webkit-tap-highlight-color:transparent}
.btn:hover{background:color-mix(in srgb,var(--raise),var(--text) 6%)}
.btn:active{transform:translateY(.5px)}
.btn:focus-visible,.chapters button:focus-visible,.foot a:focus-visible,.foot button:focus-visible,.seg button:focus-visible,.play:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.btn:disabled{opacity:.45;cursor:default;transform:none}
.btn svg{width:16px;height:16px;flex:none}
.btn.primary{background:var(--accent);border-color:transparent;color:var(--on-accent)}
.btn.primary:hover{background:var(--accent-hover)}
.btn.speed{min-width:56px;font-variant-numeric:tabular-nums}
.btn.round{width:36px;padding:0}
.btn[aria-pressed=true]{color:var(--accent-text);border-color:color-mix(in srgb,var(--accent),transparent 45%);background:color-mix(in srgb,var(--raise),var(--accent) 9%)}
.btn[hidden]{display:none}
.chapters{max-width:calc(76vh * {{RATIO_N}});margin:30px auto 0}
.chapters[hidden]{display:none}
.chapters h2{margin:0 0 6px;font-size:14px;font-weight:600;color:var(--muted)}
.chapters ol{list-style:none;margin:0;padding:0;border-top:1px solid var(--line)}
.chapters li{border-bottom:1px solid var(--line)}
.chapters button{all:unset;box-sizing:border-box;display:grid;grid-template-columns:64px 1fr;align-items:baseline;gap:12px;width:100%;padding:11px 10px;border-radius:8px;cursor:pointer;color:var(--muted)}
.chapters button:hover{background:var(--hover);color:var(--text)}
.chapters time{color:var(--faint);font-variant-numeric:tabular-nums;font-size:14px}
.chapters li.on button{color:var(--text)}
.chapters li.on time{color:var(--accent-text)}
body[data-view=guide] .chapters,body[data-view=demo] .chapters,body[data-view=guide] #speed,body[data-view=demo] #speed,body[data-view=guide] #cc,body[data-view=demo] #cc{display:none}
body[data-view=guide] .bar{max-width:820px}
body[data-view=demo] .bar{max-width:calc(64vh * var(--demo-ar,{{RATIO_N}}))}
.guide{max-width:820px;margin:34px auto 0}
.guide h2{margin:0 0 22px;padding-top:28px;border-top:1px solid var(--line);font-size:17px;line-height:1.35;font-weight:650;letter-spacing:-.012em;overflow-wrap:anywhere}
.guide h2:first-child{padding-top:0;border-top:0}
.steps{list-style:none;margin:0 0 12px;padding:0}
.step{position:relative;display:grid;grid-template-columns:28px minmax(0,1fr);column-gap:16px;padding-bottom:40px}
.step::before{content:"";position:absolute;left:13.5px;top:36px;bottom:8px;width:1px;background:var(--line)}
.step:last-child::before{display:none}
.num{width:28px;height:28px;border-radius:50%;display:grid;place-items:center;background:var(--raise);box-shadow:inset 0 0 0 1px var(--line);font-size:13px;font-weight:620;font-variant-numeric:tabular-nums;color:var(--text)}
.step .body{display:grid;grid-template-columns:minmax(0,1fr) auto;column-gap:24px;align-items:baseline;min-width:0;padding-top:3px}
.step .body>*{grid-column:1 / -1}
.step .body>.say{grid-column:1;grid-row:1}
.step .body>.play{grid-column:2;grid-row:1}
.say{margin:0;min-width:0;font-size:16px;line-height:22px;font-weight:500;letter-spacing:-.006em;overflow-wrap:anywhere}
.say strong{font-weight:680}
.play{appearance:none;margin:0;border:0;padding:0;background:none;display:inline-flex;align-items:center;gap:6px;color:var(--muted);font:inherit;font-size:13.5px;line-height:22px;white-space:nowrap;cursor:pointer;border-radius:4px;-webkit-tap-highlight-color:transparent}
.play:hover{color:var(--text)}
.play svg{width:9px;height:9px;flex:none}
.play time{color:var(--faint);font-variant-numeric:tabular-nums}
.play:hover time{color:inherit}
.note{margin:4px 0 0;color:var(--muted);font-size:14.5px;line-height:1.55;overflow-wrap:anywhere}
.shot{position:relative;width:min(100%,calc(70vh * var(--ar,1.6)));margin:16px 0 0;border-radius:10px;overflow:hidden;background:var(--hover);box-shadow:var(--ring),0 1px 2px rgba(40,25,10,.06),0 14px 34px -22px rgba(40,25,10,.4)}
.shot img{display:block;width:100%;height:auto}
.shot.broken img{visibility:hidden}
.shot.broken::after{content:"Image unavailable";position:absolute;inset:0;display:grid;place-items:center;color:var(--muted);font-size:13.5px}
.ring{position:absolute;width:clamp(22px,4.2%,38px);aspect-ratio:1;border-radius:50%;transform:translate(-50%,-50%);border:2.5px solid var(--accent);box-shadow:0 0 0 4px rgba(255,90,54,.22),0 1px 8px rgba(0,0,0,.28);pointer-events:none}
.box{position:absolute;border-radius:6px;background:rgba(255,90,54,.05);box-shadow:0 0 0 1.5px rgba(255,90,54,.9),0 0 0 5px rgba(255,90,54,.14);pointer-events:none}
.cap{position:absolute;left:50%;bottom:7%;transform:translateX(-50%);display:flex;gap:5px;padding:6px;border-radius:11px;background:rgba(20,16,14,.88);box-shadow:0 0 0 1px rgba(255,244,232,.1),0 10px 28px -10px rgba(0,0,0,.6)}
.caps{display:inline-flex;gap:4px}
.cap kbd,.caps kbd{min-width:26px;height:26px;padding:0 7px;border:0;border-radius:6px;background:#fff4e8;color:#1a1512;font-size:13px;font-weight:620;box-shadow:inset 0 -2px 0 rgba(26,21,18,.22)}
.ct{width:min(100%,calc(64vh * var(--demo-ar,{{RATIO_N}})));margin:0 auto;border-radius:14px;overflow:hidden;background:var(--raise);box-shadow:var(--ring),var(--lift)}
.ct-stage{position:relative;aspect-ratio:var(--demo-ar,{{RATIO_N}});background:var(--stage);overflow:hidden;-webkit-user-select:none;user-select:none}
.ct-stage img{position:absolute;inset:0;display:block;width:100%;height:100%}
.ct-stage.blank img{visibility:hidden}
.ct-stage.keystep::after,.ct-stage.done::after{content:"";position:absolute;inset:0;z-index:1;background:rgba(14,11,10,.4);pointer-events:none}
.ct-stage.done::after{background:rgba(14,11,10,.8)}
.hot{position:absolute;z-index:2;display:block;margin:0;padding:0;transform:translate(-50%,-50%);min-width:16px;min-height:16px;border:2px solid var(--accent);border-radius:9px;background:rgba(255,90,54,.12);color:inherit;font:inherit;cursor:pointer;box-shadow:0 0 0 1px rgba(14,11,10,.28),0 8px 22px -8px rgba(255,90,54,.75);transition:background-color .15s;-webkit-tap-highlight-color:transparent}
.hot[hidden]{display:none}
.hot::after{content:"";position:absolute;inset:-2px;border-radius:inherit;pointer-events:none;animation:hot 1.9s cubic-bezier(.25,.6,.3,1) infinite}
@keyframes hot{0%{box-shadow:0 0 0 0 rgba(255,90,54,.55)}70%,100%{box-shadow:0 0 0 16px rgba(255,90,54,0)}}
.hot:hover{background:rgba(255,90,54,.22)}
.hot:focus-visible{outline:2px solid #fff4e8;outline-offset:3px}
.hot.area::before{content:"";position:absolute;left:50%;top:50%;width:max(100%,44px);height:max(100%,44px);transform:translate(-50%,-50%)}
.hot.dot{width:40px;height:40px;border-radius:50%}
.hot.dot::before{content:"";position:absolute;left:50%;top:50%;width:10px;height:10px;margin:-5px 0 0 -5px;border-radius:50%;background:var(--accent)}
.hot.card{left:50%;top:50%;display:inline-flex;align-items:center;gap:10px;min-width:0;min-height:0;max-width:calc(100% - 32px);padding:12px 16px;border:0;border-radius:14px;background:#1a1512;color:#fff4e8;font-size:15px;font-weight:560;line-height:1.3;text-align:left;box-shadow:0 0 0 1px rgba(255,244,232,.12),0 22px 50px -16px rgba(0,0,0,.75)}
.hot.card:hover{background:#261f1b}
.hot.flash{background:rgba(255,90,54,.36);animation:nudge .5s cubic-bezier(.3,0,.3,1)}
.hot.card.flash{background:#33291f}
@keyframes nudge{35%{transform:translate(-50%,-50%) scale(1.12)}}
.ct-end{position:absolute;inset:0;z-index:3;display:grid;place-content:center;justify-items:center;padding:24px;text-align:center;color:#fff4e8}
.ct-end[hidden]{display:none}
.ct-end .mark{width:44px;height:44px;border-radius:50%;display:grid;place-items:center;background:rgba(255,90,54,.16);color:var(--accent)}
.ct-end h2{margin:12px 0 0;font-size:19px;font-weight:650;letter-spacing:-.012em}
.ct-end .row{display:flex;flex-wrap:wrap;justify-content:center;gap:8px;margin-top:18px}
.ct-end .btn{background:rgba(255,244,232,.1);border-color:rgba(255,244,232,.16);color:#fff4e8}
.ct-end .btn:hover{background:rgba(255,244,232,.17)}
.ct-end .btn.primary{background:var(--accent);border-color:transparent;color:var(--on-accent)}
.ct-end .btn.primary:hover{background:var(--accent-hover)}
.ct-bar{position:relative;padding:16px 16px 16px 20px}
.ct-track{position:absolute;left:0;right:0;top:0;height:2px;background:var(--line)}
.ct-track span{display:block;width:0;height:100%;background:var(--accent);transition:width .35s cubic-bezier(.3,0,.2,1)}
.ct-row{display:flex;align-items:flex-start;justify-content:space-between;gap:16px}
.ct-copy{min-width:0}
.ct-count{margin:0;color:var(--muted);font-size:13px;font-variant-numeric:tabular-nums;overflow-wrap:anywhere}
.ct-say{margin:2px 0 0;font-size:16px;line-height:1.4;font-weight:500;letter-spacing:-.006em;overflow-wrap:anywhere}
.ct-say strong{font-weight:680}
.ct-nav{display:flex;gap:8px;flex:none}
.foot{width:100%;max-width:1120px;margin:0 auto;padding:28px clamp(16px,3vw,32px) max(28px,env(safe-area-inset-bottom));display:flex;align-items:center;justify-content:space-between;gap:16px;color:var(--faint);font-size:13px}
.foot a,.foot button{all:unset;cursor:pointer;color:var(--faint);display:inline-flex;align-items:center;gap:8px;border-radius:4px}
.foot a:hover,.foot button:hover{color:var(--text)}
.foot .dot{width:16px;height:16px;flex:none}
.keys{position:fixed;right:20px;bottom:64px;z-index:5;width:290px;padding:16px 18px;border-radius:14px;background:var(--raise);color:var(--text);box-shadow:var(--ring),0 24px 60px -20px rgba(0,0,0,.45);font-size:13.5px}
.keys[hidden],.keys [hidden]{display:none}
.keys h2{margin:0 0 10px;font-size:14px;font-weight:600}
.keys h3{margin:14px 0 8px;font-size:13px;font-weight:600;color:var(--muted)}
.keys dl{margin:0;display:grid;grid-template-columns:minmax(76px,max-content) 1fr;gap:8px 14px;align-items:center}
.keys dt{display:flex;gap:4px}
.keys dd{margin:0;color:var(--muted)}
kbd{min-width:22px;height:22px;padding:0 6px;display:inline-grid;place-items:center;border-radius:6px;border:1px solid var(--line);border-bottom-width:2px;font:inherit;font-size:12px;color:var(--text)}
.sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}
@media (hover:none){#keys-open{display:none}}
@media (max-width:640px){
main{padding:0 0 16px}
.views{margin:0;padding:12px 16px}
.seg{display:flex;width:100%}
.seg button{flex:1 1 auto;padding:0 10px}
.stage{width:100%;border-radius:0;box-shadow:none}
.bar,.chapters{padding:0 16px;margin-top:16px}
.actions{width:100%;flex-wrap:nowrap}
.actions .btn{flex:none;padding:0 12px}
.actions .btn.grow{flex:1 1 0;min-width:0}
#cc span,#ocr span,.actions.tight #copy span{display:none}
.actions.tight #copy{flex:none}
.guide{padding:0 16px;margin-top:26px}
.step{grid-template-columns:24px minmax(0,1fr);column-gap:12px;padding-bottom:32px}
.step::before{left:11.5px;top:31px}
.num{width:24px;height:24px;font-size:12px}
.step .body{display:block;padding-top:1px}
.step .body>.play{margin-top:6px}
.say{font-size:15.5px}
.shot{margin-top:12px;border-radius:8px}
.ct{width:100%;border-radius:0;box-shadow:none}
.ct-bar{padding:14px 16px}
.hot.dot{width:34px;height:34px}
.hot.card{font-size:14px;padding:10px 14px}
.foot{padding-top:20px}
.foot .tail{display:none}
}
@media (max-width:480px){.tl-bar:not(.empty) .tl-msg{display:none}.tl-bar{padding-left:4px}.tl-bar.empty{padding-left:14px}}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
@media print{
body[data-view=guide]{display:block;min-height:0;background:#fff;color:#1a1512;--bg:#fff;--raise:#fff;--text:#1a1512;--muted:#5e554e;--faint:#5e554e;--line:rgba(26,21,18,.2);--hover:rgba(26,21,18,.04);--ring:0 0 0 1px rgba(26,21,18,.18);color-scheme:light}
body[data-view=guide] .views,body[data-view=guide] .actions,body[data-view=guide] .foot,body[data-view=guide] .keys,body[data-view=guide] .play,body[data-view=guide] .live{display:none!important}
body[data-view=guide] main{max-width:none;padding:0}
body[data-view=guide] .bar,body[data-view=guide] .guide{max-width:none;margin:0 0 28px;padding:0}
body[data-view=guide] .step{break-inside:avoid}
body[data-view=guide] .guide h2{break-after:avoid}
body[data-view=guide] .shot{width:min(100%,calc(62vh * var(--ar,1.6)));box-shadow:none;outline:1px solid rgba(26,21,18,.18)}
body[data-view=guide] .ring,body[data-view=guide] .box,body[data-view=guide] .cap,body[data-view=guide] .num{-webkit-print-color-adjust:exact;print-color-adjust:exact}
}
</style>
</head>
<body>
<main>
<div class="views" id="views" hidden>
<div class="seg" role="tablist" aria-label="View">
<button type="button" role="tab" id="tab-video" data-view="video" aria-controls="stage" aria-selected="true">Video</button>
<button type="button" role="tab" id="tab-guide" data-view="guide" aria-controls="guide-panel" aria-selected="false" tabindex="-1">Guide</button>
<button type="button" role="tab" id="tab-demo" data-view="demo" aria-controls="demo-panel" aria-selected="false" tabindex="-1">Click-through</button>
</div>
</div>
<div class="stage" id="stage">
<video id="v" controls playsinline preload="metadata"{{POSTER}}></video>
<div class="tl" id="tl" role="region" aria-label="Text in this frame" hidden></div>
<div class="tl-bar" id="tl-bar" hidden>
<span class="tl-msg" id="tl-msg"></span>
<button class="btn" id="tl-all" type="button">Copy all</button>
<button class="btn primary" id="tl-done" type="button">Done</button>
</div>
<div class="veil" id="veil" hidden>
<div class="mark" aria-hidden="true"><svg width="20" height="20" viewBox="0 0 20 20" fill="none"><circle cx="10" cy="10" r="4" fill="currentColor"/></svg></div>
<h2 id="veil-title"></h2>
<p id="veil-text"></p>
<button class="btn" id="veil-retry" type="button" hidden>Try again</button>
</div>
</div>
<section class="demo" id="demo-panel" role="tabpanel" aria-labelledby="tab-demo" hidden>
<div class="ct" id="ct">
<div class="ct-stage" id="ct-stage">
<img id="ct-img" alt="" draggable="false">
<button class="hot" id="ct-hot" type="button" hidden></button>
<div class="ct-end" id="ct-end" hidden>
<div class="mark" aria-hidden="true"><svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5.5 10.4 8.6 13.4 14.5 7"/></svg></div>
<h2>All done</h2>
<div class="row">
<button class="btn" id="ct-replay" type="button"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M2.5 8a5.5 5.5 0 1 0 1.6-3.9L2.5 5.6"/><path d="M2.5 2.5v3.1h3.1"/></svg><span>Replay</span></button>
<button class="btn primary" id="ct-watch" type="button"><svg viewBox="0 0 16 16"><path d="M5.2 3.6v8.8a.7.7 0 0 0 1.06.6l6.9-4.4a.7.7 0 0 0 0-1.2L6.26 3a.7.7 0 0 0-1.06.6z" fill="currentColor"/></svg><span>Watch the video</span></button>
</div>
</div>
</div>
<div class="ct-bar">
<div class="ct-track" aria-hidden="true"><span id="ct-fill"></span></div>
<div class="ct-row">
<div class="ct-copy"><p class="ct-count" id="ct-count"></p><p class="ct-say" id="ct-say"></p></div>
<div class="ct-nav">
<button class="btn round" id="ct-back" type="button" aria-label="Previous step"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M9.8 3.5 5.3 8l4.5 4.5"/></svg></button>
<button class="btn" id="ct-next" type="button"><span id="ct-next-label">Next</span><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M6.2 3.5 10.7 8l-4.5 4.5"/></svg></button>
</div>
</div>
</div>
</div>
</section>
<div class="bar">
<div class="info">
<h1 id="title">{{TITLE}}</h1>
<div class="sub"><span id="subline">{{SUBLINE}}</span><span class="live" id="live" hidden>Recording</span></div>
</div>
<div class="actions">
<button class="btn speed" id="speed" type="button" title="Playback speed (&lt; and &gt;)" aria-label="Playback speed 1×">1×</button>
<button class="btn" id="cc" type="button" aria-pressed="false" title="Captions (C)" aria-label="Captions" hidden><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><rect x="1.5" y="3" width="13" height="10" rx="2.2"/><path d="M7 6.7a1.9 1.9 0 1 0 0 2.6M11.6 6.7a1.9 1.9 0 1 0 0 2.6" stroke-linecap="round"/></svg><span>Captions</span></button>
<button class="btn" id="ocr" type="button" aria-pressed="false" title="Copy text (T)" aria-label="Copy text" hidden><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M2.5 5.5V4A1.5 1.5 0 0 1 4 2.5h1.5M10.5 2.5H12A1.5 1.5 0 0 1 13.5 4v1.5M13.5 10.5V12a1.5 1.5 0 0 1-1.5 1.5h-1.5M5.5 13.5H4A1.5 1.5 0 0 1 2.5 12v-1.5"/><path d="M5.5 6.5h5M5.5 9.5h3.2"/></svg><span>Copy text</span></button>
<button class="btn grow" id="copy" type="button"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M6.6 9.4a2.6 2.6 0 0 0 3.7 0l2.4-2.4a2.6 2.6 0 0 0-3.7-3.7l-.6.6"/><path d="M9.4 6.6a2.6 2.6 0 0 0-3.7 0L3.3 9a2.6 2.6 0 0 0 3.7 3.7l.6-.6"/></svg><span>Copy link</span></button>
<button class="btn primary grow" id="download" type="button"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M8 2.5v8M4.8 7.6 8 10.8l3.2-3.2M3 13.5h10"/></svg><span>Download</span></button>
</div>
</div>
<section class="guide" id="guide-panel" role="tabpanel" aria-labelledby="tab-guide" hidden></section>
<section class="chapters" id="chapters" hidden>
<h2>Chapters</h2>
<ol id="chapter-list"></ol>
</section>
</main>
<footer class="foot">
<a href="{{SITE}}" rel="noopener"><svg class="dot" viewBox="8 13 236 236" aria-hidden="true"><path d="M204 70C196 54 182 45 164 45C144 45 130 55 120 67C96 88 50 128 22 166Q15 177 28 181L72 177C86 201 108 213 132 213C176 213 206 182 210 140C212 120 210 106 205 98L230.5 88.6Q236 86.4 230.6 84.2Z" fill="currentColor"/><circle cx="146" cy="149" r="40" fill="#FF5A36"/><circle cx="177" cy="80" r="8" fill="var(--bg)"/></svg><span>Made with Reelbird<span class="tail"> · free screen recorder for Mac</span></span></a>
<button type="button" id="keys-open" aria-expanded="false" aria-controls="keys">Keyboard shortcuts</button>
</footer>
<div class="keys" id="keys" role="dialog" aria-label="Keyboard shortcuts" hidden>
<h2>Keyboard shortcuts</h2>
<dl>
<dt><kbd>Space</kbd><kbd>K</kbd></dt><dd>Play or pause</dd>
<dt><kbd>←</kbd><kbd>→</kbd></dt><dd>Back or forward 5 s</dd>
<dt><kbd>J</kbd><kbd>L</kbd></dt><dd>Back or forward 10 s</dd>
<dt><kbd>&lt;</kbd><kbd>&gt;</kbd></dt><dd>Slower or faster</dd>
<dt><kbd>0</kbd>–<kbd>9</kbd></dt><dd>Jump to 0–90%</dd>
<dt><kbd>F</kbd></dt><dd>Full screen</dd>
<dt><kbd>M</kbd></dt><dd>Mute</dd>
<dt><kbd>C</kbd></dt><dd>Captions</dd>
<dt id="keys-t" hidden><kbd>T</kbd></dt><dd id="keys-t-text" hidden>Copy text in the video</dd>
</dl>
<h3 id="keys-demo-title" hidden>Click-through</h3>
<dl id="keys-demo" hidden>
<dt><kbd>→</kbd><kbd>Enter</kbd></dt><dd>Next step</dd>
<dt><kbd>←</kbd></dt><dd>Previous step</dd>
</dl>
</div>
<div class="sr" aria-live="polite" id="announce"></div>
<template id="icons"><svg class="i-play" viewBox="0 0 16 16" aria-hidden="true"><path d="M4.4 2.6v10.8a.9.9 0 0 0 1.38.76l8.5-5.4a.9.9 0 0 0 0-1.52l-8.5-5.4a.9.9 0 0 0-1.38.76z" fill="currentColor"/></svg></template>
<script type="application/json" id="meta">{{META}}</script>
<script>
(() => {
"use strict";
const $ = id => document.getElementById(id);
const v = $("v"), veil = $("veil");
let meta = JSON.parse($("meta").textContent);
let mode = null, hls = null, hlsLoading = null, pollTimer = null, downloading = false;
const speeds = [1, 1.25, 1.5, 1.75, 2, 0.75];
const store = {
  get(k) { try { return localStorage.getItem("reelbird." + k); } catch (e) { return null; } },
  set(k, val) { try { localStorage.setItem("reelbird." + k, val); } catch (e) {} }
};
const theme = new URLSearchParams(location.search).get("theme");
if (theme === "dark" || theme === "light") document.documentElement.dataset.theme = theme;

const abs = name => name ? meta.baseURL + name : null;
const fmt = s => {
  s = Math.max(0, Math.round(s || 0));
  const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), sec = s % 60;
  return (h ? h + ":" + String(m).padStart(2, "0") : m) + ":" + String(sec).padStart(2, "0");
};
const say = t => { $("announce").textContent = t; };
const plural = (n, word) => n + " " + word + (n === 1 ? "" : "s");
// Builds an element; text only ever goes in as text.
const el = (tag, cls, text) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined) n.textContent = text;
  return n;
};
const icon = name => $("icons").content.querySelector(".i-" + name).cloneNode(true);
// The meta and the text layer are untrusted: file names must look like files in this share (the
// server's ASSET rule), numbers are clamped, strings are capped.
const ASSET = /^[A-Za-z0-9][A-Za-z0-9._-]{0,80}(\/[A-Za-z0-9][A-Za-z0-9._-]{0,80}){0,2}$/;
const TEXT_LAYER = /^text\.\d+\.json$/;
const asset = s => (typeof s === "string" && ASSET.test(s) && s.indexOf("..") < 0 ? s : null);
const num = (x, lo, hi) => (typeof x === "number" && Number.isFinite(x) ? Math.min(hi, Math.max(lo, x)) : null);
// An image size outside 1…16384 px is no size (as on the server).
const pixels = x => (num(x, 0, 16385) === x && x >= 1 && x <= 16384 ? Math.round(x) : null);
const str = (x, max) => (typeof x === "string" ? x.slice(0, max).trim() : "");
const pct = x => (x * 100).toFixed(3) + "%";

function showVeil(title, text, retry) {
  $("veil-title").textContent = title;
  $("veil-text").textContent = text || "";
  $("veil-retry").hidden = !retry;
  veil.hidden = false;
}
const hideVeil = () => { veil.hidden = true; };

function renderInfo() {
  document.title = meta.title;
  $("title").textContent = meta.title;
  renderGuideState();
  renderSub();
  const live = $("live");
  live.hidden = meta.status === "ready";
  live.textContent = meta.status === "recording" ? "Recording" : "Finishing upload";
  const dl = $("download");
  const canDownload = !!meta.video || (!!meta.hls && meta.status === "ready");
  dl.disabled = !canDownload || downloading;
  dl.title = canDownload ? "Download MP4" : "Available when the recording ends";
  dl.hidden = !canDownload && steps.length > 0 && meta.status === "ready"; // a guide with no video
  $("copy").hidden = !/^https?:\/\//i.test(meta.pageURL || "");
  renderCaptions();
  renderChapters();
  renderTextButton();
}

function renderSub() {
  const parts = [];
  if (view === "guide" && steps.length) parts.push(plural(steps.length, "step"));
  else if (meta.duration && meta.status === "ready") parts.push(fmt(meta.duration));
  try {
    parts.push(new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", year: "numeric" }).format(new Date(meta.createdAt)));
  } catch (e) {}
  $("subline").textContent = parts.join(" · ");
}

// Playback source: the polished MP4 when present, else the HLS share stream.
function attach() {
  attachSource();
  renderTextButton();
}
function attachSource() {
  if (meta.video) {
    if (mode === "mp4") return;
    const t = v.currentTime, playing = !v.paused;
    if (mode === "hls" && playing) return; // don't yank a playing video; switch on next load
    destroyHls();
    v.src = abs(meta.video);
    mode = "mp4";
    if (t > 0) v.addEventListener("loadedmetadata", () => { v.currentTime = t; }, { once: true });
    hideVeil();
  } else if (meta.hls) {
    if (mode === "hls") return;
    mode = "hls";
    hideVeil();
    attachHls(abs(meta.hls));
  } else if (meta.status === "ready") {
    if (steps.length) hideVeil(); // a guide without video: the page opens on the guide
    else showVeil("No video in this recording", "The recording ended before any video was captured.");
  } else {
    showVeil("Recording just started", "The video will appear here in a few seconds.");
  }
}

const isSafari = /^((?!chrome|chromium|crios|fxios|edg|android).)*safari/i.test(navigator.userAgent);
function attachHls(url) {
  const mse = window.ManagedMediaSource || window.MediaSource;
  if ((isSafari && v.canPlayType("application/vnd.apple.mpegurl")) || !mse) {
    v.src = url;
    v.addEventListener("loadedmetadata", () => { if (v.currentTime > 1 && v.played.length === 0) v.currentTime = 0; }, { once: true });
    return;
  }
  hlsLoading = hlsLoading || new Promise((resolve, reject) => {
    const s = document.createElement("script");
    s.src = "{{HLS_URL}}";
    s.integrity = "{{HLS_SRI}}";
    s.crossOrigin = "anonymous";
    s.onload = resolve;
    s.onerror = () => reject(new Error("player"));
    document.head.appendChild(s);
  });
  hlsLoading.then(() => {
    if (mode !== "hls") return;
    if (!window.Hls || !Hls.isSupported()) { v.src = url; return; }
    hls = new Hls({ startPosition: 0, enableWorker: true, maxBufferLength: 30 });
    let mediaRetries = 0;
    hls.on(Hls.Events.ERROR, (_, d) => {
      if (!d.fatal) return;
      if (d.type === Hls.ErrorTypes.NETWORK_ERROR) setTimeout(() => hls && hls.startLoad(), 2000);
      else if (d.type === Hls.ErrorTypes.MEDIA_ERROR && mediaRetries++ < 3) hls.recoverMediaError();
      else { destroyHls(); mode = null; renderTextButton(); showVeil("This video couldn't be played", "Check your connection and try again.", true); }
    });
    hls.loadSource(url);
    hls.attachMedia(v);
  }).catch(() => { v.src = url; });
}
function destroyHls() { if (hls) { hls.destroy(); hls = null; } }

v.addEventListener("error", () => {
  if (mode === "mp4" || (mode === "hls" && !hls)) {
    mode = null;
    renderTextButton();
    showVeil("This video couldn't be played", "Check your connection and try again.", true);
  }
});
$("veil-retry").addEventListener("click", () => { mode = null; destroyHls(); v.removeAttribute("src"); v.load(); attach(); });

// While recording, poll meta.json for the first segment and for the end.
async function poll() {
  try {
    const r = await fetch(meta.baseURL + "meta.json?t=" + Date.now(), { cache: "no-store" });
    if (r.ok) {
      const next = await r.json();
      const changed = JSON.stringify(next) !== JSON.stringify(meta);
      meta = next;
      if (changed) { renderInfo(); attach(); }
      if (meta.status === "ready") {
        say("Recording finished");
        if (meta.video && mode === "hls" && v.paused) { mode = null; attach(); }
        return;
      }
    }
  } catch (e) {}
  pollTimer = setTimeout(poll, meta.hls ? 4000 : 2000);
}

// Speed
let speedIndex = Math.max(0, speeds.indexOf(Number(store.get("speed")) || 1));
function setSpeed(i) {
  speedIndex = (i + speeds.length) % speeds.length;
  const s = speeds[speedIndex];
  v.playbackRate = s; v.defaultPlaybackRate = s;
  $("speed").textContent = s + "×";
  $("speed").setAttribute("aria-label", "Playback speed " + s + "×");
  store.set("speed", String(s));
}
const stepSpeed = dir => {
  const sorted = speeds.slice().sort((a, b) => a - b);
  const cur = sorted.indexOf(speeds[speedIndex]);
  const next = sorted[Math.min(sorted.length - 1, Math.max(0, cur + dir))];
  setSpeed(speeds.indexOf(next)); say("Speed " + next + "×");
};
$("speed").addEventListener("click", () => setSpeed(speedIndex + 1));
v.addEventListener("loadedmetadata", () => { v.playbackRate = speeds[speedIndex]; });

// Captions
let track = null;
function renderCaptions() {
  const src = abs(meta.captions);
  $("cc").hidden = !src;
  if (!src || (track && track.dataset.src === src)) return;
  if (track) track.remove();
  track = document.createElement("track");
  track.kind = "captions"; track.label = "Captions"; track.srclang = meta.captionsLanguage || "en";
  track.src = src; track.dataset.src = src;
  v.appendChild(track);
  setCaptions(store.get("captions") === "on");
}
function setCaptions(on) {
  if (!track) return;
  track.track.mode = on ? "showing" : "hidden";
  $("cc").setAttribute("aria-pressed", on ? "true" : "false");
  store.set("captions", on ? "on" : "off");
}
$("cc").addEventListener("click", () => setCaptions(track && track.track.mode !== "showing"));

// Chapters
let chapterKey = "";
function renderChapters() {
  const list = meta.chapters || [];
  const key = JSON.stringify(list);
  if (key === chapterKey) return;
  chapterKey = key;
  $("chapters").hidden = list.length === 0;
  const ol = $("chapter-list");
  ol.textContent = "";
  list.forEach(c => {
    const li = document.createElement("li");
    const b = document.createElement("button");
    b.type = "button";
    const t = document.createElement("time");
    t.textContent = fmt(c.time);
    const s = document.createElement("span");
    s.textContent = c.title;
    b.append(t, s);
    b.addEventListener("click", () => { v.currentTime = c.time; v.play().catch(() => {}); });
    li.appendChild(b);
    ol.appendChild(li);
  });
}
v.addEventListener("timeupdate", () => {
  const list = meta.chapters || [];
  if (!list.length) return;
  let on = -1;
  list.forEach((c, i) => { if (v.currentTime + 0.25 >= c.time) on = i; });
  [...$("chapter-list").children].forEach((li, i) => li.classList.toggle("on", i === on));
});

// Views: Video, Guide and Click-through, when the share has a guide. #guide and #demo link to them.
const KINDS = ["click", "doubleClick", "rightClick", "drag", "type", "shortcut", "key"];
const tabs = Array.from(document.querySelectorAll("#views [role=tab]"));
const panels = { video: $("stage"), guide: $("guide-panel"), demo: $("demo-panel") };
let steps = [], stepsKey = null, guideKey = null, view = "video";
const hasVideo = () => !!(meta.video || meta.hls) || meta.status !== "ready";
const canView = name => (name === "video" ? hasVideo() : steps.length > 0);
const hashView = () => { const h = location.hash.slice(1); return h === "guide" || h === "demo" ? h : null; };
const firstView = () => hashView() || (hasVideo() ? "video" : "guide");

function readSteps() {
  const g = meta.guide;
  const list = g && typeof g === "object" && Array.isArray(g.steps) ? g.steps.slice(0, 300) : [];
  const out = [];
  for (const s of list) {
    if (!s || typeof s !== "object") continue;
    const text = str(s.text, 500);
    if (!text) continue;
    let x = num(s.x, 0, 1), y = num(s.y, 0, 1);
    if (x === null || y === null) x = y = null;
    let box = null;
    if (s.box && typeof s.box === "object") {
      const bx = num(s.box.x, 0, 1), by = num(s.box.y, 0, 1);
      const bw = bx === null ? null : num(s.box.width, 0, 1 - bx), bh = by === null ? null : num(s.box.height, 0, 1 - by);
      if (bw && bh) box = { x: bx, y: by, w: bw, h: bh };
    }
    const w = pixels(s.w), h = pixels(s.h);
    out.push({
      t: num(s.t, 0, 1e6),
      kind: KINDS.indexOf(s.kind) >= 0 ? s.kind : "click",
      text, note: str(s.note, 1000), section: str(s.section, 200),
      image: asset(s.image),
      w, h, ar: w && h ? Math.min(6, Math.max(1 / 6, w / h)) : null,
      x, y, box, keys: str(s.keys, 40)
    });
  }
  return out;
}

function renderGuideState() {
  const key = JSON.stringify(meta.guide || null);
  if (key === stepsKey) return;
  stepsKey = key;
  steps = readSteps();
  guideKey = null;
  $("views").hidden = !steps.length;
  $("keys-demo").hidden = $("keys-demo-title").hidden = !steps.length;
  if (ct.i >= steps.length) { ct.i = 0; ct.end = false; }
  if (steps.length) {
    panels.video.setAttribute("role", "tabpanel");
    panels.video.setAttribute("aria-labelledby", "tab-video");
    if (document.body.dataset.view) setView(view, true);
  } else {
    view = "video";
    delete document.body.dataset.view;
    panels.video.removeAttribute("role");
    panels.video.removeAttribute("aria-labelledby");
    panels.video.hidden = false;
    panels.guide.hidden = panels.demo.hidden = true;
  }
}

function setView(name, fromHash) {
  if (!steps.length) return;
  if (!canView(name)) name = hasVideo() ? "video" : "guide";
  if (name !== "video") { stopText(); if (!v.paused) v.pause(); }
  view = name;
  document.body.dataset.view = name;
  for (const t of tabs) {
    const on = t.dataset.view === name;
    t.hidden = !canView(t.dataset.view);
    t.setAttribute("aria-selected", on ? "true" : "false");
    t.tabIndex = on ? 0 : -1;
  }
  for (const k in panels) panels[k].hidden = k !== name;
  if (name === "guide") buildGuide();
  if (name === "demo") renderDemo();
  if (!fromHash) {
    try { history.replaceState(history.state, "", location.pathname + location.search + (name === "video" ? "" : "#" + name)); } catch (e) {}
  }
  renderSub();
  renderTextButton();
}
// A click (not a key press) on Click-through hands the keys to the demo, so → and Enter step through it
// instead of moving between tabs.
tabs.forEach(t => t.addEventListener("click", e => {
  setView(t.dataset.view);
  if (e.detail > 0 && view === "demo") { try { $("ct-next").focus({ preventScroll: true }); } catch (err) {} }
}));
window.addEventListener("hashchange", () => { if (steps.length) setView(firstView(), true); });
function tabKey(e) {
  const shown = tabs.filter(t => !t.hidden), i = shown.indexOf(e.target);
  let j = -1;
  if (e.key === "ArrowRight") j = (i + 1) % shown.length;
  else if (e.key === "ArrowLeft") j = (i - 1 + shown.length) % shown.length;
  else if (e.key === "Home") j = 0;
  else if (e.key === "End") j = shown.length - 1;
  if (i < 0 || j < 0) return false;
  shown[j].focus();
  setView(shown[j].dataset.view);
  return true;
}

// The first quoted label ("Inbox" or “Inbox”) in bold.
function instruction(node, text) {
  const m = /"[^"\n]+"|“[^”\n]+”/.exec(text);
  if (!m) { node.append(document.createTextNode(text)); return node; }
  node.append(document.createTextNode(text.slice(0, m.index)), el("strong", "", m[0]),
    document.createTextNode(text.slice(m.index + m[0].length)));
  return node;
}
// "⌘⇧S" as ⌘ ⇧ S keys; "Return" as one key.
function keycaps(keys, cls) {
  const wrap = el("span", cls);
  let rest = keys;
  while (rest.length > 1 && "⌘⌃⌥⇧".indexOf(rest[0]) >= 0) { wrap.append(el("kbd", "", rest[0])); rest = rest.slice(1); }
  if (rest) wrap.append(el("kbd", "", rest));
  return wrap;
}
function sectionAt(i) {
  for (let j = i; j >= 0; j--) if (steps[j].section) return steps[j].section;
  return "";
}

// Guide: an ordered list of steps with section headings, each with its image.
function buildGuide() {
  const key = stepsKey + "|" + meta.baseURL + "|" + !!(meta.video || meta.hls);
  if (key === guideKey) return;
  guideKey = key;
  const root = panels.guide, lazy = steps.length > 24;
  root.textContent = "";
  let list = null;
  steps.forEach((s, i) => {
    if (s.section || !list) {
      if (s.section) root.append(el("h2", "", s.section));
      list = el("ol", "steps");
      list.setAttribute("role", "list");
      list.start = i + 1;
      root.append(list);
    }
    list.append(guideStep(s, i, lazy));
  });
}
// A step: its number, the instruction, the note, "Play from here" (top right on wide screens) and the image.
function guideStep(s, i, lazy) {
  const li = el("li", "step"), n = el("span", "num", String(i + 1)), body = el("div", "body");
  n.setAttribute("aria-hidden", "true");
  const p = el("p", "say");
  p.append(el("span", "sr", "Step " + (i + 1) + ": "));
  body.append(instruction(p, s.text));
  if (s.note) body.append(el("p", "note", s.note));
  if ((meta.video || meta.hls) && s.t !== null) {
    const b = el("button", "play");
    b.type = "button";
    b.setAttribute("aria-label", "Play from here, step " + (i + 1) + " at " + fmt(s.t));
    b.append(icon("play"), el("span", "", "Play from here"), el("time", "", fmt(s.t)));
    b.addEventListener("click", () => playFrom(s.t));
    body.append(b);
  }
  if (s.image) body.append(shot(s, lazy));
  li.append(n, body);
  return li;
}
function shot(s, lazy) {
  const f = el("figure", "shot"), img = el("img");
  if (s.ar) f.style.setProperty("--ar", s.ar.toFixed(4));
  img.alt = "";
  img.decoding = "async";
  if (lazy) img.loading = "lazy";
  if (s.w && s.h) { img.width = s.w; img.height = s.h; }
  img.addEventListener("load", () => {
    if (!s.ar && img.naturalWidth && img.naturalHeight) f.style.setProperty("--ar", (img.naturalWidth / img.naturalHeight).toFixed(4));
  }, { once: true });
  img.addEventListener("error", () => f.classList.add("broken"), { once: true });
  img.src = abs(s.image);
  f.append(img);
  if (s.box) {
    const b = el("span", "box");
    b.style.left = "calc(" + pct(s.box.x) + " - 4px)";
    b.style.top = "calc(" + pct(s.box.y) + " - 4px)";
    b.style.width = "calc(" + pct(s.box.w) + " + 8px)";
    b.style.height = "calc(" + pct(s.box.h) + " + 8px)";
    f.append(b);
  }
  if (s.x !== null) {
    const r = el("span", "ring");
    r.style.left = pct(s.x);
    r.style.top = pct(s.y);
    f.append(r);
  } else if (s.keys) f.append(keycaps(s.keys, "cap"));
  return f;
}
function playFrom(t) {
  setView("video");
  const go = () => {
    v.currentTime = Math.min(t, Number.isFinite(v.duration) ? Math.max(0, v.duration - 0.05) : t);
    v.play().catch(() => {});
  };
  if (v.readyState >= 1) go(); else v.addEventListener("loadedmetadata", go, { once: true });
  window.scrollTo(0, 0);
  try { v.focus({ preventScroll: true }); } catch (e) {}
}
window.addEventListener("beforeprint", () => {
  if (view === "guide") for (const img of panels.guide.querySelectorAll("img")) img.loading = "eager";
});

// Click-through: the viewer clicks the highlighted spot (or Next, Enter, →) to go on.
const ct = { i: 0, end: false, token: 0, ready: null, flash: 0, pre: {} };
const ctStage = $("ct-stage"), ctImg = $("ct-img"), hot = $("ct-hot");
ctImg.addEventListener("load", () => settled(false));
ctImg.addEventListener("error", () => settled(true));
function settled(failed) { const f = ct.ready; ct.ready = null; if (f) f(failed); }
// The image's aspect ratio sizes the click-through and the title bar under it alike.
const setAr = ar => { if (ar) document.body.style.setProperty("--demo-ar", Math.min(6, Math.max(1 / 6, ar)).toFixed(4)); };

function renderDemo() {
  if (!steps.length) return;
  if (ct.end) showEnd(false); else showStep(ct.i, false);
}
function showStep(i, focus) {
  const a = document.activeElement;
  focus = focus || a === hot || $("ct-end").contains(a);
  ct.end = false;
  ct.i = Math.max(0, Math.min(steps.length - 1, i));
  const s = steps[ct.i], n = steps.length, sec = sectionAt(ct.i);
  $("ct-end").hidden = true;
  ctStage.classList.remove("done", "keystep");
  $("ct-count").textContent = "Step " + (ct.i + 1) + " of " + n + (sec ? " · " + sec : "");
  const p = $("ct-say");
  p.textContent = "";
  instruction(p, s.text);
  $("ct-fill").style.width = pct((ct.i + 1) / n);
  const backBtn = $("ct-back"), nextBtn = $("ct-next");
  nextBtn.hidden = false;
  $("ct-next-label").textContent = ct.i === n - 1 ? "Finish" : "Next";
  if (ct.i === 0 && a === backBtn) nextBtn.focus();
  backBtn.disabled = ct.i === 0;
  hot.hidden = true;
  setAr(s.ar);
  const token = ++ct.token;
  const ready = failed => {
    if (token !== ct.token) return;
    if (!failed && ctImg.naturalWidth && ctImg.naturalHeight) setAr(ctImg.naturalWidth / ctImg.naturalHeight);
    ctStage.classList.toggle("blank", !!failed);
    placeHot(s, !!failed);
    if (focus) hot.focus({ preventScroll: true });
  };
  const url = s.image ? abs(s.image) : null;
  if (!url) { ct.ready = null; ctImg.removeAttribute("src"); ready(true); }
  else if (ctImg.getAttribute("src") === url && ctImg.complete && ctImg.naturalWidth) { ct.ready = null; ready(false); }
  else { ct.ready = ready; ctImg.src = url; }
  preload(ct.i + 1);
  say("Step " + (ct.i + 1) + " of " + n + ": " + s.text);
}
// Whether the click landed beside its label (a checkbox next to its text), as the app decides it.
function beside(s) {
  if (s.x === null || !s.box) return false;
  const b = s.box, slack = Math.max(0.004, b.h * 0.5);
  return s.x < b.x - slack || s.x > b.x + b.w + slack || s.y < b.y - slack || s.y > b.y + b.h + slack;
}
// The hotspot: the clicked label's box, a circle at the click, or a centred card for keys.
function placeHot(s, card) {
  hot.className = "hot";
  hot.textContent = "";
  hot.style.cssText = "";
  hot.removeAttribute("aria-label");
  if (!card && s.box && !beside(s)) {
    hot.classList.add("area");
    hot.style.left = pct(s.box.x + s.box.w / 2);
    hot.style.top = pct(s.box.y + s.box.h / 2);
    hot.style.width = "calc(" + pct(s.box.w) + " + 10px)";
    hot.style.height = "calc(" + pct(s.box.h) + " + 10px)";
    hot.setAttribute("aria-label", s.text);
  } else if (!card && s.x !== null) {
    hot.classList.add("dot");
    hot.style.left = pct(s.x);
    hot.style.top = pct(s.y);
    hot.setAttribute("aria-label", s.text);
  } else {
    hot.classList.add("card");
    ctStage.classList.add("keystep");
    if (s.keys) {
      hot.append(el("span", "", "Press"), keycaps(s.keys, "caps"));
      hot.setAttribute("aria-label", "Press " + s.keys);
    } else hot.append(el("span", "", s.text));
  }
  hot.hidden = false;
}
function showEnd(focus) {
  ct.end = true;
  ct.token++;
  ct.ready = null;
  hot.hidden = true;
  ctStage.classList.remove("keystep", "blank");
  ctStage.classList.add("done");
  $("ct-end").hidden = false;
  $("ct-watch").hidden = !(meta.video || meta.hls);
  $("ct-count").textContent = "Finished";
  $("ct-say").textContent = "You went through all " + plural(steps.length, "step") + ".";
  $("ct-fill").style.width = "100%";
  $("ct-back").disabled = false;
  $("ct-next").hidden = true;
  say("All done. You went through all " + plural(steps.length, "step") + ".");
  if (focus) $("ct-replay").focus();
}
function next() {
  if (ct.end || !steps.length) return;
  if (ct.i < steps.length - 1) { showStep(ct.i + 1, false); return; }
  const a = document.activeElement;
  showEnd(a === hot || a === $("ct-next") || a === document.body || !a);
}
function back() {
  if (!steps.length) return;
  if (ct.end) showStep(steps.length - 1, false);
  else if (ct.i > 0) showStep(ct.i - 1, false);
}
function flash() {
  if (hot.hidden) return;
  hot.classList.remove("flash");
  void hot.offsetWidth;
  hot.classList.add("flash");
  clearTimeout(ct.flash);
  ct.flash = setTimeout(() => hot.classList.remove("flash"), 700);
}
function preload(i) {
  const s = steps[i];
  if (!s || !s.image || ct.pre[s.image]) return;
  const im = new Image();
  im.decoding = "async";
  im.src = abs(s.image);
  ct.pre[s.image] = im;
}
hot.addEventListener("click", e => { e.stopPropagation(); next(); });
ctStage.addEventListener("click", e => {
  if (ct.end || hot.contains(e.target) || $("ct-end").contains(e.target)) return;
  flash(); // a click that missed: show where to click
});
$("ct-next").addEventListener("click", next);
$("ct-back").addEventListener("click", back);
$("ct-replay").addEventListener("click", () => showStep(0, true));
$("ct-watch").addEventListener("click", () => {
  setView("video");
  v.currentTime = 0;
  v.play().catch(() => {});
  try { v.focus({ preventScroll: true }); } catch (e) {}
});

// Copy text: the text read from the video, laid over the paused frame as selectable spans.
const tl = { on: false, name: null, data: null, loading: null, frame: null, token: 0 };
const layer = $("tl"), tlBar = $("tl-bar"), tlMsg = $("tl-msg"), ocr = $("ocr");
const FONT = '-apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif';
let measure = null;
layer.style.fontFamily = FONT;
const textLayerName = () => { const n = asset(meta.text); return n && TEXT_LAYER.test(n) ? n : null; };
const textOK = () => view === "video" && mode === "mp4" && !!textLayerName();
function renderTextButton() {
  const ok = textOK();
  ocr.hidden = !ok;
  $("keys-t").hidden = $("keys-t-text").hidden = !ok;
  ocr.parentNode.classList.toggle("tight", ok && !$("cc").hidden);
  if (!ok) stopText();
}
// Lines in reading order: rows top to bottom (a row shares a centre line), each left to right.
function readingOrder(lines) {
  const rows = [];
  lines.slice().sort((a, b) => (a.y + a.h / 2) - (b.y + b.h / 2)).forEach(l => {
    const c = l.y + l.h / 2, row = rows[rows.length - 1];
    if (row && Math.abs(c - row.c) < Math.min(l.h, row.h) / 2) row.items.push(l);
    else rows.push({ c, h: l.h, items: [l] });
  });
  const out = [];
  rows.forEach(r => r.items.sort((a, b) => a.x - b.x).forEach(l => out.push(l)));
  return out;
}
function parseTextLayer(j) {
  const frames = j && Array.isArray(j.frames) ? j.frames.slice(0, 50000) : [];
  const out = [];
  for (const f of frames) {
    if (!f || typeof f !== "object") continue;
    const start = num(f.start, 0, 1e7), end = num(f.end, 0, 1e7);
    if (start === null || end === null || end <= start) continue;
    const lines = [];
    for (const l of Array.isArray(f.lines) ? f.lines.slice(0, 1000) : []) {
      if (!l || typeof l !== "object" || typeof l.text !== "string" || !l.text.trim()) continue;
      const x = num(l.x, 0, 1), y = num(l.y, 0, 1);
      const w = x === null ? null : num(l.w, 0, 1 - x), h = y === null ? null : num(l.h, 0, 1 - y);
      if (w && h) lines.push({ text: l.text.slice(0, 1000), x, y, w, h });
    }
    out.push({ start, end, lines: readingOrder(lines) });
  }
  out.sort((a, b) => a.start - b.start);
  return { width: num(j && j.width, 1, 65536), height: num(j && j.height, 1, 65536), frames: out };
}
function frameAt(t) {
  const fs = tl.data.frames;
  let lo = 0, hi = fs.length - 1, hit = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (fs[mid].start <= t + 0.001) { hit = mid; lo = mid + 1; } else hi = mid - 1;
  }
  const f = fs[hit];
  return f && (t < f.end || (hit === fs.length - 1 && t <= f.end + 0.1)) ? f : null;
}
async function startText() {
  if (tl.on || !textOK()) return;
  tl.on = true;
  const token = ++tl.token;
  if (document.fullscreenElement && document.exitFullscreen) {
    const left = document.exitFullscreen();
    if (left && left.catch) left.catch(() => {});
  }
  v.pause();
  v.controls = false;
  ocr.setAttribute("aria-pressed", "true");
  layer.hidden = true;
  tlBar.hidden = false;
  tlBar.classList.remove("empty");
  tlMsg.textContent = "Loading text…";
  $("tl-all").disabled = true;
  const name = textLayerName();
  if (tl.name !== name) { tl.name = name; tl.data = null; tl.loading = null; }
  try {
    if (!tl.data) {
      tl.loading = tl.loading || fetch(abs(name)).then(r => {
        if (!r.ok) throw new Error("text");
        return r.json();
      }).then(parseTextLayer);
      const data = await tl.loading;
      if (tl.name === name) tl.data = data;
    }
  } catch (e) {
    tl.loading = null;
    if (token !== tl.token) return;
    tlBar.classList.add("empty");
    tlMsg.textContent = "Couldn't load the text";
    $("tl-done").focus();
    say("Couldn't load the text");
    return;
  }
  if (token !== tl.token || !tl.data) return;
  showLines(true);
  const all = $("tl-all");
  (all.disabled ? $("tl-done") : all).focus({ preventScroll: true });
}
function showLines(first) {
  const f = frameAt(v.currentTime), lines = f ? f.lines : [];
  tl.frame = f;
  layer.textContent = "";
  for (const l of lines) layer.append(el("span", "", l.text), document.createElement("br"));
  layer.hidden = !lines.length;
  layoutText();
  tlBar.classList.toggle("empty", !lines.length);
  $("tl-all").disabled = !lines.length;
  tlMsg.textContent = lines.length ? "Select text to copy" : "No text on this frame";
  say(lines.length ? plural(lines.length, "line") + " of text. Select text to copy, or use Copy all." : "No text on this frame");
  if (first && lines.length) {
    layer.classList.remove("reveal");
    void layer.offsetWidth;
    layer.classList.add("reveal");
    setTimeout(() => layer.classList.remove("reveal"), 1300);
  }
}
// Positions each line over the picture, inside object-fit: contain's letterbox. The font size
// comes from the line's height; each span is then stretched to the line's width (as PDF.js does).
function layoutText() {
  if (!tl.on || !tl.frame || layer.hidden) return;
  const bw = v.clientWidth, bh = v.clientHeight;
  const iw = v.videoWidth || (tl.data && tl.data.width) || meta.width || bw;
  const ih = v.videoHeight || (tl.data && tl.data.height) || meta.height || bh;
  if (!bw || !bh || !iw || !ih) return;
  const s = Math.min(bw / iw, bh / ih), cw = iw * s, ch = ih * s;
  layer.style.left = (v.offsetLeft + (bw - cw) / 2) + "px";
  layer.style.top = (v.offsetTop + (bh - ch) / 2) + "px";
  layer.style.width = cw + "px";
  layer.style.height = ch + "px";
  if (!measure) measure = document.createElement("canvas").getContext("2d");
  const spans = layer.getElementsByTagName("span");
  tl.frame.lines.forEach((l, i) => {
    const sp = spans[i];
    if (!sp) return;
    const size = Math.max(1, l.h * ch);
    sp.style.left = l.x * cw + "px";
    sp.style.top = l.y * ch + "px";
    sp.style.fontSize = size + "px";
    let natural = 0;
    if (measure) { measure.font = size + "px " + FONT; natural = measure.measureText(l.text).width; }
    sp.style.transform = natural > 0 ? "scaleX(" + (l.w * cw / natural).toFixed(4) + ")" : "";
  });
}
function stopText() {
  if (!tl.on) return;
  tl.on = false;
  tl.token++;
  const refocus = tlBar.contains(document.activeElement);
  layer.hidden = true;
  layer.textContent = "";
  tl.frame = null;
  tlBar.hidden = true;
  v.controls = true;
  ocr.setAttribute("aria-pressed", "false");
  if (refocus && !ocr.hidden) ocr.focus();
}
ocr.addEventListener("click", () => { if (tl.on) stopText(); else startText(); });
$("tl-done").addEventListener("click", stopText);
$("tl-all").addEventListener("click", async () => {
  if (!tl.frame || !tl.frame.lines.length) return;
  await clip(tl.frame.lines.map(l => l.text).join("\n"));
  const b = $("tl-all");
  b.textContent = "Copied"; say("Text copied");
  setTimeout(() => { b.textContent = "Copy all"; }, 1600);
});
v.addEventListener("play", () => { if (tl.on) stopText(); });
v.addEventListener("seeked", () => { if (tl.on && tl.data) showLines(false); });
if (window.ResizeObserver) new ResizeObserver(() => layoutText()).observe(v);
else window.addEventListener("resize", layoutText);

// Copy link
async function clip(text) {
  const before = document.activeElement;
  try {
    await Promise.race([navigator.clipboard.writeText(text),
      new Promise((_, reject) => setTimeout(() => reject(new Error("timeout")), 800))]);
  }
  catch (e) {
    const ta = document.createElement("textarea");
    ta.value = text; ta.style.position = "fixed"; ta.style.opacity = "0";
    document.body.appendChild(ta); ta.select();
    try { document.execCommand("copy"); } catch (e2) {}
    ta.remove();
    if (before && before.focus) before.focus({ preventScroll: true });
  }
}
$("copy").addEventListener("click", async () => {
  const label = $("copy").querySelector("span");
  await clip(meta.pageURL + (steps.length && view !== "video" ? "#" + view : ""));
  label.textContent = "Copied"; say("Link copied");
  setTimeout(() => { label.textContent = "Copy link"; }, 1600);
});

// Download: the polished MP4, or the share stream joined into one fragmented MP4.
const fileName = () => (meta.title || "Reelbird recording").replace(/[\\/:*?"<>|]+/g, " ").replace(/\s+/g, " ").trim().slice(0, 120) + ".mp4";
function save(href) {
  const a = document.createElement("a");
  a.href = href; a.download = fileName(); a.rel = "noopener";
  document.body.appendChild(a); a.click(); a.remove();
}
$("download").addEventListener("click", async () => {
  if (meta.video) { save(abs(meta.video)); return; }
  if (!meta.hls || downloading) return;
  const btn = $("download"), label = btn.querySelector("span");
  downloading = true; btn.disabled = true;
  try {
    const base = abs(meta.hls).replace(/[^/]*$/, "");
    const text = await (await fetch(abs(meta.hls), { cache: "no-store" })).text();
    const map = /#EXT-X-MAP:URI="([^"]+)"/.exec(text);
    const names = text.split(/\r?\n/).filter(l => l && !l.startsWith("#"));
    const urls = (map ? [map[1]] : []).concat(names).map(n => new URL(n, base).href);
    const parts = new Array(urls.length);
    let done = 0, next = 0;
    const worker = async () => {
      while (next < urls.length) {
        const i = next++;
        const r = await fetch(urls[i]);
        if (!r.ok) throw new Error("segment");
        parts[i] = await r.blob();
        done++;
        label.textContent = "Preparing " + Math.round(done / urls.length * 100) + "%";
      }
    };
    await Promise.all([worker(), worker(), worker(), worker()]);
    const url = URL.createObjectURL(new Blob(parts, { type: "video/mp4" }));
    save(url);
    setTimeout(() => URL.revokeObjectURL(url), 60000);
    label.textContent = "Download";
  } catch (e) {
    label.textContent = "Download failed";
    setTimeout(() => { label.textContent = "Download"; }, 2500);
  }
  downloading = false; btn.disabled = false;
});

// Keyboard
const keys = $("keys"), keysOpen = $("keys-open");
const toggleKeys = show => {
  keys.hidden = !(show === undefined ? keys.hidden : show);
  keysOpen.setAttribute("aria-expanded", String(!keys.hidden));
};
keysOpen.addEventListener("click", e => { e.stopPropagation(); toggleKeys(); });
document.addEventListener("click", e => { if (!keys.hidden && !keys.contains(e.target)) toggleKeys(false); });
const seek = d => { v.currentTime = Math.max(0, Math.min((v.duration || Infinity), v.currentTime + d)); };
document.addEventListener("keydown", e => {
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  const tag = (e.target.tagName || "").toLowerCase();
  if (tag === "input" || tag === "textarea" || tag === "select" || e.target.isContentEditable) return;
  if (e.target.getAttribute && e.target.getAttribute("role") === "tab" && tabKey(e)) { e.preventDefault(); return; }
  let k = e.key;
  if (e.shiftKey && (!k || k.length !== 1 || /[/.,]/.test(k))) k = { Slash: "?", Period: ">", Comma: "<" }[e.code] || k;
  let handled = true;
  if (view !== "video") {
    // Guide and Click-through: no video keys.
    switch (k) {
      case "ArrowRight": if (view === "demo") next(); else handled = false; break;
      case "ArrowLeft": if (view === "demo") back(); else handled = false; break;
      case "Enter": if (view === "demo" && tag !== "button" && tag !== "a") next(); else handled = false; break;
      case "?": toggleKeys(); break;
      case "Escape": if (!keys.hidden) toggleKeys(false); else handled = false; break;
      default: handled = false;
    }
    if (handled) e.preventDefault();
    return;
  }
  if (tl.on && e.shiftKey && /^Arrow/.test(k)) return; // extending a text selection
  if (k === " " && (e.target === v || tag === "button")) return; // native handling
  switch (k) {
    case " ": case "k": case "K": v.paused ? v.play().catch(() => {}) : v.pause(); break;
    case "ArrowLeft": if (e.target === v) { handled = false; break; } seek(-5); break;
    case "ArrowRight": if (e.target === v) { handled = false; break; } seek(5); break;
    case "j": case "J": seek(-10); break;
    case "l": case "L": seek(10); break;
    case "f": case "F":
      if (document.fullscreenElement) document.exitFullscreen();
      else if (v.requestFullscreen) v.requestFullscreen().catch(() => {});
      else if (v.webkitEnterFullscreen) v.webkitEnterFullscreen();
      break;
    case "m": case "M": v.muted = !v.muted; say(v.muted ? "Muted" : "Unmuted"); break;
    case "c": case "C": if (track) setCaptions(track.track.mode !== "showing"); break;
    case "t": case "T": if (textOK()) { if (tl.on) stopText(); else startText(); } else handled = false; break;
    case ">": stepSpeed(1); break;
    case "<": stepSpeed(-1); break;
    case "?": toggleKeys(); break;
    case "Escape": if (!keys.hidden) toggleKeys(false); else if (tl.on) stopText(); else handled = false; break;
    default:
      if (/^[0-9]$/.test(k) && isFinite(v.duration)) v.currentTime = v.duration * Number(k) / 10;
      else handled = false;
  }
  if (handled) e.preventDefault();
});

setSpeed(speedIndex);
renderInfo();
attach();
if (steps.length) setView(firstView(), true);
if (meta.status !== "ready") pollTimer = setTimeout(poll, 1500);
})();
</script>
</body>
</html>
"""#
}
