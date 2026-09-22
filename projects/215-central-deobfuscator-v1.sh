#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/ubuntu/Central/deobfuscator_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/deobfuscator-v1-$STAMP
mkdir -p "$ROOT" "$BACKUP"

echo "=== 1. INSTALL CENTRAL DEOBFUSCATOR V1 ==="
cat >"$ROOT/deobfuscate_android.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import argparse, base64, binascii, codecs, hashlib, json, math, re, string, sys, urllib.parse
from pathlib import Path

PROJECTS=Path("/home/ubuntu/Central/projects")

PRINTABLE=set(string.printable)
INTERESTING_WORDS={
    "http","https","api","player","play","stream","video","movie","series","episode",
    "season","catalog","search","login","auth","token","subtitle","manifest","m3u8",
    "mpd","dash","hls","drm","widevine","exo","media","poster","image","profile",
    "favorite","download","graphql","socket","webview"
}

B64_RE=re.compile(r'(?<![A-Za-z0-9+/=_-])([A-Za-z0-9+/]{16,}={0,2})(?![A-Za-z0-9+/=_-])')
HEX_RE=re.compile(r'(?<![0-9A-Fa-f])([0-9A-Fa-f]{16,})(?![0-9A-Fa-f])')
URLENC_RE=re.compile(r'(%[0-9A-Fa-f]{2}){3,}')
UNICODE_RE=re.compile(r'(?:\\u[0-9A-Fa-f]{4}){2,}')
SMALI_STRING_RE=re.compile(r'const-string(?:/jumbo)?\s+[^,]+,\s+"(.*)"')
SMALI_METHOD_RE=re.compile(r'^\.method\s+(.+)$')
SMALI_END_RE=re.compile(r'^\.end method')
DECODER_HINTS=(
    "xor-int","xor-long","aget-byte","aget-char","StringBuilder;->append",
    "java/util/Base64","android/util/Base64","javax/crypto/Cipher",
    "SecretKeySpec","IvParameterSpec","MessageDigest","Character;->toChars"
)

def text_quality(s:str)->float:
    if not s:return 0.0
    good=sum(1 for c in s if c in PRINTABLE or c.isprintable())
    ratio=good/max(1,len(s))
    words=sum(1 for w in INTERESTING_WORDS if w in s.lower())
    return ratio + min(words,5)*0.25

def interesting(s:str)->bool:
    low=s.lower()
    return any(w in low for w in INTERESTING_WORDS) or low.startswith(("http://","https://"))

def unique_add(out, seen, original, decoded, method, source, depth):
    decoded=decoded.strip("\x00")
    if not decoded or decoded==original or len(decoded)<2 or len(decoded)>20000:
        return
    key=(original,decoded,method,source)
    if key in seen:return
    if text_quality(decoded)<0.85:return
    seen.add(key)
    out.append({
        "original":original,
        "decoded":decoded,
        "method":method,
        "source":source,
        "depth":depth,
        "interesting":interesting(decoded),
        "confidence":"high" if interesting(decoded) else "medium"
    })

def decode_candidates(s:str):
    vals=[]
    t=s.strip()
    # URL percent encoding.
    if "%" in t:
        try:
            u=urllib.parse.unquote(t)
            if u!=t:vals.append(("url_decode",u))
        except Exception:pass
    # Unicode escapes.
    if "\\u" in t:
        try:
            u=codecs.decode(t,"unicode_escape")
            if u!=t:vals.append(("unicode_escape",u))
        except Exception:pass
    # Hex.
    if len(t)>=16 and len(t)%2==0 and re.fullmatch(r"[0-9A-Fa-f]+",t):
        try:
            raw=bytes.fromhex(t)
            vals.append(("hex_utf8",raw.decode("utf-8","strict")))
        except Exception:pass
    # Base64 / URL-safe Base64.
    if len(t)>=16 and re.fullmatch(r"[A-Za-z0-9_+/=-]+",t):
        for name,fn in (
            ("base64",base64.b64decode),
            ("base64url",base64.urlsafe_b64decode),
        ):
            try:
                pad="="*((4-len(t)%4)%4)
                raw=fn((t+pad).encode())
                vals.append((name,raw.decode("utf-8","strict")))
            except Exception:pass
    # Reverse is common in hand-written obfuscators; only keep plausible text.
    if len(t)>=6:
        vals.append(("reverse",t[::-1]))
    # Single-byte XOR brute force: only surface results that become meaningful text.
    try:
        raw=t.encode("latin1")
        if 4<=len(raw)<=512:
            for k in range(1,256):
                dec=bytes(b^k for b in raw)
                try:u=dec.decode("utf-8")
                except Exception:continue
                if interesting(u) and text_quality(u)>=1.1:
                    vals.append((f"xor_byte_{k}",u))
    except Exception:pass
    return vals

def extract_strings(path:Path):
    try:s=path.read_text(encoding="utf-8",errors="ignore")
    except Exception:return []
    out=[]
    if path.suffix==".smali":
        for line in s.splitlines():
            m=SMALI_STRING_RE.search(line)
            if m:
                out.append(bytes(m.group(1),"utf-8").decode("unicode_escape",errors="ignore"))
    else:
        for m in B64_RE.finditer(s):out.append(m.group(1))
        for m in HEX_RE.finditer(s):out.append(m.group(1))
        for m in URLENC_RE.finditer(s):out.append(m.group(0))
        for m in UNICODE_RE.finditer(s):out.append(m.group(0))
        for q in re.finditer(r'["\']([^"\']{6,500})["\']',s):
            out.append(q.group(1))
    return list(dict.fromkeys(out))

def scan_decoder_routines(files):
    routines=[]
    for p in files:
        if p.suffix!=".smali":continue
        try:lines=p.read_text(encoding="utf-8",errors="ignore").splitlines()
        except Exception:continue
        cur=None;buf=[]
        for line in lines:
            if cur is None:
                m=SMALI_METHOD_RE.match(line.strip())
                if m:
                    cur=m.group(1);buf=[line]
            else:
                buf.append(line)
                if SMALI_END_RE.match(line.strip()):
                    body="\n".join(buf)
                    hints=sorted({h for h in DECODER_HINTS if h in body})
                    if hints:
                        score=len(hints)
                        routines.append({
                            "file":str(p),
                            "method":cur,
                            "hints":hints,
                            "score":score,
                            "sha1":hashlib.sha1(body.encode()).hexdigest()
                        })
                    cur=None;buf=[]
    routines.sort(key=lambda x:(-x["score"],x["file"],x["method"]))
    return routines[:500]

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("project_id")
    ap.add_argument("--max-files",type=int,default=6000)
    ap.add_argument("--max-depth",type=int,default=3)
    a=ap.parse_args()

    root=(PROJECTS/a.project_id).resolve()
    if root.parent!=PROJECTS.resolve() or not root.is_dir():
        raise SystemExit("PROJECT_NOT_FOUND:"+a.project_id)
    analysis_path=root/"canon"/"analysis.json"
    if not analysis_path.is_file():
        raise SystemExit("ANALYSIS_NOT_FOUND")
    analysis=json.load(open(analysis_path,encoding="utf-8"))

    decoded=root/"work"/"android-audit"/"decoded"
    if not decoded.is_dir():
        raise SystemExit("APKTOOL_DECODED_TREE_NOT_FOUND")

    files=[]
    for p in decoded.rglob("*"):
        if p.is_file() and p.stat().st_size<=5*1024*1024:
            files.append(p)
            if len(files)>=a.max_files:break

    routines=scan_decoder_routines(files)

    recovered=[];seen=set();inputs=0
    queue=[]
    for p in files:
        rel=str(p.relative_to(decoded))
        for s in extract_strings(p):
            inputs+=1
            queue.append((s,s,rel,0))

    qi=0
    while qi<len(queue):
        original,current,source,depth=queue[qi];qi+=1
        if depth>=a.max_depth:continue
        for method,decoded_s in decode_candidates(current):
            before=len(recovered)
            unique_add(recovered,seen,original,decoded_s,method,source,depth+1)
            if len(recovered)>before and depth+1<a.max_depth:
                queue.append((original,decoded_s,source,depth+1))

    recovered.sort(key=lambda x:(not x["interesting"],x["source"],x["method"]))
    work=root/"work"/"deobfuscation"
    work.mkdir(parents=True,exist_ok=True)
    (work/"decoded-strings.json").write_text(json.dumps(recovered,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    (work/"decoder-routines.json").write_text(json.dumps(routines,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

    interesting_rows=[x for x in recovered if x["interesting"]]
    (work/"interesting-strings.json").write_text(json.dumps(interesting_rows,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

    # Add evidence for recovered high-value strings without pretending they are yet functional components.
    existing={e.get("id") for e in analysis.get("evidence",[])}
    for row in interesting_rows[:1000]:
        loc=f"{row['source']}::{row['method']}"
        eid="ev."+hashlib.sha1(("decoded|"+loc+"|"+row["decoded"]).encode()).hexdigest()[:12]
        if eid in existing:continue
        analysis["evidence"].append({
            "id":eid,
            "kind":"other",
            "locator":loc,
            "excerpt":row["decoded"][:1000],
            "hash_sha256":None,
            "tool":"central-deobfuscator-v1",
            "observed_at":None
        })
        existing.add(eid)

    notes=[n for n in analysis.get("notes",[]) if not str(n).startswith("DEOBFUSCATION_V1_")]
    notes += [
        "DEOBFUSCATION_V1_COMPLETE",
        f"DEOBFUSCATION_V1_INPUT_STRINGS={inputs}",
        f"DEOBFUSCATION_V1_RECOVERED={len(recovered)}",
        f"DEOBFUSCATION_V1_INTERESTING={len(interesting_rows)}",
        f"DEOBFUSCATION_V1_DECODER_ROUTINES={len(routines)}"
    ]
    analysis["notes"]=notes
    analysis_path.write_text(json.dumps(analysis,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

    report={
        "ok":True,
        "project_id":a.project_id,
        "files_scanned":len(files),
        "input_strings":inputs,
        "recovered_strings":len(recovered),
        "interesting_strings":len(interesting_rows),
        "decoder_routines":len(routines),
        "decoded_strings":str(work/"decoded-strings.json"),
        "interesting_output":str(work/"interesting-strings.json"),
        "decoder_routines_output":str(work/"decoder-routines.json")
    }
    (work/"report.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    print(json.dumps(report,ensure_ascii=False))

if __name__=="__main__":
    main()
PY
chmod 755 "$ROOT/deobfuscate_android.py"
python3 -m py_compile "$ROOT/deobfuscate_android.py"
echo DEOBFUSCATOR_V1_SOURCE_OK

echo "=== 2. INSTALL CONTRACT ==="
cat >"$ROOT/README.md" <<'EOF'
# Central Deobfuscator V1

Objetivo: eliminar el trabajo manual repetitivo de recuperar cadenas y localizar rutinas
de decodificación antes del análisis funcional.

V1 hace automáticamente:
- extracción masiva de strings desde smali/recursos;
- Base64 y Base64 URL-safe;
- hexadecimal;
- URL percent encoding;
- escapes Unicode;
- reverse;
- XOR de un byte cuando produce resultados funcionalmente interesantes;
- decodificación recursiva hasta 3 capas;
- detección de métodos smali con patrones típicos de decodificación/cifrado;
- inventario de resultados interesantes;
- evidencia incorporada al analysis.json.

Salidas:
- work/deobfuscation/decoded-strings.json
- work/deobfuscation/interesting-strings.json
- work/deobfuscation/decoder-routines.json
- work/deobfuscation/report.json

Los cifrados que dependan de una rutina específica de la app quedan identificados como
decoder routines. Una fase posterior los aislará/ejecutará en lote o los interceptará
en runtime, evitando el procedimiento manual carácter por carácter.
EOF

echo "=== 3. SELF TEST WITH ENCODED STRINGS ==="
TMPROOT=/home/ubuntu/Central/projects/deobfuscator-v1-selftest
rm -rf "$TMPROOT"
mkdir -p "$TMPROOT/canon" "$TMPROOT/work/android-audit/decoded/smali/demo"
cat >"$TMPROOT/canon/analysis.json" <<'JSON'
{
  "schema_version":"central.analysis.v1",
  "analysis_id":"AN-DEOBF-SELFTEST",
  "created_at":"2026-09-22T00:00:00Z",
  "source":{"kind":"apk","origin":"selftest.apk","artifact_name":"selftest.apk","package_name":"demo","version":"1","hash_sha256":null,"captured_at":null},
  "identity":{"name":"Deobfuscator selftest","platform":"android","description":null,"entrypoints":[]},
  "interfaces":[],
  "behaviors":[],
  "data":{"models":[],"local_storage":[],"apis":[],"formats":[]},
  "media":{"players":[],"streams":[],"codecs":[],"drm":[],"subtitles":[]},
  "security":{"authentication":[],"permissions":[],"certificates":[],"restrictions":[]},
  "components":[],
  "dependencies":[],
  "evidence":[],
  "notes":[]
}
JSON

cat >"$TMPROOT/work/android-audit/decoded/smali/demo/Test.smali" <<'SMALI'
.class public Ldemo/Test;
.super Ljava/lang/Object;

.method public static decode([B)Ljava/lang/String;
    .locals 2
    aget-byte v0, p0, v1
    xor-int/lit8 v0, v0, 0x2a
    new-instance v0, Ljava/lang/StringBuilder;
    invoke-virtual {v0, v1}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;
    const-string v1, "aHR0cHM6Ly9hcGkuZXhhbXBsZS50ZXN0L2NhdGFsb2c="
    const-string v1, "72656c706d617865"
    return-object v0
.end method
SMALI

OUT=$(sudo -u ubuntu python3 "$ROOT/deobfuscate_android.py" deobfuscator-v1-selftest)
echo "$OUT"

python3 - <<'PY'
import json
from pathlib import Path
w=Path("/home/ubuntu/Central/projects/deobfuscator-v1-selftest/work/deobfuscation")
dec=json.load(open(w/"decoded-strings.json",encoding="utf-8"))
routines=json.load(open(w/"decoder-routines.json",encoding="utf-8"))
assert any(x["decoded"]=="https://api.example.test/catalog" for x in dec),dec
assert any(x["method"]=="base64" for x in dec),dec
assert len(routines)>=1,routines
assert any("xor-int" in h for r in routines for h in r["hints"]),routines
print("DEOBFUSCATOR_V1_BATCH_DECODE_OK")
print("DEOBFUSCATOR_V1_ROUTINE_DETECTION_OK")
PY

python3 /home/ubuntu/Central/canon/v1/validate_canon.py "$TMPROOT/canon/analysis.json"
echo DEOBFUSCATOR_V1_CANON_OK
echo CENTRAL_DEOBFUSCATOR_V1_READY
echo "root=$ROOT"
echo "backup=$BACKUP"
