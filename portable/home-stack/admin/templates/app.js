const state = {
  overview: null,
  services: [],
  events: [],
  doctor: null,
  deploy: null,
  pending: null,
};
const $ = (id) => document.getElementById(id);
const esc = (v) =>
  String(v ?? "").replace(
    /[&<>"']/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c],
  );
document
  .querySelectorAll(".tab")
  .forEach((btn) => btn.addEventListener("click", () => setTab(btn.dataset.tab)));
function setTab(tab) {
  document
    .querySelectorAll(".tab")
    .forEach((b) => b.classList.toggle("active", b.dataset.tab === tab));
  document.querySelectorAll(".view").forEach((v) => v.classList.toggle("active", v.id === tab));
}
async function api(path, opts = {}) {
  const resp = await fetch(path, { credentials: "same-origin", ...opts });
  const data = await resp.json().catch(() => ({}));
  if (!resp.ok || data.ok === false) throw new Error(data.message || resp.statusText);
  return data;
}
function renderSkeletons() {
  ["triage", "services", "deploy", "events", "doctor"].forEach(
    (id) => ($(id).innerHTML = '<div class="panel skeleton" style="height:180px">Loading</div>'),
  );
}
function renderAll() {
  renderTriage();
  renderServices();
  renderDeploy();
  renderEvents();
  renderDoctor();
}
function renderTriage() {
  const o = state.overview;
  const status = o?.overall_state || "loading";
  const incidents = o?.top_incidents || [];
  $("triage").innerHTML =
    `<div class="topbar"><div><div class="eyebrow">Home Stack<span class="status-label"></span></div><h1 class="title">Control Plane</h1></div><div class="pill">${esc(new Date().toLocaleTimeString())}</div></div><div class="grid"><div class="panel hero"><div><div class="eyebrow">Stack State</div><div class="state ${esc(status)}">${esc(status).toUpperCase()}</div></div><p>${incidents[0] ? esc(incidents[0].explanation || incidents[0].title) : "All primary checks are calm."}</p></div><div class="card-row">${incidents.length ? incidents.map(renderIncident).join("") : '<div class="incident-card">No active incidents.</div>'}</div></div>`;
}
function renderIncident(i) {
  const sev = (i.severity || "").toLowerCase();
  const cls = sev === "high" ? "sev-high" : sev === "warning" ? "sev-warning" : "sev-info";
  return `<button class="incident-card ${cls}"><strong>${esc(i.title)}</strong><br><span>${esc(i.severity)} · ${esc(i.confidence)}</span></button>`;
}
function sig(x, label, tip, disabled) {
  // Disabled is the only state that reads as neutral: the engine never
  // probes a disabled service, so a missing signal there is expected, not a
  // failure. For an ENABLED service a missing signal (e.g. a plist that was
  // synced but never installed) must still read as err/red -- that is a real
  // problem, and collapsing it into the same neutral look as "disabled"
  // would hide it. The base .signal style is already the neutral look, used
  // here only for the disabled case.
  const cls = disabled ? "" : x ? (x.ok || x.state === "running" ? "ok" : "err") : "err";
  return `<span class="signal ${cls}" title="${esc(tip || label)}">${label}</span>`;
}
function renderServices() {
  $("services").innerHTML =
    `<div class="topbar"><h1 class="title">Services</h1><button class="action" onclick="openServiceAdd()" style="margin-left:auto">+ Add</button></div><div class="card-row">${state.services.map(renderService).join("")}</div>`;
}
function renderService(s) {
  const disabled = s.overall_state === "disabled";
  return `<button class="service-card" data-service="${esc(s.name)}" style="position:relative;overflow:hidden"><strong>${esc(s.display_name || s.name)}</strong><br><span>${esc(s.overall_state || "unknown")}</span><div class="signals">${sig(s.launchd, "L", "Launchd", disabled)}${sig(s.port, "P", "Port", disabled)}${sig(s.route, "R", "Route", disabled)}${sig(s.http, "H", "HTTP", disabled)}</div><div class="swipe-delete" onclick="event.stopPropagation();if(confirm('Remove ${esc(s.display_name || s.name)}?'))api('/api/actions',{method:'POST',headers:{'Content-Type':'application/json','X-Home-Stack-Admin':'1'},body:JSON.stringify({action:'registry.remove',target:'${esc(s.name)}',confirm:true})}).then(()=>loadAll()).catch(e=>alert('Failed: '+e.message))">Remove</div></button>`;
}
document.addEventListener("click", (e) => {
  const card = e.target.closest("[data-service]");
  if (card) openService(card.dataset.service);
});
function serviceDetailRows(s) {
  const rows = [
    ["State", s.overall_state],
    ["Host", s.desired?.host || s.host],
    ["Target", s.desired?.upstream || s.port?.target],
    ["Launchd", s.launchd?.state],
    ["PID", s.launchd?.pid],
    ["Route", s.route?.state],
    ["HTTP", s.http?.state],
    ["Stdout", s.launchd?.stdout],
    ["Stderr", s.launchd?.stderr],
  ].filter(([, v]) => v);
  return rows
    .map(
      ([k, v]) => `<div class="detail-row"><span>${esc(k)}</span><strong>${esc(v)}</strong></div>`,
    )
    .join("");
}
function openService(name) {
  const s = state.services.find((x) => x.name === name);
  if (!s) return;
  const actions =
    (s.actions || [])
      .map(
        (a) =>
          `<button class="action ${a.risk === "destructive" ? "danger" : ""}" data-action="${esc(a.id)}" data-target="${esc(s.name)}" data-confirm="${a.requires_confirmation ? "1" : "0"}">${esc(a.label)}</button>`,
      )
      .join("") || "<p>No web actions for this service.</p>";
  const footer = `<div style="margin-top:16px;display:flex;gap:8px"><button class="action" onclick="closeSheet();openServiceEdit('${esc(s.name)}')" style="flex:1">Edit</button><button class="action danger" onclick="if(confirm('Remove ${esc(s.display_name || s.name)}?')){api('/api/actions',{method:'POST',headers:{'Content-Type':'application/json','X-Home-Stack-Admin':'1'},body:JSON.stringify({action:'registry.remove',target:'${esc(s.name)}',confirm:true})}).then(()=>{closeSheet();loadAll()}).catch(e=>alert('Failed: '+e.message))}" style="flex:1">Remove</button></div>`;
  $("sheet").innerHTML =
    `<div class="sheet-head"><div><h2>${esc(s.display_name || s.name)}</h2><p>${esc(s.kind || "")} · ${esc(s.overall_state || "unknown")}</p></div><button class="sheet-close" aria-label="Close service details" onclick="closeSheet()">×</button></div><div class="sheet-body"><div class="actions">${actions}</div><div class="detail-list">${serviceDetailRows(s)}</div>${footer}</div>`;
  $("sheet").classList.add("open");
  $("sheet-backdrop").classList.add("open");
  document.body.classList.add("sheet-open");
}
function closeSheet() {
  $("sheet").classList.remove("open");
  $("sheet-backdrop").classList.remove("open");
  document.body.classList.remove("sheet-open");
}
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") closeSheet();
});
document.addEventListener("click", (e) => {
  const btn = e.target.closest("[data-action]");
  if (!btn) return;
  const needsConfirm = btn.dataset.confirm === "1";
  if (needsConfirm && !confirm(`Confirm ${btn.textContent.trim()} for ${btn.dataset.target}?`))
    return;
  runAction(btn.dataset.action, btn.dataset.target, needsConfirm);
});
function renderDeploy() {
  const diff = state.deploy?.diff;
  if (diff && diff.has_changes) {
    let html = '<div class="topbar"><h1 class="title">Deploy</h1></div>';
    const secs = { caddyfile: "Caddyfile", launchd: "Launchd Plists", catalog: "Catalog" };
    for (const [s, sec] of Object.entries(secs)) {
      const d = diff[s];
      if (!d || (!d.added && !d.removed && !d.changed)) continue;
      html += `<div class="panel" style="margin-bottom:12px"><strong>${esc(sec)}</strong> <span style="color:var(--ok)">+${d.added}</span> <span style="color:var(--down)">-${d.removed}</span> <span style="color:var(--warn)">~${d.changed}</span>`;
      if (d.details) {
        d.details.forEach((l) => {
          html += `<div style="font:11px monospace;margin-top:4px;color:var(--muted)">${esc(l)}</div>`;
        });
      }
      html += "</div>";
    }
    html +=
      '<button class="action" onclick="runAction(\"deploy.apply\",\"system\",true)" style="margin-top:8px">Apply Changes</button>';
    $("deploy").innerHTML = html;
  } else {
    $("deploy").innerHTML =
      '<div class="topbar"><h1 class="title">Deploy</h1></div><div class="panel"><p>' +
      esc(state.deploy?.details || "No pending changes. The registry is in sync.") +
      '</p><button class="action" onclick="loadDeploy()">Refresh Preview</button></div>';
  }
}
function renderEvents() {
  $("events").innerHTML =
    `<div class="topbar"><h1 class="title">Events</h1></div><div class="card-row">${(state.events || []).map((e) => `<div class="event-row"><strong>${esc(e.message)}</strong><br><span>${esc(e.action)} · ${esc(e.target || "")}</span></div>`).join("") || '<div class="event-row empty">No events yet.</div>'}</div>`;
}
function renderDoctor() {
  const checks = state.doctor?.checks || [];
  $("doctor").innerHTML =
    `<div class="topbar"><h1 class="title">Doctor</h1></div><div class="card-row">${checks.map((c) => `<div class="check-row"><strong>${esc(c.label)}</strong><br><span>${esc(c.state)} ${esc(c.details || "")}</span></div>`).join("") || '<div class="check-row">Doctor checks loading.</div>'}</div>`;
}
function setStatus(state, text) {
  $("status-bar").className = state;
  const el = document.querySelector(".status-label");
  if (el) {
    el.className = "status-label " + state;
    el.textContent = text || "";
  }
}
let initialLoad = true;
async function loadAll() {
  setStatus("syncing");
  if (initialLoad) renderSkeletons();
  try {
    const overview = await api("/api/overview");
    state.overview = overview;
    renderTriage();
    $("triage").classList.add("content-loaded");
    const [services, events, doctor] = await Promise.all([
      api("/api/services"),
      api("/api/events"),
      api("/api/doctor"),
    ]);
    state.services = services.services || [];
    state.events = events.events || [];
    state.doctor = doctor;
    renderServices();
    renderEvents();
    renderDoctor();
    $("services").classList.add("content-loaded");
    $("events").classList.add("content-loaded");
    $("doctor").classList.add("content-loaded");
    setStatus("connected");
  } catch (e) {
    setStatus("offline");
  }
  initialLoad = false;
  loadDeploy();
}
async function loadDeploy() {
  state.deploy = await api("/api/deploy/preview");
  renderDeploy();
}
function setPending(label) {
  state.pending = label;
  document.querySelectorAll("button").forEach((btn) => (btn.disabled = Boolean(label)));
}
async function runAction(action, target, confirm) {
  if (state.pending) return;
  if (action === "admin.restart") return restartAdmin();
  setPending(`${action} ${target}`);
  try {
    await api("/api/actions", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Home-Stack-Admin": "1" },
      body: JSON.stringify({ action, target, confirm }),
    });
    await loadAll();
  } finally {
    setPending(null);
  }
}
async function restartAdmin() {
  setPending("Admin restarting");
  setStatus("offline");
  await api("/api/actions", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Home-Stack-Admin": "1" },
    body: JSON.stringify({ action: "admin.restart", target: "admin", confirm: true }),
  }).catch(() => {});
  await waitForReconnect();
}
async function waitForReconnect() {
  for (let i = 0; i < 18; i++) {
    await new Promise((r) => setTimeout(r, Math.min(1000 + i * 500, 5000)));
    try {
      await api("/api/health");
      setStatus("connected");
      setPending(null);
      await loadAll();
      return;
    } catch (_) {}
  }
  setPending(null);
  setStatus("offline");
}

function openServiceAdd() {
  const types = [
    { id: "proxy", icon: "◉", desc: "Routes to a local port" },
    { id: "static", icon: "📁", desc: "Serves static files" },
    { id: "task", icon: "⏱", desc: "Background job" },
    { id: "split", icon: "⚡", desc: "Frontend + API" },
  ];
  const lcs = [
    { id: "external", icon: "🔗", desc: "Just route to it" },
    { id: "managed", icon: "⚙", desc: "Home-stack runs it" },
    { id: "custom", icon: "📋", desc: "I provide a plist" },
  ];
  let selType = "proxy",
    selLc = "external",
    svcName = "",
    subdomain = "",
    upstream = "",
    root = "",
    apiPath = "/api",
    bin = "",
    plistPath = "";
  function renderAddSheet() {
    let h =
      '<div class="sheet-head"><div><h2>Add Service</h2></div><button class="sheet-close" onclick="closeSheet()">×</button></div><div class="sheet-body">';
    h +=
      '<div class="eyebrow">Name</div><input id="add-name" style="width:100%;padding:12px;border-radius:14px;border:1px solid var(--line);background:rgba(255,255,255,.04);color:var(--text);margin-bottom:12px" placeholder="myapp" value="' +
      esc(svcName) +
      '" oninput="svcName=this.value;renderAddSheet()">';
    h +=
      '<div class="eyebrow">Type</div><div style="display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:12px">';
    types.forEach((t) => {
      h += `<button class="type-card${selType === t.id ? " selected" : ""}" onclick="selType='${t.id}';renderAddSheet()" style="padding:10px;border:1px solid var(--line);border-radius:14px;background:${selType === t.id ? "rgba(122,183,255,.15)" : "rgba(255,255,255,.04)"};color:var(--text);text-align:center"><div style="font-size:20px">${t.icon}</div><div style="font-size:12px;color:var(--muted)">${t.desc}</div></button>`;
    });
    h +=
      '</div><div class="eyebrow">Lifecycle</div><div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px;margin-bottom:12px">';
    lcs.forEach((l) => {
      h += `<button class="lc-card${selLc === l.id ? " selected" : ""}" onclick="selLc='${l.id}';renderAddSheet()" style="padding:10px;border:1px solid var(--line);border-radius:14px;background:${selLc === l.id ? "rgba(122,183,255,.15)" : "rgba(255,255,255,.04)"};color:var(--text);text-align:center"><div style="font-size:16px">${l.icon}</div><div style="font-size:11px;color:var(--muted)">${l.desc}</div></button>`;
    });
    h += "</div>";
    if (selType !== "task") {
      h +=
        '<div class="eyebrow">Subdomain</div><input id="add-sub" style="width:100%;padding:12px;border-radius:14px;border:1px solid var(--line);background:rgba(255,255,255,.04);color:var(--text);margin-bottom:8px" placeholder="' +
        esc(svcName || "myapp") +
        '" value="' +
        esc(subdomain) +
        '" oninput="subdomain=this.value;renderAddSheet()">';
      if (subdomain && PARENT_DOMAIN) {
        let fqdn = subdomain + "." + PARENT_DOMAIN;
        h +=
          '<div style="font-size:11px;color:var(--muted);margin-bottom:12px">→ ' +
          esc(fqdn) +
          "</div>";
      }
    }
    if (selType === "proxy" || selType === "split") {
      h +=
        '<div class="eyebrow">Upstream</div><input id="add-up" style="width:100%;padding:12px;border-radius:14px;border:1px solid var(--line);background:rgba(255,255,255,.04);color:var(--text);margin-bottom:12px" placeholder="127.0.0.1:8080" value="' +
        esc(upstream) +
        '" oninput="upstream=this.value">';
    }
    if (selType === "static" || selType === "split") {
      h +=
        '<div class="eyebrow">Root path</div><input id="add-root" style="width:100%;padding:12px;border-radius:14px;border:1px solid var(--line);background:rgba(255,255,255,.04);color:var(--text);margin-bottom:12px" placeholder="~/myapp/dist" value="' +
        esc(root) +
        '" oninput="root=this.value">';
    }
    if (selType === "split") {
      h +=
        '<div class="eyebrow">API path</div><input id="add-apipath" style="width:100%;padding:12px;border-radius:14px;border:1px solid var(--line);background:rgba(255,255,255,.04);color:var(--text);margin-bottom:12px" placeholder="/api" value="' +
        esc(apiPath) +
        '" oninput="apiPath=this.value">';
    }
    if (selType === "task" || selLc === "managed") {
      h +=
        '<div class="eyebrow">Binary</div><input id="add-bin" style="width:100%;padding:12px;border-radius:14px;border:1px solid var(--line);background:rgba(255,255,255,.04);color:var(--text);margin-bottom:12px" placeholder="/usr/local/bin/myapp" value="' +
        esc(bin) +
        '" oninput="bin=this.value">';
    }
    if (selLc === "custom") {
      h +=
        '<div class="eyebrow">Plist path</div><input id="add-plist" style="width:100%;padding:12px;border-radius:14px;border:1px solid var(--line);background:rgba(255,255,255,.04);color:var(--text);margin-bottom:12px" placeholder="~/Library/LaunchAgents/my.plist" value="' +
        esc(plistPath) +
        '" oninput="plistPath=this.value">';
    }
    if (selLc === "external")
      h +=
        '<div style="font-size:11px;color:var(--muted);margin-bottom:12px">This service must be started independently. Home-stack only provides the Caddy route.</div>';
    h +=
      '<button class="action" onclick="submitServiceAdd()" style="width:100%;margin-top:8px">Add Service</button></div>';
    $("sheet").innerHTML = h;
    $("sheet").classList.add("open");
    $("sheet-backdrop").classList.add("open");
    document.body.classList.add("sheet-open");
  }
  function submitServiceAdd() {
    if (!svcName) return alert("Name is required");
    const svc = { type: selType, lifecycle: selLc };
    if (subdomain) svc.subdomain = subdomain;
    if (upstream) svc.upstream = upstream;
    if (root) svc.root = root;
    if (selType === "split") svc.api_path = apiPath;
    if (bin) svc.binary = bin;
    if (plistPath) svc.plist = plistPath;
    api("/api/actions", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Home-Stack-Admin": "1" },
      body: JSON.stringify({
        action: "registry.add",
        target: svcName,
        confirm: true,
        service: svc,
      }),
    })
      .then(() => {
        closeSheet();
        loadAll();
      })
      .catch((e) => alert("Failed: " + e.message));
  }
  function openServiceEdit(name) {
    const s = state.services.find((x) => x.name === name);
    if (!s) return;
    selType = s.desired?.Type || "proxy";
    selLc = s.desired?.Lifecycle || "external";
    svcName = name;
    subdomain = s.desired?.Subdomain || "";
    upstream = s.desired?.Upstream || "";
    root = s.desired?.Root || "";
    apiPath = s.desired?.APIPath || "/api";
    bin = s.desired?.Binary || "";
    plistPath = s.desired?.Plist || "";
    renderAddSheet();
  }
}
loadAll();
setInterval(loadAll, 30000);
let sx = 0,
  sy = 0,
  sc = null;
document.addEventListener(
  "touchstart",
  (e) => {
    const c = e.target.closest(".service-card");
    if (c) {
      sc = c;
      sx = e.touches[0].clientX;
      sy = e.touches[0].clientY;
    }
  },
  { passive: true },
);
document.addEventListener(
  "touchmove",
  (e) => {
    if (!sc) return;
    const dx = e.touches[0].clientX - sx,
      dy = e.touches[0].clientY - sy;
    if (Math.abs(dx) > Math.abs(dy) && dx < -60) sc.classList.add("swiped");
    else sc.classList.remove("swiped");
  },
  { passive: true },
);
document.addEventListener("touchend", () => {
  setTimeout(() => {
    if (sc) sc.classList.remove("swiped");
    sc = null;
  }, 300);
});
$("status-bar").addEventListener(
  "dblclick",
  () => setStatus("syncing", "Refreshing…") || loadAll(),
);
