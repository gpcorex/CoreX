#!/usr/bin/env bash
set -euo pipefail

APP=/home/ubuntu/Interfaz
SERVER="$APP/server.py"
NATIVE=/home/ubuntu/Central/native_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/interfaz-attachments-v2-$STAMP

mkdir -p "$BACKUP"
cp -a "$SERVER" "$BACKUP/server.py"

echo "=== 1. PATCH ATTACHMENT METADATA + RENAME API ==="
python3 - <<'PY'
from pathlib import Path
p=Path("/home/ubuntu/Interfaz/server.py")
s=p.read_text(encoding="utf-8")

# Conversation attachment metadata.
old='''                ars=c.execute("""SELECT a.id,a.original_name,a.mime,a.size
                    FROM attachments a JOIN message_attachments ma ON ma.attachment_id=a.id
                    WHERE ma.message_id=? ORDER BY a.created_at""",(md["id"],)).fetchall()
'''
new='''                ars=c.execute("""SELECT a.id,a.original_name,a.mime,a.size,a.created_at
                    FROM attachments a JOIN message_attachments ma ON ma.attachment_id=a.id
                    WHERE ma.message_id=? ORDER BY a.created_at""",(md["id"],)).fetchall()
'''
if old in s:
    s=s.replace(old,new,1)

# Rename endpoint before message endpoint.
anchor='''        if p=="/api/message":
            try:
'''
insert='''        m=re.fullmatch(r"/api/attachments/([A-Za-z0-9_-]+)/rename",p)
        if m:
            try:
                b=self.read_json()
                new_name=os.path.basename(str(b.get("name") or "").strip())
                if not new_name or len(new_name)>180:
                    return self.send_json(400,{"ok":False,"error":"INVALID_NAME"})
                c=db()
                row=c.execute("SELECT id,original_name FROM attachments WHERE id=?",(m.group(1),)).fetchone()
                if not row:
                    c.close()
                    return self.send_json(404,{"ok":False,"error":"ATTACHMENT_NOT_FOUND"})
                c.execute("UPDATE attachments SET original_name=? WHERE id=?",(new_name,m.group(1)))
                c.commit(); c.close()
                return self.send_json(200,{"ok":True,"id":m.group(1),"name":new_name})
            except Exception as e:
                return self.send_json(500,{"ok":False,"error":"ATTACHMENT_RENAME_FAILED","detail":str(e)})
        if p=="/api/message":
            try:
'''
if 'ATTACHMENT_RENAME_FAILED' not in s:
    if anchor not in s:
        raise SystemExit("RENAME_ENDPOINT_ANCHOR_NOT_FOUND")
    s=s.replace(anchor,insert,1)

# CSS.
css_anchor='''.attrow{display:flex;gap:8px;flex-wrap:wrap;margin-top:8px}.attlink{font-size:12px;color:var(--accent);text-decoration:none;border:1px solid var(--line);padding:5px 8px;border-radius:10px}'''
css_new='''.attrow{display:flex;gap:8px;flex-wrap:wrap;margin-top:8px}.attcard{border:1px solid var(--line);background:var(--panel);border-radius:12px;padding:7px;max-width:220px}.attthumb{display:block;max-width:200px;max-height:160px;border-radius:8px;margin-bottom:6px}.attmeta{font-size:11px;color:var(--muted);margin-top:3px}.attname{font-size:12px;color:var(--accent);text-decoration:none;display:inline-block;max-width:190px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.attrename{margin-left:6px;border:0;background:transparent;color:var(--muted);font-size:12px;padding:0}.pending{max-width:820px;margin:0 auto 8px;display:flex;gap:6px;flex-wrap:wrap}.chip{font-size:12px;border:1px solid var(--line);background:var(--panel2);padding:6px 9px;border-radius:999px}'''
if '.attcard{' not in s:
    if css_anchor not in s:
        raise SystemExit("ATTACHMENT_CSS_ANCHOR_NOT_FOUND")
    s=s.replace(css_anchor,css_new,1)

# JS helpers after esc().
anchorjs='''function esc(s){return String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
'''
helpers=r'''function esc(s){return String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
function fmtBytes(n){n=Number(n||0);if(n<1024)return n+' B';if(n<1048576)return (n/1024).toFixed(1)+' KB';return (n/1048576).toFixed(1)+' MB'}
function fmtDate(ts){if(!ts)return'';try{return new Date(Number(ts)*1000).toLocaleString()}catch(e){return''}}
async function renameAttachment(a,el){
 const current=a.original_name||a.name||'adjunto';
 const name=prompt('Nuevo nombre',current); if(!name||name===current)return;
 try{
   const x=await api('api/attachments/'+encodeURIComponent(a.id)+'/rename',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name})});
   a.original_name=x.name;a.name=x.name;if(el)el.textContent=x.name;loadConvs()
 }catch(e){addMsg('assistant','Error al renombrar adjunto: '+e.message)}
}
'''
if 'function fmtBytes(' not in s:
    if anchorjs not in s: raise SystemExit("ATTACHMENT_HELPERS_ANCHOR_NOT_FOUND")
    s=s.replace(anchorjs,helpers,1)

# Replace attachment rendering in addMsg with card/preview.
old_add='''function addMsg(role,text,attachments=[]){$('.empty')?.remove();const d=document.createElement('div');d.className='msg '+role;d.innerHTML=esc(text);if(attachments&&attachments.length){const row=document.createElement('div');row.className='attrow';for(const a of attachments){const l=document.createElement('a');l.className='attlink';l.href='api/attachments/'+encodeURIComponent(a.id);l.target='_blank';l.textContent='📎 '+(a.original_name||a.name||'adjunto');row.appendChild(l)}d.appendChild(row)}$('#thread').appendChild(d);scrollEnd()}'''
new_add=r'''function addMsg(role,text,attachments=[]){$('.empty')?.remove();const d=document.createElement('div');d.className='msg '+role;d.innerHTML=esc(text);if(attachments&&attachments.length){const row=document.createElement('div');row.className='attrow';for(const a of attachments){const card=document.createElement('div');card.className='attcard';const url='api/attachments/'+encodeURIComponent(a.id);if((a.mime||'').startsWith('image/')){const img=document.createElement('img');img.className='attthumb';img.src=url;img.alt=a.original_name||a.name||'imagen';card.appendChild(img)}const line=document.createElement('div');const l=document.createElement('a');l.className='attname';l.href=url;l.target='_blank';l.textContent=a.original_name||a.name||'adjunto';line.appendChild(l);const r=document.createElement('button');r.className='attrename';r.textContent='✎';r.title='Renombrar';r.onclick=()=>renameAttachment(a,l);line.appendChild(r);card.appendChild(line);const meta=document.createElement('div');meta.className='attmeta';meta.textContent=[fmtBytes(a.size),fmtDate(a.created_at)].filter(Boolean).join(' · ');card.appendChild(meta);row.appendChild(card)}d.appendChild(row)}$('#thread').appendChild(d);scrollEnd()}'''
if old_add in s:
    s=s.replace(old_add,new_add,1)
elif 'className=\'attcard\'' not in s and 'className="attcard"' not in s:
    raise SystemExit("ADDMSG_V2_ANCHOR_NOT_FOUND")

# Pending chips show size.
old_pending="d.textContent=a.name+' ×';"
new_pending="d.textContent=a.name+' · '+fmtBytes(a.size)+' ×';"
if old_pending in s:
    s=s.replace(old_pending,new_pending,1)

# Optimistic attachment metadata includes mime/size.
old_shown="const shownAttachments=pendingAttachments.map(a=>({id:a.id,original_name:a.name}))"
new_shown="const shownAttachments=pendingAttachments.map(a=>({id:a.id,original_name:a.name,mime:a.mime,size:a.size,created_at:Math.floor(Date.now()/1000)}))"
if old_shown in s:
    s=s.replace(old_shown,new_shown,1)

p.write_text(s,encoding="utf-8")
PY

python3 -m py_compile "$SERVER"
echo INTERFAZ_ATTACHMENTS_V2_PATCH_OK

echo "=== 2. RESTART INTERFAZ ==="
sudo systemctl restart interfaz.service
for i in $(seq 1 30); do
  if curl -fsS --max-time 2 http://127.0.0.1:8791/api/health >/tmp/interfaz-att-v2-health.json 2>/dev/null; then break; fi
  sleep 1
done
cat /tmp/interfaz-att-v2-health.json
echo
systemctl is-active interfaz.service
echo INTERFAZ_ATTACHMENTS_V2_SERVICE_OK

echo "=== 3. UPLOAD + RENAME API TEST ==="
F=/tmp/attachment-v2.txt
printf 'ATTACHMENT_V2_OK\n' > "$F"
REQ=/tmp/attachment-v2-upload.json
python3 - "$F" "$REQ" <<'PY'
import base64,json,sys
src,dst=sys.argv[1:]
with open(src,"rb") as f:b64=base64.b64encode(f.read()).decode()
with open(dst,"w",encoding="utf-8") as f:
    json.dump({"name":"original.txt","mime":"text/plain","data_base64":b64},f,separators=(",",":"))
PY
UP=$(curl -fsS --max-time 30 -H 'Content-Type: application/json' --data-binary @"$REQ" http://127.0.0.1:8791/api/attachments)
echo "$UP"
AID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["attachment"]["id"])' <<<"$UP")
REN=$(curl -fsS --max-time 15 -H 'Content-Type: application/json' -d '{"name":"renombrado.txt"}' "http://127.0.0.1:8791/api/attachments/$AID/rename")
echo "$REN"
REN_JSON="$REN" python3 - <<'PY'
import json,os
x=json.loads(os.environ["REN_JSON"])
assert x["ok"] is True,x
assert x["name"]=="renombrado.txt",x
print("INTERFAZ_ATTACHMENT_RENAME_OK")
PY

echo "=== 4. PUBLIC UI MARKERS ==="
PUB=$(curl -fsS --max-time 15 https://cen-tral.duckdns.org/interfaz/)
grep -q 'attthumb' <<<"$PUB"
grep -q 'Renombrar' <<<"$PUB"
grep -q 'fmtBytes' <<<"$PUB"
echo INTERFAZ_ATTACHMENT_PREVIEW_PUBLIC_OK

cat >"$NATIVE/BUILD_REPORT.json" <<EOF
{
  "ok": true,
  "build": "interfaz-attachments-v2",
  "image_previews": true,
  "metadata": ["name","size","date"],
  "rename": true,
  "persistent_attachments": true,
  "operational_file_staging": false,
  "active": true
}
EOF

echo CENTRAL_INTERFAZ_ATTACHMENTS_V2_READY
echo "URL=https://cen-tral.duckdns.org/interfaz/"
echo "NOTE=Next layer: stage operational attachments directly into each Central job workspace."
echo "backup=$BACKUP"
