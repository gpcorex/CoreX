#!/usr/bin/env bash
set -euo pipefail

BASE="/home/ubuntu/Central/media_center/pwa"
OUT="/var/lib/conector/media-pwa-v1.txt"
CADDYFILE="/etc/caddy/Caddyfile"
BACKUP="/etc/caddy/Caddyfile.media-pwa-backup"

mkdir -p "$BASE" /var/lib/conector

cat > "$BASE/index.html" <<'HTML'
<!doctype html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
  <meta name="theme-color" content="#0b0d10">
  <link rel="manifest" href="./manifest.webmanifest">
  <title>Centro Multimedia</title>
  <style>
    :root{
      --bg:#0b0d10;--panel:#13171c;--panel2:#1b2027;--text:#f5f7fa;--muted:#9aa4af;
      --accent:#5eead4;--line:#272e36;--shadow:0 18px 50px rgba(0,0,0,.35);
    }
    *{box-sizing:border-box}
    body{margin:0;background:linear-gradient(180deg,#0b0d10 0%,#0d1117 45%,#0b0d10 100%);color:var(--text);font:15px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
    button,input{font:inherit}
    .shell{min-height:100vh;padding-bottom:92px}
    .top{position:sticky;top:0;z-index:10;display:flex;gap:14px;align-items:center;padding:14px 18px;background:rgba(11,13,16,.88);backdrop-filter:blur(14px);border-bottom:1px solid rgba(255,255,255,.05)}
    .brand{font-weight:800;letter-spacing:.2px;font-size:18px;white-space:nowrap}
    .brand b{color:var(--accent)}
    .search{flex:1;max-width:520px;margin-left:auto}
    .search input{width:100%;border:1px solid var(--line);background:#11151a;color:white;border-radius:12px;padding:10px 12px;outline:none}
    .hero{margin:18px;min-height:310px;border-radius:24px;padding:26px;display:flex;align-items:flex-end;position:relative;overflow:hidden;background:
      radial-gradient(circle at 80% 10%,rgba(94,234,212,.18),transparent 34%),
      linear-gradient(135deg,#192028,#10151a 55%,#0d1014);box-shadow:var(--shadow);border:1px solid rgba(255,255,255,.06)}
    .hero:after{content:"";position:absolute;inset:0;background:linear-gradient(90deg,rgba(0,0,0,.05),rgba(0,0,0,.5))}
    .hero-copy{position:relative;z-index:1;max-width:620px}
    .eyebrow{font-size:12px;text-transform:uppercase;letter-spacing:1.6px;color:var(--accent);font-weight:800}
    h1{font-size:clamp(34px,8vw,64px);line-height:.95;margin:8px 0 14px}
    .hero p{max-width:560px;color:#c6ced7;margin:0 0 18px}
    .actions{display:flex;gap:10px;flex-wrap:wrap}
    .btn{border:0;border-radius:11px;padding:10px 15px;font-weight:700}
    .primary{background:var(--accent);color:#06110f}
    .ghost{background:#242b33;color:white}
    .status{margin:0 18px 20px;padding:12px 14px;background:#10151a;border:1px solid var(--line);border-radius:14px;display:flex;gap:10px;align-items:center;color:var(--muted)}
    .dot{width:9px;height:9px;border-radius:50%;background:#f5a524;box-shadow:0 0 16px currentColor}
    .dot.ok{background:#39d98a}
    .section{margin:26px 0}
    .section-head{display:flex;align-items:end;justify-content:space-between;padding:0 18px 10px}
    .section h2{font-size:20px;margin:0}
    .section small{color:var(--muted)}
    .rail{display:grid;grid-auto-flow:column;grid-auto-columns:minmax(150px,42vw);gap:12px;overflow-x:auto;padding:0 18px 8px;scroll-snap-type:x proximity}
    .card{scroll-snap-align:start;background:var(--panel);border:1px solid rgba(255,255,255,.055);border-radius:16px;overflow:hidden;min-height:230px}
    .poster{aspect-ratio:2/3;background:linear-gradient(145deg,#29323b,#151a20);position:relative}
    .poster img{width:100%;height:100%;object-fit:cover;display:block}
    .badge{position:absolute;top:9px;left:9px;background:rgba(0,0,0,.7);padding:5px 7px;border-radius:7px;font-size:11px}
    .meta{padding:10px 11px 12px}
    .meta strong{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .meta span{font-size:12px;color:var(--muted)}
    .empty{margin:0 18px;padding:24px;border:1px dashed #33404c;border-radius:16px;color:var(--muted)}
    .bottom{position:fixed;z-index:20;bottom:0;left:0;right:0;display:grid;grid-template-columns:repeat(5,1fr);padding:8px 8px calc(8px + env(safe-area-inset-bottom));background:rgba(13,16,20,.95);backdrop-filter:blur(15px);border-top:1px solid var(--line)}
    .tab{background:transparent;border:0;color:#8f99a5;padding:7px 4px;font-size:11px}
    .tab.active{color:var(--accent);font-weight:800}
    .tab span{display:block;font-size:18px;margin-bottom:2px}
    @media(min-width:800px){
      .rail{grid-auto-columns:190px}
      .hero{min-height:410px;padding:42px}
      .bottom{left:50%;right:auto;transform:translateX(-50%);width:min(560px,90%);bottom:16px;border:1px solid var(--line);border-radius:18px}
    }
  </style>
</head>
<body>
<div class="shell">
  <header class="top">
    <div class="brand">Centro <b>Multimedia</b></div>
    <div class="search"><input id="search" placeholder="Buscar películas, series, anime…"></div>
  </header>

  <section class="hero">
    <div class="hero-copy">
      <div class="eyebrow">Vista previa</div>
      <h1>Todo en un solo lugar.</h1>
      <p>Películas, series, anime y TV en vivo en una interfaz única. Esta PWA usa la misma API que la app Android.</p>
      <div class="actions">
        <button class="btn primary" onclick="document.querySelector('#catalog').scrollIntoView({behavior:'smooth'})">Explorar</button>
        <button class="btn ghost" onclick="location.reload()">Actualizar</button>
      </div>
    </div>
  </section>

  <div class="status"><span id="dot" class="dot"></span><span id="statusText">Conectando con la API…</span></div>

  <section id="catalog" class="section">
    <div class="section-head"><h2>Destacados</h2><small id="videoCount"></small></div>
    <div id="featured" class="rail"></div>
  </section>

  <section class="section">
    <div class="section-head"><h2>Series y anime</h2><small>Diseño</small></div>
    <div id="series" class="rail"></div>
  </section>

  <section class="section">
    <div class="section-head"><h2>TV en vivo</h2><small id="liveCount"></small></div>
    <div id="live" class="rail"></div>
  </section>
</div>

<nav class="bottom">
  <button class="tab active"><span>⌂</span>Inicio</button>
  <button class="tab"><span>⌕</span>Buscar</button>
  <button class="tab"><span>▶</span>TV</button>
  <button class="tab"><span>♥</span>Favoritos</button>
  <button class="tab"><span>☻</span>Perfil</button>
</nav>

<script>
const API = "/media-api";

const demo = [
  {title:"Película destacada",kind:"movie"},
  {title:"Thriller nocturno",kind:"movie"},
  {title:"Serie recomendada",kind:"series"},
  {title:"Anime destacado",kind:"anime"},
  {title:"Estreno de la semana",kind:"movie"}
];

function esc(s){return String(s??"").replace(/[&<>"']/g,m=>({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"}[m]))}
function card(item,label){
  const img=item.poster_url?'<img loading="lazy" src="'+esc(item.poster_url)+'" alt="">':'';
  return '<article class="card" data-title="'+esc((item.title||item.name||"").toLowerCase())+'"><div class="poster">'+img+'<span class="badge">'+esc(label||item.kind||item.quality||"")+'</span></div><div class="meta"><strong>'+esc(item.title||item.name||"Sin título")+'</strong><span>'+esc(item.kind||item.quality||"")+'</span></div></article>';
}
function render(id,items,label){document.getElementById(id).innerHTML=items.map(x=>card(x,label)).join("")}

async function load(){
  try{
    const [h,v,l]=await Promise.all([
      fetch(API+"/health").then(r=>r.json()),
      fetch(API+"/video/items?limit=30").then(r=>r.json()),
      fetch(API+"/live/channels").then(r=>r.json())
    ]);
    document.getElementById("dot").classList.add("ok");
    document.getElementById("statusText").textContent="API conectada · catálogo real: "+h.video_items+" videos · "+h.live_channels+" canales";
    const items=v.items||[], live=l.channels||[];
    document.getElementById("videoCount").textContent=items.length+" títulos";
    document.getElementById("liveCount").textContent=live.length+" canales";

    if(items.length){
      render("featured",items.slice(0,12));
      render("series",items.filter(x=>x.kind==="series"||x.kind==="anime").slice(0,12));
    }else{
      render("featured",demo,"demo");
      render("series",demo.filter(x=>x.kind!=="movie"),"demo");
    }

    if(live.length){
      render("live",live,"en vivo");
    }else{
      render("live",[
        {name:"Canal de muestra",quality:"HD"},
        {name:"Noticias",quality:"FHD"},
        {name:"Películas",quality:"HD"}
      ],"demo");
    }
  }catch(e){
    document.getElementById("statusText").textContent="No se pudo conectar con la API. Mostrando modo diseño.";
    render("featured",demo,"demo");
    render("series",demo.filter(x=>x.kind!=="movie"),"demo");
    render("live",[{name:"Canal de muestra",quality:"HD"},{name:"Noticias",quality:"FHD"}],"demo");
  }
}

document.getElementById("search").addEventListener("input",e=>{
  const q=e.target.value.toLowerCase().trim();
  document.querySelectorAll(".card").forEach(c=>c.style.display=!q||c.dataset.title.includes(q)?"":"none");
});
load();
if("serviceWorker" in navigator) navigator.serviceWorker.register("./sw.js").catch(()=>{});
</script>
</body>
</html>
HTML

cat > "$BASE/manifest.webmanifest" <<'JSON'
{
  "name":"Centro Multimedia",
  "short_name":"Multimedia",
  "start_url":"./",
  "display":"standalone",
  "background_color":"#0b0d10",
  "theme_color":"#0b0d10"
}
JSON

cat > "$BASE/sw.js" <<'JS'
const CACHE="centro-multimedia-pwa-v1";
self.addEventListener("install",e=>e.waitUntil(caches.open(CACHE).then(c=>c.addAll(["./","./index.html","./manifest.webmanifest"]))));
self.addEventListener("fetch",e=>{
  if(e.request.url.includes("/media-api/")) return;
  e.respondWith(caches.match(e.request).then(r=>r||fetch(e.request)));
});
JS

cat > /etc/systemd/system/media-pwa.service <<EOF
[Unit]
Description=Centro Multimedia PWA
After=network-online.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=$BASE
ExecStart=/usr/bin/python3 -m http.server 8093 --bind 127.0.0.1
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now media-pwa.service

cp "$CADDYFILE" "$BACKUP"
python3 - <<'PY'
from pathlib import Path
p=Path("/etc/caddy/Caddyfile")
s=p.read_text()
marker="# MEDIA_PWA_V1"
block="""
    # MEDIA_PWA_V1
    handle_path /multimedia/* {
        reverse_proxy 127.0.0.1:8093
    }
"""
if marker not in s:
    i=s.rfind("}")
    if i<0: raise SystemExit("CADDY_ROOT_BLOCK_NOT_FOUND")
    s=s[:i]+block+"\n"+s[i:]
    p.write_text(s)
PY

caddy validate --config "$CADDYFILE"
systemctl reload caddy
sleep 1

LOCAL="$(curl -fsS http://127.0.0.1:8093/ | grep -o 'Centro Multimedia' | head -1)"
PUBLIC_CODE="$(curl -ksS -o /tmp/media-pwa-public.html -w '%{http_code}' https://cen-tral.duckdns.org/multimedia/)"
PUBLIC_MARK="$(grep -o 'Centro Multimedia' /tmp/media-pwa-public.html | head -1 || true)"

{
  echo "MEDIA_PWA_V1_READY"
  echo "service=$(systemctl is-active media-pwa.service)"
  echo "local_marker=$LOCAL"
  echo "public_http=$PUBLIC_CODE"
  echo "public_marker=$PUBLIC_MARK"
  echo "url=https://cen-tral.duckdns.org/multimedia/"
  echo "path=$BASE"
} > "$OUT"

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-pwa-v1.txt" || true
fi

echo "MEDIA_PWA_V1_READY"
