#!/usr/bin/env bash
set -euo pipefail

BASE="/home/ubuntu/Central/media_center"
API="$BASE/video/catalog_service.py"
PWA="$BASE/pwa"
OUT="/var/lib/conector/media-pwa-player-v1.txt"

mkdir -p "$PWA" /var/lib/conector

python3 - "$API" <<'PY'
from pathlib import Path
p=Path(__import__("sys").argv[1])
s=p.read_text()

if 'if u.path == "/video/playback":' not in s:
    marker='''        if u.path.startswith("/video/item/"):
'''
    block='''        if u.path == "/video/playback":
            playable_type = q.get("type", ["item"])[0]
            playable_id = q.get("id", [""])[0].strip()
            if playable_type not in ("item", "episode") or not playable_id:
                self.send_json(400, {"error": "bad_request"})
                return
            data = rows(
                """SELECT id,playable_type,playable_id,provider,provider_media_code,
                          quality,language,format,priority,weight,resolver_key,resolver_ref,
                          drm_hint
                   FROM playback_source
                   WHERE playable_type=? AND playable_id=? AND active=1
                   ORDER BY priority DESC, weight DESC, id""",
                (playable_type, playable_id)
            )
            resolved = []
            for src in data:
                item = dict(src)
                key = (item.get("resolver_key") or "").lower()
                ref = item.get("resolver_ref")
                if key in ("direct_url", "url", "http") and isinstance(ref, str) and ref.startswith(("http://","https://")):
                    item["playable_url"] = ref
                    item["browser_direct"] = True
                else:
                    item["playable_url"] = None
                    item["browser_direct"] = False
                resolved.append(item)
            self.send_json(200, {"type": playable_type, "id": playable_id, "sources": resolved, "count": len(resolved)})
            return

'''
    if marker not in s:
        raise SystemExit("catalog_service marker not found")
    s=s.replace(marker,block+marker,1)
    p.write_text(s)
PY

cat > "$PWA/player-test.html" <<'HTML'
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>Centro Multimedia · Player</title>
<style>
:root{color-scheme:dark;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
*{box-sizing:border-box}body{margin:0;background:#0b0d12;color:#f5f7fb}
main{max-width:980px;margin:auto;padding:18px}.top{display:flex;align-items:center;gap:12px;margin-bottom:18px}
a{color:#fff;text-decoration:none}.box{background:#151923;border:1px solid #272d3a;border-radius:18px;padding:16px;margin-bottom:14px}
h1{font-size:22px;margin:0}h2{font-size:16px;margin:0 0 12px}.row{display:flex;gap:8px;flex-wrap:wrap}
input,button{font:inherit;border-radius:12px;border:1px solid #343b4b;padding:12px}
input{background:#0d1118;color:#fff;flex:1;min-width:240px}button{background:#fff;color:#111;font-weight:700;cursor:pointer}
video{width:100%;max-height:70vh;background:#000;border-radius:14px;margin-top:12px}
small,#status{color:#aeb6c7}.ok{color:#88e0a3}.bad{color:#ff9b9b}
code{word-break:break-all}
</style>
</head>
<body>
<main>
<div class="top"><a href="./">← Inicio</a><h1>Prueba de reproducción</h1></div>

<div class="box">
  <h2>Fuente directa</h2>
  <div class="row"><input id="url" placeholder="https://...mp4 / .m3u8"><button id="play">Reproducir</button></div>
  <div id="status">Pegá una URL directa compatible con navegador.</div>
  <video id="video" controls playsinline preload="metadata"></video>
</div>

<div class="box">
  <h2>Fuente desde catálogo</h2>
  <div class="row">
    <input id="itemId" placeholder="ID del item o episodio">
    <select id="ptype" style="border-radius:12px;background:#0d1118;color:#fff;border:1px solid #343b4b;padding:12px">
      <option value="item">item</option><option value="episode">episode</option>
    </select>
    <button id="resolve">Resolver</button>
  </div>
  <pre id="result" style="white-space:pre-wrap"></pre>
</div>
</main>
<script>
const API="/media-api";
const v=document.getElementById("video"), st=document.getElementById("status");
function playUrl(url){
  if(!url){st.textContent="Falta URL.";st.className="bad";return}
  v.pause();v.removeAttribute("src");v.load();
  v.src=url;
  st.textContent="Intentando abrir: "+url;st.className="";
  v.play().then(()=>{st.textContent="Reproduciendo.";st.className="ok"}).catch(e=>{
    st.textContent="El navegador no pudo iniciar esta fuente: "+e.message;st.className="bad";
  });
}
document.getElementById("play").onclick=()=>playUrl(document.getElementById("url").value.trim());
v.addEventListener("error",()=>{st.textContent="Error de reproducción del navegador. Puede ser formato, CORS, DRM o URL temporal.";st.className="bad"});
document.getElementById("resolve").onclick=async()=>{
  const id=document.getElementById("itemId").value.trim();
  const type=document.getElementById("ptype").value;
  const el=document.getElementById("result");
  if(!id){el.textContent="Falta ID.";return}
  try{
    const r=await fetch(API+"/video/playback?type="+encodeURIComponent(type)+"&id="+encodeURIComponent(id));
    const j=await r.json();el.textContent=JSON.stringify(j,null,2);
    const direct=(j.sources||[]).find(x=>x.browser_direct&&x.playable_url);
    if(direct){document.getElementById("url").value=direct.playable_url;playUrl(direct.playable_url)}
  }catch(e){el.textContent=String(e)}
};
</script>
</body>
</html>
HTML

sudo systemctl restart media-catalog.service
sleep 1

{
  echo "MEDIA_PWA_PLAYER_V1_READY"
  echo "timestamp=$(date -Is)"
  echo "api_health=$(curl -fsS http://127.0.0.1:8092/health || true)"
  echo "playback_probe=$(curl -fsS 'http://127.0.0.1:8092/video/playback?type=item&id=missing-test' || true)"
  echo "player_local_http=$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8093/player-test.html || true)"
  echo "player_public_http=$(curl -sS -o /dev/null -w '%{http_code}' https://cen-tral.duckdns.org/multimedia/player-test.html || true)"
  echo "url=https://cen-tral.duckdns.org/multimedia/player-test.html"
} > "$OUT"

chmod 600 "$OUT"
if command -v conector-publish-result >/dev/null 2>&1; then
  conector-publish-result "$OUT" "vm-results/media-pwa-player-v1.txt" || true
fi

cat "$OUT"
