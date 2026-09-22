#!/usr/bin/env bash
set -euo pipefail

DEST=/home/ubuntu/Central/native_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/native-direct-$STAMP

mkdir -p "$BACKUP"
if [ -d "$DEST" ]; then
  cp -a "$DEST" "$BACKUP/native_v1"
fi
mkdir -p "$DEST/tests"

echo "=== 1. CONFIG ==="
cat >"$DEST/config.py" <<'PY'
from __future__ import annotations
import json
from dataclasses import dataclass
from pathlib import Path

GROQ_KEY_PATH=Path("/home/ubuntu/Claves/prov/groq.key")
OPENROUTER_KEY_PATH=Path("/home/ubuntu/Claves/providers/openrouter.key")
ROSTER_PATH=Path("/home/ubuntu/Central/config/model-roster.json")

def _read_secret(path: Path) -> str:
    value=path.read_text(encoding="utf-8-sig").strip().strip('"').strip("'")
    if not value:
        raise RuntimeError(f"EMPTY_SECRET:{path}")
    return value

@dataclass(frozen=True)
class Settings:
    groq_key: str
    openrouter_key: str
    roster: dict

def load_settings() -> Settings:
    roster=json.loads(ROSTER_PATH.read_text(encoding="utf-8"))
    return Settings(
        groq_key=_read_secret(GROQ_KEY_PATH),
        openrouter_key=_read_secret(OPENROUTER_KEY_PATH),
        roster=roster,
    )
PY
python3 -m py_compile "$DEST/config.py"
echo CONFIG_OK

echo "=== 2. PROVIDERS ==="
cat >"$DEST/providers.py" <<'PY'
from __future__ import annotations
import json, urllib.request, urllib.error

class ProviderError(RuntimeError): pass

class OpenAICompatProvider:
    def __init__(self, name:str, base_url:str, api_key:str, timeout:int=60):
        self.name=name
        self.base_url=base_url.rstrip("/")
        self.api_key=api_key
        self.timeout=timeout

    def _request(self, path:str, payload:dict|None=None, method:str="GET"):
        data=None if payload is None else json.dumps(payload,ensure_ascii=False).encode()
        req=urllib.request.Request(
            self.base_url+path,
            data=data,
            method=method,
            headers={
                "Authorization":"Bearer "+self.api_key,
                "Content-Type":"application/json",
            },
        )
        try:
            with urllib.request.urlopen(req,timeout=self.timeout) as r:
                return json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            body=e.read().decode("utf-8","replace")[-1500:]
            raise ProviderError(f"{self.name}:HTTP_{e.code}:{body}")
        except Exception as e:
            raise ProviderError(f"{self.name}:{type(e).__name__}:{e}")

    def list_models(self):
        out=self._request("/models")
        return [x for x in out.get("data",[]) if isinstance(x,dict)]

    def chat(self, model:str, messages:list[dict], tools:list[dict]|None=None,
             max_tokens:int=1024, temperature:float=0.2):
        payload={
            "model":model,
            "messages":messages,
            "max_tokens":max_tokens,
            "temperature":temperature,
        }
        if tools:
            payload["tools"]=tools
            payload["tool_choice"]="auto"
        return self._request("/chat/completions",payload,"POST")

def groq_provider(key:str, timeout:int=60):
    return OpenAICompatProvider("groq","https://api.groq.com/openai/v1",key,timeout)

def openrouter_provider(key:str, timeout:int=60):
    return OpenAICompatProvider("openrouter","https://openrouter.ai/api/v1",key,timeout)
PY
python3 -m py_compile "$DEST/providers.py"
echo PROVIDERS_OK

echo "=== 3. ROUTER ==="
cat >"$DEST/router.py" <<'PY'
from __future__ import annotations

ROLE_ORDER={
    "rapido":["rapido","tecnico","fuerte","fallback"],
    "tecnico":["tecnico","fuerte","rapido","fallback"],
    "fuerte":["fuerte","tecnico","rapido","fallback"],
    "fallback":["fallback","rapido","tecnico","fuerte"],
}

def build_chain(roster:dict, role:str="rapido")->list[str]:
    groups=[]
    for k in ("groq","openrouter"):
        for item in roster.get(k,[]) or []:
            if isinstance(item,dict) and item.get("id"):
                groups.append(item)
    order=ROLE_ORDER.get(role,ROLE_ORDER["rapido"])
    rank={r:i for i,r in enumerate(order)}
    groups.sort(key=lambda x:(rank.get(x.get("role"),99), 0 if x.get("provider")=="groq" else 1))
    out=[]
    for x in groups:
        mid=x["id"]
        if mid not in out: out.append(mid)
    # Preserve explicit policy as final safety chain.
    policy=roster.get("policy",{})
    for mid in [policy.get("primary"),*(policy.get("fallback_order") or [])]:
        if mid and mid not in out: out.append(mid)
    return out

def provider_for(model_ref:str)->str:
    return model_ref.split("/",1)[0]
PY
python3 -m py_compile "$DEST/router.py"
echo ROUTER_OK

echo "=== 4. RADAR ==="
cat >"$DEST/radar.py" <<'PY'
from __future__ import annotations
from providers import groq_provider, openrouter_provider

def scan(groq_key:str, openrouter_key:str, timeout:int=20)->dict:
    out={}
    for name,p in (
        ("groq",groq_provider(groq_key,timeout)),
        ("openrouter",openrouter_provider(openrouter_key,timeout)),
    ):
        try:
            rows=p.list_models()
            out[name]={
                "ok":True,
                "count":len(rows),
                "models":[{"id":x.get("id"),"owned_by":x.get("owned_by")} for x in rows if x.get("id")]
            }
        except Exception as e:
            out[name]={"ok":False,"error":str(e),"count":0,"models":[]}
    return out
PY
python3 -m py_compile "$DEST/radar.py"
echo RADAR_OK

echo "=== 5. TOOLS ==="
cat >"$DEST/tools.py" <<'PY'
from __future__ import annotations
import os, subprocess
from pathlib import Path

class ToolError(RuntimeError): pass

class ToolBox:
    def __init__(self, root:str|Path, exec_timeout:int=60):
        self.root=Path(root).resolve()
        self.exec_timeout=exec_timeout
        self.root.mkdir(parents=True,exist_ok=True)

    def _safe(self,p:str|Path)->Path:
        raw=Path(p)
        target=(self.root/raw).resolve() if not raw.is_absolute() else raw.resolve()
        try:
            target.relative_to(self.root)
        except ValueError:
            raise ToolError("PATH_OUTSIDE_ROOT")
        return target

    def read(self,path:str)->str:
        return self._safe(path).read_text(encoding="utf-8")

    def write(self,path:str,text:str)->dict:
        p=self._safe(path); p.parent.mkdir(parents=True,exist_ok=True)
        p.write_text(text,encoding="utf-8")
        return {"ok":True,"path":str(p),"bytes":len(text.encode())}

    def edit(self,path:str,old:str,new:str,count:int=1)->dict:
        p=self._safe(path); s=p.read_text(encoding="utf-8")
        if old not in s: raise ToolError("EDIT_ANCHOR_NOT_FOUND")
        p.write_text(s.replace(old,new,count),encoding="utf-8")
        return {"ok":True,"path":str(p)}

    def exec(self,argv:list[str],cwd:str=".",timeout:int|None=None)->dict:
        if not isinstance(argv,list) or not argv or not all(isinstance(x,str) for x in argv):
            raise ToolError("INVALID_ARGV")
        wd=self._safe(cwd)
        if not wd.is_dir(): raise ToolError("CWD_NOT_DIRECTORY")
        cp=subprocess.run(argv,cwd=wd,capture_output=True,text=True,
                          timeout=timeout or self.exec_timeout)
        return {"returncode":cp.returncode,"stdout":cp.stdout,"stderr":cp.stderr}

    def process(self,argv:list[str],cwd:str=".",timeout:int|None=None)->dict:
        return self.exec(argv,cwd,timeout)
PY
python3 -m py_compile "$DEST/tools.py"
echo TOOLS_OK

echo "=== 6. AGENT ==="
cat >"$DEST/agent.py" <<'PY'
from __future__ import annotations
import json

class AgentError(RuntimeError): pass

def openai_tool_schemas():
    return [
      {"type":"function","function":{"name":"read","description":"Leer archivo dentro del workspace","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},
      {"type":"function","function":{"name":"write","description":"Escribir archivo dentro del workspace","parameters":{"type":"object","properties":{"path":{"type":"string"},"text":{"type":"string"}},"required":["path","text"]}}},
      {"type":"function","function":{"name":"edit","description":"Reemplazar texto dentro de un archivo","parameters":{"type":"object","properties":{"path":{"type":"string"},"old":{"type":"string"},"new":{"type":"string"}},"required":["path","old","new"]}}},
      {"type":"function","function":{"name":"exec","description":"Ejecutar comando en el workspace","parameters":{"type":"object","properties":{"argv":{"type":"array","items":{"type":"string"}},"cwd":{"type":"string"}},"required":["argv"]}}},
    ]

class Agent:
    def __init__(self, provider, model:str, toolbox, max_steps:int=12):
        self.provider=provider; self.model=model; self.toolbox=toolbox; self.max_steps=max_steps

    def _run_tool(self,name,args):
        if name=="read": return self.toolbox.read(**args)
        if name=="write": return self.toolbox.write(**args)
        if name=="edit": return self.toolbox.edit(**args)
        if name=="exec": return self.toolbox.exec(**args)
        raise AgentError("UNKNOWN_TOOL:"+name)

    def run(self,task:str):
        messages=[
          {"role":"system","content":"Sos el agente programador de Central. Usá herramientas para completar y verificar la tarea. No salgas del workspace. Cuando termines, explicá el resultado de forma breve."},
          {"role":"user","content":task},
        ]
        tools=openai_tool_schemas()
        for step in range(1,self.max_steps+1):
            raw=self.provider.chat(self.model,messages,tools=tools,max_tokens=1400)
            msg=(raw.get("choices") or [{}])[0].get("message") or {}
            calls=msg.get("tool_calls") or []
            if not calls:
                return {"ok":True,"steps":step,"answer":str(msg.get("content") or "").strip()}
            assistant={"role":"assistant","content":msg.get("content"),"tool_calls":calls}
            messages.append(assistant)
            for call in calls:
                fn=(call.get("function") or {})
                name=fn.get("name")
                try: args=json.loads(fn.get("arguments") or "{}")
                except Exception: raise AgentError("INVALID_TOOL_ARGUMENTS")
                try: result=self._run_tool(name,args)
                except Exception as e: result={"ok":False,"error":str(e)}
                messages.append({
                  "role":"tool",
                  "tool_call_id":call.get("id"),
                  "name":name,
                  "content":json.dumps(result,ensure_ascii=False) if not isinstance(result,str) else result,
                })
        raise AgentError("MAX_STEPS_EXCEEDED")
PY
python3 -m py_compile "$DEST/agent.py"
echo AGENT_OK

echo "=== 7. CLI ==="
cat >"$DEST/cli.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, tempfile
from config import load_settings
from providers import groq_provider, openrouter_provider
from router import build_chain, provider_for
from tools import ToolBox
from agent import Agent

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("task")
    ap.add_argument("--role",default="tecnico")
    ap.add_argument("--workspace",default=None)
    ap.add_argument("--max-steps",type=int,default=12)
    a=ap.parse_args()

    cfg=load_settings()
    chain=build_chain(cfg.roster,a.role)
    root=a.workspace or tempfile.mkdtemp(prefix="central-native-")
    last=None
    for ref in chain:
        if ref=="openrouter/free":
            model="openrouter/free"; provider=openrouter_provider(cfg.openrouter_key)
        else:
            kind=provider_for(ref); model=ref.split("/",1)[1]
            provider=groq_provider(cfg.groq_key) if kind=="groq" else openrouter_provider(cfg.openrouter_key)
        try:
            out=Agent(provider,model,ToolBox(root),a.max_steps).run(a.task)
            out.update({"provider":kind if ref!="openrouter/free" else "openrouter","model":model,"workspace":root})
            print(json.dumps(out,ensure_ascii=False))
            return
        except Exception as e:
            last=str(e)
    raise SystemExit("ALL_MODELS_FAILED:"+str(last))

if __name__=="__main__":
    main()
PY
chmod 755 "$DEST/cli.py"
python3 -m py_compile "$DEST/cli.py"
echo CLI_OK

echo "=== 8. UNIT TESTS ==="
cat >"$DEST/tests/test_native.py" <<'PY'
import json, tempfile, unittest
from pathlib import Path
from tools import ToolBox, ToolError
from router import build_chain
from agent import Agent, AgentError

class FakeProvider:
    def __init__(self): self.n=0
    def chat(self,model,messages,tools=None,max_tokens=0,temperature=0.2):
        self.n+=1
        if self.n==1:
            return {"choices":[{"message":{"content":None,"tool_calls":[{"id":"1","type":"function","function":{"name":"write","arguments":json.dumps({"path":"x.txt","text":"OK"})}}]}}]}
        return {"choices":[{"message":{"content":"hecho"}}]}

class LoopProvider:
    def chat(self,model,messages,tools=None,max_tokens=0,temperature=0.2):
        return {"choices":[{"message":{"content":None,"tool_calls":[{"id":"x","type":"function","function":{"name":"read","arguments":json.dumps({"path":"missing"})}}]}}]}

class NativeTests(unittest.TestCase):
    def test_tools_root(self):
        with tempfile.TemporaryDirectory() as d:
            t=ToolBox(d)
            t.write("a.txt","hola")
            self.assertEqual(t.read("a.txt"),"hola")
            with self.assertRaises(ToolError): t.read("/etc/passwd")

    def test_router(self):
        r={"groq":[{"id":"groq/a","role":"rapido","provider":"groq"},{"id":"groq/b","role":"fuerte","provider":"groq"}],"openrouter":[]}
        self.assertEqual(build_chain(r,"fuerte")[0],"groq/b")

    def test_agent_tool_loop(self):
        with tempfile.TemporaryDirectory() as d:
            a=Agent(FakeProvider(),"fake",ToolBox(d),max_steps=3)
            out=a.run("crear")
            self.assertTrue(out["ok"])
            self.assertEqual(Path(d,"x.txt").read_text(),"OK")

    def test_agent_max_steps(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(AgentError):
                Agent(LoopProvider(),"fake",ToolBox(d),max_steps=2).run("loop")

if __name__=="__main__": unittest.main()
PY

PYTHONPATH="$DEST" python3 -m unittest discover -s "$DEST/tests" -p 'test_*.py' -v
echo UNIT_TESTS_OK

echo "=== 9. RADAR REAL SMOKE ==="
PYTHONPATH="$DEST" python3 - <<'PY'
from config import load_settings
from radar import scan
s=load_settings()
out=scan(s.groq_key,s.openrouter_key,20)
assert out["groq"]["ok"], out["groq"]
assert out["groq"]["count"] > 0
assert out["openrouter"]["ok"], out["openrouter"]
assert out["openrouter"]["count"] > 0
print("RADAR_REAL_OK", "groq="+str(out["groq"]["count"]), "openrouter="+str(out["openrouter"]["count"]))
PY

echo "=== 10. PROVIDER REAL SMOKE ==="
PYTHONPATH="$DEST" python3 - <<'PY'
from config import load_settings
from providers import groq_provider
s=load_settings()
p=groq_provider(s.groq_key,30)
r=p.chat("openai/gpt-oss-20b",[{"role":"user","content":"Respondé exactamente NATIVE_PROVIDER_OK"}],max_tokens=80)
ans=((r.get("choices") or [{}])[0].get("message") or {}).get("content","").strip()
assert ans=="NATIVE_PROVIDER_OK", repr(ans)
print("PROVIDER_REAL_OK")
PY

echo "=== 11. NATIVE AGENT REAL SMOKE ==="
WORK=/tmp/central-native-smoke
rm -rf "$WORK"
mkdir -p "$WORK"
PYTHONPATH="$DEST" python3 "$DEST/cli.py" \
  "Creá un archivo prueba.txt con el texto NATIVE_AGENT_OK y después leelo para verificarlo." \
  --role rapido --workspace "$WORK" --max-steps 8 | tee /tmp/central-native-agent-smoke.json

grep -q 'NATIVE_AGENT_OK' "$WORK/prueba.txt"
echo AGENT_REAL_OK

cat >"$DEST/BUILD_REPORT.json" <<EOF
{
  "ok": true,
  "build": "direct",
  "tests": "passed",
  "radar_real": "passed",
  "provider_real": "passed",
  "agent_real": "passed",
  "active": false
}
EOF

chown -R ubuntu:ubuntu "$DEST"
echo CENTRAL_NATIVE_V1_DIRECT_READY
echo "installed=$DEST"
echo "backup=$BACKUP"
echo "NOTE=inactive; no production route changed"
