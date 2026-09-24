#!/usr/bin/env bash
set -euo pipefail

PWA="/home/ubuntu/Central/media_center/pwa/index.html"
OUT="/var/lib/conector/media-pwa-detail-play-v1.txt"
mkdir -p /var/lib/conector

python3 - "$PWA" <<'PY'
from pathlib import Path
import sys,re
p=Path(sys.argv[1])
s=p.read_text()

if 'async function openPlayable(id)' not in s:
    marker='async function load(){'
    block=r'''
async function openPlayable(id){
  if(!id) return;
  try{
    const item=await fetch(API+"/video/item/"+encodeURIComponent(id)).then(r=>r.json());
    const pb=await fetch(API+"/video/playback?type=item&id="+encodeURIComponent(id)).then(r=>r.json());
    const src=(pb.sources||[]).find(x=>x.browser_direct&&x.playable_url);
    let modal=document.getElementById("playModal");
    if(!modal){
      modal=document.createElement("div");
      modal.id="playModal";
      modal.style.cssText="position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,.88);display:flex;align-items:center;justify-content:center;padding:18px";
      modal.innerHTML='<div style="width:min(920px,100%);background:#151923;border:1px solid #2b3240;border-radius:20px;padding:16px"><div style="display:flex;justify-content:space-between;gap:12px;align-items:center"><div><div id="pmTitle" style="font-size:22px;font-weight:800"></div><div id="pmMeta" style="color:#aeb6c7;margin-top:4px"></div></div><button id="pmClose" style="border:0;border-radius:12px;padding:10px 14px;font-weight:800">Cerrar</button></div><div id="pmMsg" style="margin:14px 0;color:#c6cedd"></div><video id="pmVideo" controls playsinline preload="metadata" style="display:none;width:100%;max-height:70vh;background:#000;border-radius:14px"></video></div>';
      document.body.appendChild(modal);
      modal.querySelector("#pmClose").onclick=()=>{const v=modal.querySelector("#pmVideo");v.pause();v.removeAttribute("src");v.load();modal.remove()};
    }
    modal.querySelector("#pmTitle").textContent=item.title||item.name||id;
    modal.querySelector("#pmMeta").textContent=(item.kind||"")+" · "+id;
    const msg=modal.querySelector("#pmMsg");
    const video=modal.querySelector("#pmVideo");
    if(src){
      msg.textContent="Fuente resuelta · "+(src.provider||"provider")+" · "+(src.format||"");
      video.style.display="block";
      video.src=src.playable_url;
      video.play().catch(()=>{});
    }else{
      msg.textContent=(pb.count||0)+" fuente(s) encontradas, pero ninguna es directa y reproducible por navegador.";
      video.style.display="none";
    }
  }catch(e){
    alert("No se pudo abrir el contenido: "+e.message);
  }
}

document.addEventListener("click",e=>{
  const card=e.target.closest("[data-item-id]");
  if(card) openPlayable(card.dataset.itemId);
});

'''
    if marker not in s:
        raise SystemExit("load marker not found")
    s=s.replace(marker,block+marker,1)

m=re.search(r'function card\(x,label\)\{([^}]*)\}',s,re.S)
if m and 'data-item-id' not in m.group(0):
    body=m.group(0)
    body2=body.replace('<div class="card"', '<div class="card" data-item-id="${x.id||\'\'}"',1)
    s=s.replace(body,body2,1)

if 'function annotatePlayableCards()' not in s:
    marker='function setView(id){'
    block=r'''
function annotatePlayableCards(){
  document.querySelectorAll(".card").forEach(el=>{
    if(el.dataset.itemId) return;
    const title=(el.querySelector(".title")||el.querySelector("h3")||el).textContent.trim();
    const hit=allVideos.find(x=>(x.title||x.name||"").trim()===title);
    if(hit&&hit.id) el.dataset.itemId=hit.id;
  });
}
'''
    if marker not in s:
        raise SystemExit("setView marker not found")
    s=s.replace(marker,block+marker,1)

if 'annotatePlayableCards();' not in s:
    s=s.replace(' render();\n}', ' render();\n annotatePlayableCards();\n}',1)

p.write_text(s)
PY

sudo systemctl restart media-pwa.service
sleep 1

{
  echo "MEDIA_PWA_DETAIL_PLAY_V1_READY"
  echo "timestamp=$(date -Is)"
  echo "local_http=$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8093/ || true)"
  echo "public_http=$(curl -sS -o /dev/null -w '%{http_code}' https://cen-tral.duckdns.org/multimedia/ || true)"
  echo "test_item=$(curl -fsS http://127.0.0.1:8092/video/item/test:pwa-direct-001 | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("title",""))' 2>/dev/null || true)"
  echo "url=https://cen-tral.duckdns.org/multimedia/"
  echo "NOTE=click a real catalog card to resolve and play its browser-direct source"
} > "$OUT"

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-pwa-detail-play-v1.txt" || true
fi

cat "$OUT"
