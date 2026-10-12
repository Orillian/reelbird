import Foundation
import ReelbirdCore

/// The static viewer page uploaded to `r/<id>/index.html`.
///
/// Self-contained (inline CSS and JS, no fonts or images to fetch). hls.js is loaded from
/// jsDelivr, pinned and integrity-checked, only when the share has no polished MP4 yet and
/// the browser can't play HLS natively. Open Graph and Twitter tags are baked into the HTML
/// because link unfurlers (Slack, iMessage) don't run JavaScript.
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

        return template
            .replacingOccurrences(of: "{{HEAD}}", with: head.joined(separator: "\n"))
            .replacingOccurrences(of: "{{TITLE}}", with: text(title))
            .replacingOccurrences(of: "{{SUBLINE}}", with: text(subline))
            .replacingOccurrences(of: "{{RATIO}}", with: ratio)
            .replacingOccurrences(of: "{{RATIO_N}}", with: ratioNumber)
            .replacingOccurrences(of: "{{POSTER}}", with: meta.url(meta.poster).map { #" poster="\#(attr($0))""# } ?? "")
            .replacingOccurrences(of: "{{HLS_URL}}", with: hlsURL)
            .replacingOccurrences(of: "{{HLS_SRI}}", with: hlsIntegrity)
            .replacingOccurrences(of: "{{REPO}}", with: ReelbirdInfo.repositoryURL)
            .replacingOccurrences(of: "{{META}}", with: json)
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
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func attr(_ s: String) -> String { text(s).replacingOccurrences(of: "\"", with: "&quot;") }
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
<meta name="theme-color" media="(prefers-color-scheme: light)" content="#faf7f2">
<meta name="theme-color" media="(prefers-color-scheme: dark)" content="#13110f">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Ccircle cx='16' cy='16' r='15' fill='%23ff8d4d'/%3E%3Cpath d='M13 10.5v11l9-5.5z' fill='%2313110f'/%3E%3C/svg%3E">
<style>
:root{color-scheme:light;--bg:#faf7f2;--raise:#fffdfa;--text:#1c1814;--muted:#6c6259;--faint:#978d83;--line:rgba(60,40,20,.12);--hover:rgba(60,40,20,.055);--accent:#ff8d4d;--accent-hover:#ff7d33;--accent-text:#c2520f;--on-accent:#221005;--stage:#0f0d0c;--ring:0 0 0 1px rgba(60,40,20,.07);--lift:0 1px 2px rgba(60,40,20,.05),0 18px 50px -24px rgba(60,40,20,.35)}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){color-scheme:dark;--bg:#13110f;--raise:#1c1916;--text:#f4eee6;--muted:#a3998e;--faint:#746b62;--line:rgba(255,236,214,.1);--hover:rgba(255,236,214,.06);--accent:#ff8d4d;--accent-hover:#ffa066;--accent-text:#ff9a5e;--on-accent:#221005;--stage:#0a0908;--ring:0 0 0 1px rgba(255,236,214,.07);--lift:0 24px 70px -30px rgba(0,0,0,.8)}}
:root[data-theme=dark]{color-scheme:dark;--bg:#13110f;--raise:#1c1916;--text:#f4eee6;--muted:#a3998e;--faint:#746b62;--line:rgba(255,236,214,.1);--hover:rgba(255,236,214,.06);--accent:#ff8d4d;--accent-hover:#ffa066;--accent-text:#ff9a5e;--on-accent:#221005;--stage:#0a0908;--ring:0 0 0 1px rgba(255,236,214,.07);--lift:0 24px 70px -30px rgba(0,0,0,.8)}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%;text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;-webkit-font-smoothing:antialiased;min-height:100vh;display:flex;flex-direction:column}
main{width:100%;max-width:1120px;margin:0 auto;padding:clamp(16px,4vw,40px) clamp(16px,3vw,32px) 24px;flex:1}
.stage{position:relative;width:min(100%,calc(76vh * {{RATIO_N}}));aspect-ratio:{{RATIO}};margin:0 auto;background:var(--stage);border-radius:14px;overflow:hidden;box-shadow:var(--ring),var(--lift)}
video{display:block;width:100%;height:100%;object-fit:contain;background:var(--stage)}
.veil{position:absolute;inset:0;display:grid;place-content:center;justify-items:center;gap:6px;padding:24px;text-align:center;color:#f4eee6;background:radial-gradient(120% 90% at 18% 0%,rgba(255,141,77,.13),transparent 55%),var(--stage)}
.veil[hidden]{display:none}
.veil h2{margin:10px 0 0;font-size:17px;font-weight:600;letter-spacing:-.01em}
.veil p{margin:0;max-width:34ch;color:rgba(244,238,230,.6);font-size:14px}
.veil .mark{width:44px;height:44px;border-radius:50%;display:grid;place-items:center;background:rgba(255,141,77,.14);color:var(--accent)}
.veil .btn{margin-top:14px}
.bar{display:flex;flex-wrap:wrap;align-items:flex-start;justify-content:space-between;gap:14px 24px;max-width:calc(76vh * {{RATIO_N}});margin:22px auto 0}
.info{min-width:0;flex:1 1 320px}
h1{margin:0;font-size:clamp(20px,2.3vw,25px);line-height:1.25;font-weight:650;letter-spacing:-.018em;text-wrap:balance;overflow-wrap:anywhere}
.sub{margin-top:5px;display:flex;flex-wrap:wrap;align-items:center;gap:6px 10px;color:var(--muted);font-size:14px;font-variant-numeric:tabular-nums}
.live{display:inline-flex;align-items:center;gap:7px;color:var(--accent-text);font-weight:600}
.live::before{content:"";width:7px;height:7px;border-radius:50%;background:currentColor;animation:breathe 2.4s ease-in-out infinite}
.live[hidden]{display:none}
@keyframes breathe{50%{opacity:.35}}
.actions{display:flex;flex-wrap:wrap;gap:8px}
.btn{appearance:none;display:inline-flex;align-items:center;justify-content:center;gap:7px;height:36px;padding:0 14px;border-radius:10px;border:1px solid var(--line);background:var(--raise);color:var(--text);font:inherit;font-size:14px;font-weight:560;line-height:1;white-space:nowrap;cursor:pointer;text-decoration:none;transition:background-color .15s,border-color .15s,color .15s;-webkit-tap-highlight-color:transparent}
.btn:hover{background:color-mix(in srgb,var(--raise),var(--text) 6%)}
.btn:active{transform:translateY(.5px)}
.btn:focus-visible,.chapters button:focus-visible,.foot a:focus-visible,.foot button:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.btn:disabled{opacity:.45;cursor:default;transform:none}
.btn svg{width:16px;height:16px;flex:none}
.btn.primary{background:var(--accent);border-color:transparent;color:var(--on-accent)}
.btn.primary:hover{background:var(--accent-hover)}
.btn.speed{min-width:56px;font-variant-numeric:tabular-nums}
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
.foot{width:100%;max-width:1120px;margin:0 auto;padding:28px clamp(16px,3vw,32px) max(28px,env(safe-area-inset-bottom));display:flex;align-items:center;justify-content:space-between;gap:16px;color:var(--faint);font-size:13px}
.foot a,.foot button{all:unset;cursor:pointer;color:var(--faint);display:inline-flex;align-items:center;gap:8px;border-radius:4px}
.foot a:hover,.foot button:hover{color:var(--text)}
.foot .dot{width:14px;height:14px;flex:none}
.keys{position:fixed;right:20px;bottom:20px;z-index:5;width:290px;padding:16px 18px;border-radius:14px;background:var(--raise);color:var(--text);box-shadow:var(--ring),0 24px 60px -20px rgba(0,0,0,.45);font-size:13.5px}
.keys[hidden]{display:none}
.keys h2{margin:0 0 10px;font-size:14px;font-weight:600}
.keys dl{margin:0;display:grid;grid-template-columns:auto 1fr;gap:8px 14px;align-items:center}
.keys dt{display:flex;gap:4px}
.keys dd{margin:0;color:var(--muted)}
kbd{min-width:22px;height:22px;padding:0 6px;display:inline-grid;place-items:center;border-radius:6px;border:1px solid var(--line);border-bottom-width:2px;font:inherit;font-size:12px;color:var(--text)}
.sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}
@media (hover:none){#keys-open{display:none}}
@media (max-width:640px){
main{padding:0 0 16px}
.stage{width:100%;border-radius:0;box-shadow:none}
.bar,.chapters{padding:0 16px;margin-top:16px}
.actions{width:100%}
.actions .btn.grow{flex:1}
.foot{padding-top:20px}
}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
</style>
</head>
<body>
<main>
<div class="stage">
<video id="v" controls playsinline preload="metadata"{{POSTER}}></video>
<div class="veil" id="veil" hidden>
<div class="mark" aria-hidden="true"><svg width="20" height="20" viewBox="0 0 20 20" fill="none"><circle cx="10" cy="10" r="4" fill="currentColor"/></svg></div>
<h2 id="veil-title"></h2>
<p id="veil-text"></p>
<button class="btn" id="veil-retry" type="button" hidden>Try again</button>
</div>
</div>
<div class="bar">
<div class="info">
<h1 id="title">{{TITLE}}</h1>
<div class="sub"><span id="subline">{{SUBLINE}}</span><span class="live" id="live" hidden>Recording</span></div>
</div>
<div class="actions">
<button class="btn speed" id="speed" type="button" title="Playback speed (&lt; and &gt;)" aria-label="Playback speed 1×">1×</button>
<button class="btn" id="cc" type="button" aria-pressed="false" title="Captions (C)" hidden><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><rect x="1.5" y="3" width="13" height="10" rx="2.2"/><path d="M7 6.7a1.9 1.9 0 1 0 0 2.6M11.6 6.7a1.9 1.9 0 1 0 0 2.6" stroke-linecap="round"/></svg>Captions</button>
<button class="btn grow" id="copy" type="button"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M6.6 9.4a2.6 2.6 0 0 0 3.7 0l2.4-2.4a2.6 2.6 0 0 0-3.7-3.7l-.6.6"/><path d="M9.4 6.6a2.6 2.6 0 0 0-3.7 0L3.3 9a2.6 2.6 0 0 0 3.7 3.7l.6-.6"/></svg><span>Copy link</span></button>
<button class="btn primary grow" id="download" type="button"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M8 2.5v8M4.8 7.6 8 10.8l3.2-3.2M3 13.5h10"/></svg><span>Download</span></button>
</div>
</div>
<section class="chapters" id="chapters" hidden>
<h2>Chapters</h2>
<ol id="chapter-list"></ol>
</section>
</main>
<footer class="foot">
<a href="{{REPO}}" rel="noopener"><svg class="dot" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="7.5" fill="var(--accent)"/><path d="M6.5 5.2v5.6L11 8z" fill="var(--on-accent)"/></svg>Made with Reelbird</a>
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
</dl>
</div>
<div class="sr" aria-live="polite" id="announce"></div>
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
  const parts = [];
  if (meta.duration && meta.status === "ready") parts.push(fmt(meta.duration));
  try {
    parts.push(new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", year: "numeric" }).format(new Date(meta.createdAt)));
  } catch (e) {}
  $("subline").textContent = parts.join(" · ");
  const live = $("live");
  live.hidden = meta.status === "ready";
  live.textContent = meta.status === "recording" ? "Recording" : "Finishing upload";
  const dl = $("download");
  const canDownload = !!meta.video || (!!meta.hls && meta.status === "ready");
  dl.disabled = !canDownload || downloading;
  dl.title = canDownload ? "Download MP4" : "Available when the recording ends";
  renderCaptions();
  renderChapters();
}

// Playback source: the polished MP4 when present, else the HLS share stream.
function attach() {
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
    showVeil("No video in this recording", "The recording ended before any video was captured.");
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
      else { destroyHls(); mode = null; showVeil("This video couldn't be played", "Check your connection and try again.", true); }
    });
    hls.loadSource(url);
    hls.attachMedia(v);
  }).catch(() => { v.src = url; });
}
function destroyHls() { if (hls) { hls.destroy(); hls = null; } }

v.addEventListener("error", () => {
  if (mode === "mp4" || (mode === "hls" && !hls)) {
    mode = null;
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

// Copy link
$("copy").addEventListener("click", async () => {
  const label = $("copy").querySelector("span");
  try { await navigator.clipboard.writeText(meta.pageURL); }
  catch (e) {
    const ta = document.createElement("textarea");
    ta.value = meta.pageURL; ta.style.position = "fixed"; ta.style.opacity = "0";
    document.body.appendChild(ta); ta.select();
    try { document.execCommand("copy"); } catch (e2) {}
    ta.remove();
  }
  label.textContent = "Copied"; say("Link copied");
  setTimeout(() => { label.textContent = "Copy link"; }, 1600);
});

// Download: the polished MP4, or the share stream joined into one fragmented MP4.
const fileName = () => (meta.title || "Reelbird recording").replace(/[\\/:*?"<>|]+/g, " ").trim().slice(0, 120) + ".mp4";
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
keysOpen.addEventListener("click", () => toggleKeys());
const seek = d => { v.currentTime = Math.max(0, Math.min((v.duration || Infinity), v.currentTime + d)); };
document.addEventListener("keydown", e => {
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  const tag = (e.target.tagName || "").toLowerCase();
  if (tag === "input" || tag === "textarea" || tag === "select" || e.target.isContentEditable) return;
  const k = e.key;
  if (k === " " && (e.target === v || tag === "button")) return; // native handling
  let handled = true;
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
    case ">": stepSpeed(1); break;
    case "<": stepSpeed(-1); break;
    case "?": toggleKeys(); break;
    case "Escape": if (!keys.hidden) toggleKeys(false); else handled = false; break;
    default:
      if (/^[0-9]$/.test(k) && isFinite(v.duration)) v.currentTime = v.duration * Number(k) / 10;
      else handled = false;
  }
  if (handled) e.preventDefault();
});

setSpeed(speedIndex);
renderInfo();
attach();
if (meta.status !== "ready") pollTimer = setTimeout(poll, 1500);
})();
</script>
</body>
</html>
"""#
}
