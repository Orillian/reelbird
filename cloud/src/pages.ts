// Server-rendered pages: sign-in, device approval, account and per-link stats.
// Same palette as the viewer page, so a hosted link and its stats feel like one product.
import { config } from "./config";
import type { Stats } from "./stats";
import type { User } from "./auth";

export const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[ch]!);

const ICON = `data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Ccircle cx='16' cy='16' r='15' fill='%23ff8d4d'/%3E%3Cpath d='M13 10.5v11l9-5.5z' fill='%2313110f'/%3E%3C/svg%3E`;

const CSS = `
:root{color-scheme:light;--bg:#faf7f2;--raise:#fffdfa;--sunk:#f3ede4;--text:#1c1814;--muted:#6c6259;--faint:#978d83;--line:rgba(60,40,20,.12);--accent:#ff8d4d;--accent-hover:#ff7d33;--accent-text:#c2520f;--on-accent:#221005;--ring:0 0 0 1px rgba(60,40,20,.07);--lift:0 1px 2px rgba(60,40,20,.05),0 18px 50px -24px rgba(60,40,20,.35)}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){color-scheme:dark;--bg:#13110f;--raise:#1c1916;--sunk:#0f0d0c;--text:#f4eee6;--muted:#a3998e;--faint:#746b62;--line:rgba(255,236,214,.1);--accent-text:#ff9a5e;--accent-hover:#ffa066;--ring:0 0 0 1px rgba(255,236,214,.07);--lift:0 24px 70px -30px rgba(0,0,0,.8)}}
:root[data-theme=dark]{color-scheme:dark;--bg:#13110f;--raise:#1c1916;--sunk:#0f0d0c;--text:#f4eee6;--muted:#a3998e;--faint:#746b62;--line:rgba(255,236,214,.1);--accent-text:#ff9a5e;--accent-hover:#ffa066;--ring:0 0 0 1px rgba(255,236,214,.07);--lift:0 24px 70px -30px rgba(0,0,0,.8)}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;-webkit-font-smoothing:antialiased;min-height:100vh;display:flex;flex-direction:column}
a{color:inherit}
header.top{width:100%;max-width:1040px;margin:0 auto;padding:20px 16px;display:flex;align-items:center;justify-content:space-between;gap:16px}
.brand{display:inline-flex;align-items:center;gap:10px;font-weight:650;letter-spacing:-.01em;text-decoration:none}
.brand img{width:22px;height:22px}
.brand small{font-weight:500;color:var(--faint)}
nav.top{display:flex;align-items:center;gap:14px;color:var(--muted);font-size:14px}
nav.top a{text-decoration:none}nav.top a:hover{color:var(--text)}
main{width:100%;max-width:1040px;margin:0 auto;padding:12px 16px 48px;flex:1}
main.narrow{max-width:440px;padding-top:8vh}
h1{margin:0 0 6px;font-size:clamp(22px,2.6vw,28px);line-height:1.2;font-weight:650;letter-spacing:-.02em;text-wrap:balance;overflow-wrap:anywhere}
h2{margin:0 0 12px;font-size:14px;font-weight:600;color:var(--muted)}
p{margin:0 0 12px}
.muted{color:var(--muted)}.faint{color:var(--faint)}
.card{background:var(--raise);border-radius:14px;box-shadow:var(--ring),var(--lift);padding:22px}
.btn{appearance:none;display:inline-flex;align-items:center;justify-content:center;gap:7px;height:38px;padding:0 16px;border-radius:10px;border:1px solid var(--line);background:var(--raise);color:var(--text);font:inherit;font-size:14px;font-weight:560;cursor:pointer;text-decoration:none;white-space:nowrap}
.btn:hover{background:color-mix(in srgb,var(--raise),var(--text) 6%)}
.btn.primary{background:var(--accent);border-color:transparent;color:var(--on-accent)}
.btn.primary:hover{background:var(--accent-hover)}
.btn.small{height:30px;padding:0 11px;font-size:13px}
.btn:focus-visible,input:focus-visible,a:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
form.stack{display:grid;gap:12px;margin-top:18px}
label{font-size:13px;font-weight:560;color:var(--muted)}
input[type=email]{width:100%;height:42px;padding:0 12px;border-radius:10px;border:1px solid var(--line);background:var(--bg);color:var(--text);font:inherit}
.code{font:600 28px/1 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.12em;text-align:center;padding:18px;border-radius:12px;background:var(--sunk);margin:16px 0}
.note{font-size:13px;color:var(--faint);margin-top:14px}
.pill{display:inline-flex;align-items:center;height:22px;padding:0 9px;border-radius:999px;font-size:12px;font-weight:600;background:var(--sunk);color:var(--muted)}
.pill.pro{background:color-mix(in srgb,var(--accent),transparent 82%);color:var(--accent-text)}
.row{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:12px}
.meter{height:6px;border-radius:99px;background:var(--sunk);overflow:hidden;margin:8px 0 4px}
.meter i{display:block;height:100%;background:var(--accent);border-radius:99px}
.grid2{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:16px;margin-top:16px}
table{width:100%;border-collapse:collapse;font-size:14px}
th{text-align:left;font-weight:560;color:var(--faint);font-size:12.5px;padding:0 10px 8px}
td{padding:11px 10px;border-top:1px solid var(--line);vertical-align:middle}
td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}
td a{text-decoration:none;font-weight:560}td a:hover{color:var(--accent-text)}
.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin:18px 0 16px}
.kpi{background:var(--raise);border-radius:12px;box-shadow:var(--ring);padding:14px 16px}
.kpi b{display:block;font-size:26px;line-height:1.15;font-weight:650;letter-spacing:-.02em;font-variant-numeric:tabular-nums}
.kpi span{font-size:13px;color:var(--muted)}
.chart{width:100%;height:auto;display:block;overflow:visible}
.chart .area{fill:color-mix(in srgb,var(--accent),transparent 80%)}
.chart .lineo{fill:none;stroke:var(--accent);stroke-width:2;vector-effect:non-scaling-stroke}
.chart .grid{stroke:var(--line);stroke-width:1;vector-effect:non-scaling-stroke}
.chart text{fill:var(--faint);font-size:11px;font-variant-numeric:tabular-nums}
.bars{display:flex;align-items:flex-end;gap:3px;height:90px}
.bars i{flex:1;background:var(--accent);border-radius:3px 3px 0 0;min-height:2px;opacity:.85}
.bars i.zero{background:var(--line);opacity:1}
.list{list-style:none;margin:0;padding:0}
.list li{display:flex;justify-content:space-between;gap:12px;padding:8px 0;border-top:1px solid var(--line);font-size:14px}
.list li:first-child{border-top:0}
.list b{font-weight:560;font-variant-numeric:tabular-nums}
.lock{text-align:center;padding:34px 22px}
.lock h2{color:var(--text);font-size:17px;margin-bottom:6px}
.empty{color:var(--faint);font-size:14px;padding:18px 0}
.foot{width:100%;max-width:1040px;margin:0 auto;padding:24px 16px 32px;color:var(--faint);font-size:13px}
@media (max-width:640px){td.hide,th.hide{display:none}.card{padding:18px}}
`;

function layout(title: string, body: string, opts: { user?: User | null; narrow?: boolean } = {}) {
  const nav = opts.user
    ? `<nav class="top"><a href="/account">Your links</a><form method="post" action="/logout" style="margin:0"><button class="btn small" type="submit">Sign out</button></form></nav>`
    : `<nav class="top"><a href="/login">Sign in</a></nav>`;
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title><meta name="robots" content="noindex"><link rel="icon" href="${ICON}"><style>${CSS}</style></head>
<body><header class="top"><a class="brand" href="/"><img src="${ICON}" alt="">Reelbird <small>Cloud</small></a>${nav}</header>
<main${opts.narrow ? ' class="narrow"' : ""}>${body}</main>
<footer class="foot">Reelbird Cloud${config.dev ? " · development server" : ""}</footer></body></html>`;
}

export function notFoundPage(message = "This link doesn't exist, or its owner deleted it.") {
  return layout("Link not available", `<div class="card"><h1>Link not available</h1><p class="muted">${esc(message)}</p></div>`, { narrow: true });
}

export function homePage(user: User | null) {
  return layout("Reelbird Cloud", `<div class="card">
<h1>Share without setting up storage</h1>
<p class="muted">Reelbird Cloud hosts your links, so Share just works. Pro adds unlimited links and full viewer analytics.</p>
<p style="margin-top:18px">${user ? `<a class="btn primary" href="/account">Your links</a>` : `<a class="btn primary" href="/login">Sign in</a>`}</p>
</div>`, { user, narrow: true });
}

export function loginPage(next: string, error?: string) {
  const devNote = config.dev
    ? `<p class="note">Development server: you're signed in straight away, no email is sent.</p>`
    : "";
  return layout("Sign in · Reelbird Cloud", `<div class="card">
<h1>Sign in</h1><p class="muted">Use your email address. New addresses get an account.</p>
${error ? `<p style="color:var(--accent-text)">${esc(error)}</p>` : ""}
<form class="stack" method="post" action="/login"><input type="hidden" name="next" value="${esc(next)}">
<label for="email">Email</label><input id="email" name="email" type="email" required autocomplete="email" autofocus>
<button class="btn primary" type="submit">Continue</button></form>${devNote}</div>`, { narrow: true });
}

export function devicePage(user: User, code: string, name: string | null, state: "ask" | "done" | "invalid") {
  if (state === "invalid") {
    return layout("Connect Reelbird", `<div class="card"><h1>Code expired</h1><p class="muted">Start again from Reelbird: Settings › Sharing › Sign in.</p></div>`, { user, narrow: true });
  }
  if (state === "done") {
    return layout("Connected", `<div class="card"><h1>Reelbird is connected</h1><p class="muted">You can close this tab and go back to Reelbird.</p></div>`, { user, narrow: true });
  }
  return layout("Connect Reelbird", `<div class="card">
<h1>Connect Reelbird${name ? ` on ${esc(name)}` : ""}?</h1>
<p class="muted">Check that this code matches the one Reelbird shows.</p>
<div class="code">${esc(code)}</div>
<form method="post" action="/device"><input type="hidden" name="code" value="${esc(code)}">
<button class="btn primary" type="submit" style="width:100%">Connect as ${esc(user.email)}</button></form>
<p class="note">Reelbird can then create and delete links in this account.</p></div>`, { user, narrow: true });
}

const fmtBytes = (n: number) =>
  n < 1024 ** 2 ? `${Math.round(n / 1024)} KB` : n < 1024 ** 3 ? `${(n / 1024 ** 2).toFixed(0)} MB` : `${(n / 1024 ** 3).toFixed(1)} GB`;
const fmtDur = (s: number) => {
  s = Math.max(0, Math.round(s));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
  return h ? `${h}:${String(m).padStart(2, "0")}:${String(x).padStart(2, "0")}` : `${m}:${String(x).padStart(2, "0")}`;
};
const fmtDate = (d: Date | string) => new Date(d).toLocaleDateString("en", { month: "short", day: "numeric", year: "numeric" });

export function accountPage(
  user: User,
  usage: { activeLinks: number; storageBytes: number },
  lim: { activeLinks: number | null; storageBytes: number },
  shares: { id: string; title: string | null; created_at: Date; bytes: string; views: number; opens: number }[],
) {
  const pro = user.plan === "pro";
  const linksLine = lim.activeLinks === null ? `${usage.activeLinks} links` : `${usage.activeLinks} of ${lim.activeLinks} links`;
  const pct = Math.min(100, (usage.storageBytes / lim.storageBytes) * 100);
  const rows = shares.length
    ? shares.map((s) => `<tr><td><a href="/account/s/${esc(s.id)}">${esc(s.title || "Untitled recording")}</a></td>
<td class="num">${s.views}</td><td class="num hide">${fmtBytes(Number(s.bytes))}</td><td class="hide faint">${fmtDate(s.created_at)}</td>
<td class="num"><a class="btn small" href="/r/${esc(s.id)}/" target="_blank" rel="noopener">Open</a></td></tr>`).join("")
    : `<tr><td colspan="5" class="empty">No hosted links yet. In Reelbird, choose Share on any recording.</td></tr>`;
  const devPlan = config.dev
    ? `<form method="post" action="/dev/plan" style="margin:0"><input type="hidden" name="plan" value="${pro ? "free" : "pro"}"><button class="btn small" type="submit">Dev: switch to ${pro ? "Free" : "Pro"}</button></form>`
    : "";
  return layout("Your links · Reelbird Cloud", `
<div class="row"><div><h1>Your links</h1><p class="muted" style="margin:0">${esc(user.email)} <span class="pill${pro ? " pro" : ""}">${pro ? "Pro" : "Free"}</span></p></div>${devPlan}</div>
<div class="grid2">
<div class="card"><h2>Links</h2><b style="font-size:22px">${linksLine}</b>${pro ? `<p class="faint" style="margin:4px 0 0">Unlimited on Pro</p>` : `<p class="faint" style="margin:4px 0 0">Pro removes the limit</p>`}</div>
<div class="card"><h2>Storage</h2><b style="font-size:22px">${fmtBytes(usage.storageBytes)}</b><span class="faint"> of ${fmtBytes(lim.storageBytes)}</span><div class="meter"><i style="width:${pct.toFixed(1)}%"></i></div></div>
</div>
<div class="card" style="margin-top:16px;padding-bottom:10px"><table><thead><tr><th>Recording</th><th class="num">Views</th><th class="num hide">Size</th><th class="hide">Created</th><th></th></tr></thead><tbody>${rows}</tbody></table></div>`, { user });
}

function retentionSVG(retention: number[], chunkSeconds: number, duration: number | null) {
  if (!retention.length) return `<p class="empty">The retention curve appears after the first view of the current version.</p>`;
  const W = 600, H = 160;
  const n = retention.length;
  const x = (i: number) => (n === 1 ? W / 2 : (i / (n - 1)) * W);
  const y = (v: number) => H - v * H;
  const pts = retention.map((v, i) => `${x(i).toFixed(1)},${y(v).toFixed(1)}`).join(" ");
  const total = duration ?? n * chunkSeconds;
  const ticks = [0, 0.25, 0.5, 0.75, 1].map((f) => `<text x="${(f * W).toFixed(0)}" y="${H + 18}" text-anchor="${f === 0 ? "start" : f === 1 ? "end" : "middle"}">${fmtDur(f * total)}</text>`).join("");
  const grid = [0, 0.5, 1].map((f) => `<line class="grid" x1="0" x2="${W}" y1="${y(f)}" y2="${y(f)}"/><text x="-8" y="${y(f) + 4}" text-anchor="end">${Math.round(f * 100)}%</text>`).join("");
  return `<svg class="chart" viewBox="-36 -8 ${W + 44} ${H + 30}" role="img" aria-label="Share of viewers still watching at each point of the video">
${grid}<polygon class="area" points="0,${H} ${pts} ${W},${H}"/><polyline class="lineo" points="${pts}"/>${ticks}</svg>`;
}

const listBlock = (title: string, rows: { name: string; views: number }[]) =>
  `<div class="card"><h2>${esc(title)}</h2>${rows.length ? `<ul class="list">${rows.map((r) => `<li><span>${esc(r.name)}</span><b>${r.views}</b></li>`).join("")}</ul>` : `<p class="empty">No data yet</p>`}</div>`;

export function statsPage(user: User, s: Stats) {
  const kpis = `<div class="kpis">
<div class="kpi"><b>${s.views}</b><span>Views</span></div>
<div class="kpi"><b>${s.locked ? "—" : s.uniqueViewers}</b><span>Unique viewers</span></div>
<div class="kpi"><b>${s.averagePercent === null ? "—" : s.averagePercent + "%"}</b><span>Average watched</span></div>
<div class="kpi"><b>${s.completionRate === null ? "—" : s.completionRate + "%"}</b><span>Watched to the end</span></div>
</div>`;
  const head = `<p style="margin:0 0 4px"><a class="faint" href="/account" style="text-decoration:none">← Your links</a></p>
<div class="row"><h1>${esc(s.title || "Untitled recording")}</h1><a class="btn small" href="/r/${esc(s.id)}/" target="_blank" rel="noopener">Open link</a></div>`;
  if (s.locked) {
    return layout(`${s.title ?? "Stats"} · Reelbird Cloud`, `${head}${kpis}
<div class="card lock"><h2>See who's watching</h2><p class="muted">Pro shows where people stop watching, unique viewers, where they came from and every recent view.${s.views ? ` Your ${s.views} view${s.views === 1 ? " is" : "s are"} already recorded.` : ""}</p></div>`, { user });
  }
  const maxDay = Math.max(1, ...s.byDay.map((d) => d.views));
  const bars = s.byDay.map((d) => `<i class="${d.views ? "" : "zero"}" style="height:${d.views ? Math.max(4, (d.views / maxDay) * 100) : 2}%" title="${esc(d.day)}: ${d.views}"></i>`).join("");
  const recent = s.recent.length
    ? `<table><thead><tr><th>When</th><th class="num">Watched</th><th class="hide">Device</th><th class="hide">From</th></tr></thead><tbody>${s.recent.map((r) => `<tr><td>${new Date(r.at).toLocaleString("en", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })}</td><td class="num">${r.percent === null ? fmtDur(r.seconds) : r.percent + "%"}</td><td class="hide muted">${esc([r.device, r.browser].filter(Boolean).join(" · "))}</td><td class="hide muted">${esc(r.referrer ?? "Direct")}</td></tr>`).join("")}</tbody></table>`
    : `<p class="empty">No views yet. Send the link to someone.</p>`;
  return layout(`${s.title ?? "Stats"} · Reelbird Cloud`, `${head}${kpis}
<div class="card"><h2>Still watching</h2>${retentionSVG(s.retention, s.chunkSeconds, s.duration)}</div>
<div class="grid2">
<div class="card"><h2>Views, last 30 days</h2><div class="bars">${bars}</div></div>
${listBlock("Where viewers came from", s.referrers)}
${listBlock("Devices", s.devices)}
${s.countries.length ? listBlock("Countries", s.countries) : ""}
</div>
<div class="card" style="margin-top:16px;padding-bottom:10px"><h2>Recent views</h2>${recent}</div>`, { user });
}
