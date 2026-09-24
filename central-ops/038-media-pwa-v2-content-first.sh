#!/usr/bin/env bash
set -euo pipefail

BASE="/home/ubuntu/Central/media_center/pwa"
OUT="/var/lib/conector/media-pwa-v2.txt"
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
  --bg:#0b0d10;--panel:#151a20;--panel2:#1d232b;--text:#f5f7fa;--muted:#99a3ae;
  --accent:#5eead4;--line:#27303a;--navh:74px
}
*{box-sizing:border-box}
html,body{margin:0;background:var(--bg);color:var(--text);font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
body{min-height:100vh;padding-bottom:calc(var(--navh) + env(safe-area-inset-bottom))}
button,input{font:inherit}
.top{
  position:sticky;top:0;z-index:20;
  display:flex;align-items:center;gap:12px;
  padding:13px 16px;
  background:rgba(11,13,16,.96);
  border-bottom:1px solid rgba(255,255,255,.05);
  backdrop-filter:blur(14px)
}
.brand{font-size:19px;font-weight:850;white-space:nowrap}
.brand b{color:var(--accent)}
.search{flex:1;max-width:560px;margin-left:auto}
.search input{
  width:100%;border:1px solid var(--line);background:#11151a;color:#fff;
  border-radius:13px;padding:10px 12px;outline:none
}
.mobile-sections{
  display:flex;gap:8px;overflow:auto;padding:12px 16px 4px;scrollbar-width:none
}
.pill{
  flex:0 0 auto;border:1px solid var(--line);background:#12171c;color:#c6ced7;
  border-radius:999px;padding:9px 13px;font-weight:750
}
.pill.active{background:var(--accent);color:#06110f;border-color:var(--accent)}
.status{
  margin:10px 16px 2px;
  display:flex;align-items:center;gap:8px;color:var(--muted);font-size:12px
}
.dot{width:8px;height:8px;border-radius:50%;background:#f5a524}
.dot.ok{background:#39d98a}
.view{display:none}
.view.active{display:block}
.section{margin:19px 0 25px}
.section-head{display:flex;align-items:end;justify-content:space-between;padding:0 16px 9px}
.section h2{font-size:21px;margin:0}
.section small{color:var(--muted)}
.rail{
  display:grid;grid-auto-flow:column;grid-auto-columns:minmax(145px,42vw);
  gap:12px;overflow-x:auto;padding:0 16px 8px;scroll-snap-type:x proximity
}
.grid{
  display:grid;grid-template-columns:repeat(2,minmax(0,1fr));
  gap:12px;padding:0 16px 18px
}
.card{
  scroll-snap-align:start;background:var(--panel);
  border:1px solid rgba(255,255,255,.055);border-radius:15px;overflow:hidden
}
.poster{aspect-ratio:2/3;background:linear-gradient(145deg,#29323b,#151a20);position:relative}
.poster img{width:100%;height:100%;object-fit:cover;display:block}
.badge{
  position:absolute;top:8px;left:8px;background:rgba(0,0,0,.72);
  padding:4px 7px;border-radius:7px;font-size:10px
}
.meta{padding:9px 10px 11px}
.meta strong{display:block;font-size:14px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.meta span{font-size:11px;color:var(--muted)}
.empty{margin:0 16px;padding:22px;border:1px dashed #33404c;border-radius:15px;color:var(--muted)}
.bottom{
  position:fixed;z-index:30;left:0;right:0;bottom:0;
  display:grid;grid-template-columns:repeat(5,1fr);
  padding:7px 6px calc(7px + env(safe-area-inset-bottom));
  background:rgba(12,15,19,.97);border-top:1px solid var(--line);backdrop-filter:blur(14px)
}
.tab{border:0;background:transparent;color:#919ba7;padding:5px 2px;font-size:11px}
.tab span{display:block;font-size:18px;margin-bottom:2px}
.tab.active{color:var(--accent);font-weight:800}

/* TV / landscape shell */
.tv-sidebar,.tv-top{display:none}
@media (orientation:landscape) and (min-width:700px){
  body{padding:0 0 0 190px}
  .top,.mobile-sections,.bottom{display:none}
  .tv-sidebar{
    display:flex;position:fixed;left:0;top:0;bottom:0;width:190px;z-index:40;
    flex-direction:column;gap:8px;padding:24px 14px;
    background:#0d1115;border-right:1px solid var(--line)
  }
  .tv-sidebar .brand{margin-bottom:18px}
  .tv-nav{
    border:0;background:transparent;color:#aab3bd;text-align:left;
    padding:12px 13px;border-radius:11px;font-weight:750
  }
  .tv-nav.active{background:#1c252c;color:var(--accent)}
  .tv-top{
    display:flex;align-items:center;padding:18px 22px 6px;gap:16px
  }
  .tv-top h1{font-size:28px;margin:0}
  .tv-top .search{margin-left:auto}
  .status{margin:6px 22px 8px}
  .section-head{padding:0 22px 11px}
  .rail{
    grid-auto-columns:190px;gap:15px;padding:0 22px 10px
  }
  .grid{grid-template-columns:repeat(5,minmax(0,1fr));gap:15px;padding:0 22px 24px}
  .section{margin:22px 0 30px}
}

/* Wide TV-like screens with remote/no hover */
@media (min-width:1000px) and (pointer:coarse){
  body{padding-left:210px}
  .tv-sidebar{width:210px}
  .rail{grid-auto-columns:210px}
  .grid{grid-template-columns:repeat(5,minmax(0,1fr))}
}
</style>
</head>
<body>

<aside class="tv-sidebar">
  <div class="brand">Centro <b>Multimedia</b></div>
  <button class="tv-nav active" data-view="home">Inicio</button>
  <button class="tv-nav" data-view="movies">Películas</button>
  <button class="tv-nav" data-view="series">Series</button>
  <button class="tv-nav" data-view="searchView">Buscar</button>
  <button class="tv-nav" data-view="liveView">TV en vivo</button>
</aside>

<header class="top">
  <div class="brand">Centro <b>Multimedia</b></div>
  <div class="search"><input id="searchTop" placeholder="Buscar…"></div>
</header>

<div class="tv-top">
  <h1 id="tvTitle">Inicio</h1>
  <div class="search"><input id="searchTv" placeholder="Buscar películas, series, anime…"></div>
</div>

<div class="mobile-sections">
  <button class="pill active" data-view="home">Inicio</button>
  <button class="pill" data-view="movies">Películas</button>
  <button class="pill" data-view="series">Series</button>
  <button class="pill" data-view="liveView">TV</button>
</div>

<div class="status"><span id="dot" class="dot"></span><span id="statusText">Conectando…</span></div>

<main>
  <section id="home" class="view active">
    <div class="section">
      <div class="section-head"><h2>Películas</h2><small id="movieCount"></small></div>
      <div id="homeMovies" class="rail"></div>
    </div>
    <div class="section">
      <div class="section-head"><h2>Series</h2><small id="seriesCount"></small></div>
      <div id="homeSeries" class="rail"></div>
    </div>
    <div class="section">
      <div class="section-head"><h2>Anime</h2><small id="animeCount"></small></div>
      <div id="homeAnime" class="rail"></div>
    </div>
    <div class="section">
      <div class="section-head"><h2>TV en vivo</h2><small id="liveCount"></small></div>
      <div id="homeLive" class="rail"></div>
    </div>
  </section>

  <section id="movies" class="view">
    <div class="section"><div class="section-head"><h2>Películas</h2></div><div id="moviesGrid" class="grid"></div></div>
  </section>

  <section id="series" class="view">
    <div class="section"><div class="section-head"><h2>Series y anime</h2></div><div id="seriesGrid" class="grid"></div></div>
  </section>

  <section id="searchView" class="view">
    <div class="section"><div class="section-head"><h2>Buscar</h2></div><div id="searchGrid" class="grid"></div></div>
  </section>

  <section id="liveView" class="view">
    <div class="section"><div class="section-head"><h2>TV en vivo</h2></div><div id="liveGrid" class="grid"></div></div>
  </section>
</main>

<nav class="bottom">
  <button class="tab active" data-view="home"><span>⌂</span>Inicio</button>
  <button class="tab" data-view="movies"><span>▣</span>Películas</button>
  <button class="tab" data-view="series"><span>▤</span>Series</button>
  <button class="tab" data-view="searchView"><span>⌕</span>Buscar</button>
  <button class="tab" data-view="liveView"><span>▶</span>TV</button>
</nav>

<script>
const API="/media-api";
let allVideos=[],allLive=[];

const demoMovies=[
 {title:"Película 1",kind:"movie"},{title:"Película 2",kind:"movie"},{title:"Película 3",kind:"movie"},
 {title:"Película 4",kind:"movie"},{title:"Película 5",kind:"movie"}
];
const demoSeries=[
 {title:"Serie 1",kind:"series"},{title:"Serie 2",kind:"series"},{title:"Anime 1",kind:"anime"},
 {title:"Serie 3",kind:"series"},{title:"Anime 2",kind:"anime"}
];
const demoLive=[
 {name:"Canal 1",quality:"HD"},{name:"Canal 2",quality:"FHD"},{name:"Canal 3",quality:"HD"}
];

function esc(s){return String(s??"").replace(/[&<>"']/g,m=>({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"}[m]))}
function card(x,label){
 const img=x.poster_url?'<img loading="lazy" src="'+esc(x.poster_url)+'" alt="">':'';
 const title=x.title||x.name||"Sin título";
 return '<article class="card" data-title="'+esc(title.toLowerCase())+'"><div class="poster">'+img+'<span class="badge">'+esc(label||x.kind||x.quality||"")+'</span></div><div class="meta"><strong>'+esc(title)+'</strong><span>'+esc(x.kind||x.quality||"")+'</span></div></article>';
}
function fill(id,arr,label){document.getElementById(id).innerHTML=arr.map(x=>card(x,label)).join("")}

function render(){
 const movies=allVideos.filter(x=>x.kind==="movie");
 const series=allVideos.filter(x=>x.kind==="series");
 const anime=allVideos.filter(x=>x.kind==="anime");

 const dm=movies.length?movies:demoMovies;
 const ds=(series.length||anime.length)?series:demoSeries.filter(x=>x.kind==="series");
 const da=anime.length?anime:demoSeries.filter(x=>x.kind==="anime");
 const dl=allLive.length?allLive:demoLive;

 fill("homeMovies",dm.slice(0,12),movies.length?"":"demo");
 fill("homeSeries",ds.slice(0,12),(series.length||anime.length)?"":"demo");
 fill("homeAnime",da.slice(0,12),anime.length?"":"demo");
 fill("homeLive",dl.slice(0,12),allLive.length?"en vivo":"demo");

 fill("moviesGrid",dm,movies.length?"":"demo");
 fill("seriesGrid",[...ds,...da],(series.length||anime.length)?"":"demo");
 fill("liveGrid",dl,allLive.length?"en vivo":"demo");

 document.getElementById("movieCount").textContent=movies.length+" títulos";
 document.getElementById("seriesCount").textContent=series.length+" títulos";
 document.getElementById("animeCount").textContent=anime.length+" títulos";
 document.getElementById("liveCount").textContent=allLive.length+" canales";
}

function setView(id){
 document.querySelectorAll(".view").forEach(v=>v.classList.toggle("active",v.id===id));
 document.querySelectorAll("[data-view]").forEach(b=>b.classList.toggle("active",b.dataset.view===id));
 const names={home:"Inicio",movies:"Películas",series:"Series",searchView:"Buscar",liveView:"TV en vivo"};
 document.getElementById("tvTitle").textContent=names[id]||"Centro Multimedia";
 window.scrollTo({top:0,behavior:"smooth"});
}
document.querySelectorAll("[data-view]").forEach(b=>b.addEventListener("click",()=>setView(b.dataset.view)));

function doSearch(q){
 q=q.trim().toLowerCase();
 setView("searchView");
 if(!q){
   document.getElementById("searchGrid").innerHTML='<div class="empty">Escribí algo para buscar.</div>';
   return;
 }
 const pool=allVideos.length?allVideos:[...demoMovies,...demoSeries];
 const found=pool.filter(x=>(x.title||x.name||"").toLowerCase().includes(q));
 document.getElementById("searchGrid").innerHTML=found.length?found.map(x=>card(x,allVideos.length?"":"demo")).join(""):'<div class="empty">No encontramos resultados.</div>';
}
["searchTop","searchTv"].forEach(id=>{
 document.getElementById(id).addEventListener("keydown",e=>{if(e.key==="Enter") doSearch(e.target.value)});
});

async function load(){
 try{
   const [h,v,l]=await Promise.all([
     fetch(API+"/health").then(r=>r.json()),
     fetch(API+"/video/items?limit=100").then(r=>r.json()),
     fetch(API+"/live/channels").then(r=>r.json())
   ]);
   allVideos=v.items||[]; allLive=l.channels||[];
   document.getElementById("dot").classList.add("ok");
   document.getElementById("statusText").textContent="Conectado · "+h.video_items+" videos · "+h.live_channels+" canales";
 }catch(e){
   document.getElementById("statusText").textContent="Modo diseño · API no disponible";
 }
 render();
}
load();
if("serviceWorker" in navigator) navigator.serviceWorker.register("./sw.js").catch(()=>{});
</script>
</body>
</html>
HTML

cat > "$BASE/sw.js" <<'JS'
const CACHE="centro-multimedia-pwa-v2";
self.addEventListener("install",e=>e.waitUntil(caches.open(CACHE).then(c=>c.addAll(["./","./index.html","./manifest.webmanifest"])).then(()=>self.skipWaiting())));
self.addEventListener("activate",e=>e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
self.addEventListener("fetch",e=>{
  if(e.request.url.includes("/media-api/")) return;
  e.respondWith(fetch(e.request).catch(()=>caches.match(e.request)));
});
JS

systemctl restart media-pwa.service
sleep 1
LOCAL="$(curl -fsS http://127.0.0.1:8093/ | grep -o 'Centro Multimedia' | head -1)"
PUBLIC_CODE="$(curl -ksS -o /tmp/media-pwa-v2.html -w '%{http_code}' https://cen-tral.duckdns.org/multimedia/)"
PUBLIC_MARK="$(grep -o 'Centro Multimedia' /tmp/media-pwa-v2.html | head -1 || true)"

{
 echo "MEDIA_PWA_V2_READY"
 echo "service=$(systemctl is-active media-pwa.service)"
 echo "local_marker=$LOCAL"
 echo "public_http=$PUBLIC_CODE"
 echo "public_marker=$PUBLIC_MARK"
 echo "url=https://cen-tral.duckdns.org/multimedia/"
 echo "layout=content-first responsive phone-landscape-tv"
} > "$OUT"

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-pwa-v2.txt" || true
fi

echo "MEDIA_PWA_V2_READY"
