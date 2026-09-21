#!/usr/bin/env bash
set -euo pipefail

MAIN=/home/ubuntu/Gemini/app/main.py
UI=/home/ubuntu/Gemini/web/index.html
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Gemini/backups/ui-cleanup-$STAMP
mkdir -p "$BACKUP"
cp -a "$MAIN" "$BACKUP/main.py"
cp -a "$UI" "$BACKUP/index.html"

python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Gemini/app/main.py")
s=p.read_text(encoding="utf-8")

# 1) Cleaner Central answers: prefer human-readable fields before dumping JSON.
old='''                raw_result.get("final")
                or raw_result.get("answer")
                or raw_result.get("result")
                or json.dumps(raw_result, ensure_ascii=False)
'''
new='''                raw_result.get("final")
                or raw_result.get("answer")
                or raw_result.get("message")
                or raw_result.get("resultado")
                or raw_result.get("result")
                or json.dumps(raw_result, ensure_ascii=False)
'''
if old in s:
    s=s.replace(old,new,1)

# 2) Safe conversation deletion endpoint.
route='@app.post("/api/chat/direct")'
delete_block=r'''
@app.delete("/api/conversations/{cid}")
async def delete_conversation(cid: str):
    """Delete one conversation and its DB-linked rows. Does not delete arbitrary files from disk."""
    with db() as c:
        row = c.execute("SELECT id FROM conversations WHERE id=?", (cid,)).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="Conversación no encontrada")

        msg_rows = c.execute(
            "SELECT id FROM messages WHERE conversation_id=?",
            (cid,),
        ).fetchall()
        msg_ids = [r[0] for r in msg_rows]

        # Clean file DB rows when the schema supports it, without touching disk paths.
        try:
            cols = {r[1] for r in c.execute("PRAGMA table_info(files)").fetchall()}
            if "conversation_id" in cols:
                c.execute("DELETE FROM files WHERE conversation_id=?", (cid,))
            if "message_id" in cols and msg_ids:
                marks=",".join("?" for _ in msg_ids)
                c.execute(f"DELETE FROM files WHERE message_id IN ({marks})", msg_ids)
        except Exception:
            pass

        c.execute("DELETE FROM messages WHERE conversation_id=?", (cid,))
        c.execute("DELETE FROM conversations WHERE id=?", (cid,))

    return {"ok": True, "deleted_conversation_id": cid}

'''
if '@app.delete("/api/conversations/{cid}")' not in s:
    if route not in s:
        raise SystemExit("DIRECT_ROUTE_NOT_FOUND")
    s=s.replace(route,delete_block+"\n"+route,1)

p.write_text(s,encoding="utf-8")
print("BACKEND_UI_CLEANUP_OK")
PY

python3 -m py_compile "$MAIN"

python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Gemini/web/index.html")
s=p.read_text(encoding="utf-8")

css=r'''
<style id="gemini-chat-manager-style">
#gcmBtn{
  border:0;background:transparent;color:#b8bcc8;font-size:20px;line-height:1;
  padding:8px 10px;border-radius:10px;cursor:pointer;margin-left:8px
}
#gcmBtn:hover{background:#23262d;color:#fff}
#gcmOverlay{
  position:fixed;inset:0;background:rgba(0,0,0,.62);display:none;
  align-items:flex-end;justify-content:center;z-index:99999
}
#gcmOverlay.open{display:flex}
#gcmPanel{
  width:min(680px,100%);max-height:82vh;overflow:hidden;
  background:#15171c;border:1px solid #2a2e37;border-radius:20px 20px 0 0;
  box-shadow:0 -16px 50px rgba(0,0,0,.35)
}
#gcmHead{display:flex;align-items:center;justify-content:space-between;padding:18px 18px 12px}
#gcmHead h3{margin:0;font-size:18px}
#gcmClose{border:0;background:#252932;color:#fff;border-radius:10px;padding:8px 12px;font-size:18px}
#gcmList{overflow:auto;max-height:68vh;padding:0 12px 18px}
.gcmRow{
  display:flex;gap:12px;align-items:center;padding:12px 6px;border-top:1px solid #272b33
}
.gcmTitle{flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.gcmDel{
  border:1px solid #5a2c31;background:#2a181b;color:#ffb7bd;border-radius:10px;
  padding:8px 11px;font-size:14px
}
.gcmEmpty{padding:30px 12px;text-align:center;color:#9297a3}
</style>
'''

js=r'''
<script id="gemini-chat-manager-script">
(() => {
  const api = '/api/conversations';

  function mountButton(){
    if(document.getElementById('gcmBtn')) return;
    const header=document.querySelector('header') || document.querySelector('[class*="header"]');
    if(!header) return;
    const b=document.createElement('button');
    b.id='gcmBtn';
    b.type='button';
    b.title='Administrar conversaciones';
    b.setAttribute('aria-label','Administrar conversaciones');
    b.textContent='🗑';
    b.addEventListener('click',openManager);
    header.appendChild(b);
  }

  function ensureOverlay(){
    let o=document.getElementById('gcmOverlay');
    if(o) return o;
    o=document.createElement('div');
    o.id='gcmOverlay';
    o.innerHTML=`
      <div id="gcmPanel" role="dialog" aria-modal="true" aria-label="Conversaciones">
        <div id="gcmHead"><h3>Conversaciones</h3><button id="gcmClose">×</button></div>
        <div id="gcmList"><div class="gcmEmpty">Cargando…</div></div>
      </div>`;
    document.body.appendChild(o);
    o.addEventListener('click',e=>{if(e.target===o)o.classList.remove('open')});
    o.querySelector('#gcmClose').onclick=()=>o.classList.remove('open');
    return o;
  }

  async function loadRows(){
    const list=document.getElementById('gcmList');
    try{
      const r=await fetch(api,{cache:'no-store'});
      const data=await r.json();
      const rows=Array.isArray(data)?data:(data.conversations||data.items||[]);
      list.innerHTML='';
      if(!rows.length){
        list.innerHTML='<div class="gcmEmpty">No hay conversaciones guardadas.</div>';
        return;
      }
      rows.forEach(item=>{
        const id=String(item.id||item.conversation_id||'');
        if(!id)return;
        const title=String(item.title||item.name||'Conversación');
        const row=document.createElement('div');
        row.className='gcmRow';
        const t=document.createElement('div');
        t.className='gcmTitle';
        t.textContent=title;
        const d=document.createElement('button');
        d.className='gcmDel';
        d.textContent='Eliminar';
        d.onclick=async()=>{
          if(!confirm('¿Eliminar esta conversación?'))return;
          d.disabled=true;
          const rr=await fetch(api+'/'+encodeURIComponent(id),{method:'DELETE'});
          if(!rr.ok){
            d.disabled=false;
            alert('No se pudo eliminar la conversación.');
            return;
          }
          row.remove();
          // Refresh app state so the sidebar/current chat cannot keep stale data.
          setTimeout(()=>location.reload(),150);
        };
        row.append(t,d);
        list.appendChild(row);
      });
    }catch(e){
      list.innerHTML='<div class="gcmEmpty">No se pudieron cargar las conversaciones.</div>';
    }
  }

  async function openManager(){
    const o=ensureOverlay();
    o.classList.add('open');
    await loadRows();
  }

  if(document.readyState==='loading'){
    document.addEventListener('DOMContentLoaded',mountButton);
  }else{
    mountButton();
  }
  new MutationObserver(mountButton).observe(document.documentElement,{childList:true,subtree:true});
})();
</script>
'''

if 'gemini-chat-manager-style' not in s:
    pos=s.lower().find('</head>')
    if pos<0: raise SystemExit("HEAD_NOT_FOUND")
    s=s[:pos]+css+s[pos:]
if 'gemini-chat-manager-script' not in s:
    pos=s.lower().rfind('</body>')
    if pos<0: raise SystemExit("BODY_NOT_FOUND")
    s=s[:pos]+js+s[pos:]

p.write_text(s,encoding="utf-8")
print("UI_MANAGER_OK")
PY

# One controlled restart because main.py changed.
systemctl restart gemini-backend.service
for i in $(seq 1 30); do
  curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/gem-health-ui.json 2>/dev/null && break
  sleep 1
done

echo "=== HEALTH ==="
cat /tmp/gem-health-ui.json

echo
echo "=== DELETE ROUTE PRESENT ==="
grep -n '@app.delete("/api/conversations/{cid}")' "$MAIN"

echo
echo "=== UI PRESENT ==="
grep -n 'gemini-chat-manager-script' "$UI"

echo
echo GEMINI_CHAT_MANAGEMENT_READY
