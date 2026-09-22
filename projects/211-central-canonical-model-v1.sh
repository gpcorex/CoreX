#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/ubuntu/Central/canon/v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/canon-schema-v1-$STAMP
mkdir -p "$ROOT" "$BACKUP"

[ -d "$ROOT" ] && cp -a "$ROOT" "$BACKUP/v1-before" 2>/dev/null || true

echo "=== 1. INSTALL CANONICAL ANALYSIS SCHEMA V1 ==="
cat >"$ROOT/analysis.schema.json" <<'JSON'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://central.local/schema/v1/analysis.schema.json",
  "title": "Central Canonical Analysis V1",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "schema_version",
    "analysis_id",
    "created_at",
    "source",
    "identity",
    "components",
    "dependencies",
    "evidence"
  ],
  "properties": {
    "schema_version": { "const": "central.analysis.v1" },
    "analysis_id": { "type": "string", "minLength": 1 },
    "created_at": { "type": "string", "minLength": 1 },
    "source": {
      "type": "object",
      "additionalProperties": false,
      "required": ["kind", "origin"],
      "properties": {
        "kind": {
          "type": "string",
          "enum": ["apk", "xapk", "installed_android_app", "web_url", "pwa", "source_project", "desktop_package", "other"]
        },
        "origin": { "type": "string", "minLength": 1 },
        "artifact_name": { "type": ["string", "null"] },
        "package_name": { "type": ["string", "null"] },
        "version": { "type": ["string", "null"] },
        "hash_sha256": { "type": ["string", "null"] },
        "captured_at": { "type": ["string", "null"] }
      }
    },
    "identity": {
      "type": "object",
      "additionalProperties": false,
      "required": ["name", "platform"],
      "properties": {
        "name": { "type": "string", "minLength": 1 },
        "platform": { "type": "string", "minLength": 1 },
        "description": { "type": ["string", "null"] },
        "entrypoints": { "type": "array", "items": { "type": "string" } }
      }
    },
    "interfaces": {
      "type": "array",
      "items": { "$ref": "#/$defs/interface" }
    },
    "behaviors": {
      "type": "array",
      "items": { "$ref": "#/$defs/behavior" }
    },
    "data": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "models": { "type": "array", "items": { "$ref": "#/$defs/namedItem" } },
        "local_storage": { "type": "array", "items": { "$ref": "#/$defs/namedItem" } },
        "apis": { "type": "array", "items": { "$ref": "#/$defs/api" } },
        "formats": { "type": "array", "items": { "type": "string" } }
      }
    },
    "media": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "players": { "type": "array", "items": { "$ref": "#/$defs/namedItem" } },
        "streams": { "type": "array", "items": { "$ref": "#/$defs/namedItem" } },
        "codecs": { "type": "array", "items": { "type": "string" } },
        "drm": { "type": "array", "items": { "$ref": "#/$defs/namedItem" } },
        "subtitles": { "type": "array", "items": { "$ref": "#/$defs/namedItem" } }
      }
    },
    "security": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "authentication": { "type": "array", "items": { "$ref": "#/$defs/namedItem" } },
        "permissions": { "type": "array", "items": { "type": "string" } },
        "certificates": { "type": "array", "items": { "$ref": "#/$defs/namedItem" } },
        "restrictions": { "type": "array", "items": { "$ref": "#/$defs/namedItem" } }
      }
    },
    "components": {
      "type": "array",
      "items": { "$ref": "#/$defs/component" }
    },
    "dependencies": {
      "type": "array",
      "items": { "$ref": "#/$defs/dependency" }
    },
    "evidence": {
      "type": "array",
      "items": { "$ref": "#/$defs/evidence" }
    },
    "notes": { "type": "array", "items": { "type": "string" } }
  },
  "$defs": {
    "confidence": {
      "type": "string",
      "enum": ["low", "medium", "high", "verified"]
    },
    "evidenceRefList": {
      "type": "array",
      "items": { "type": "string" },
      "uniqueItems": true
    },
    "namedItem": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "name"],
      "properties": {
        "id": { "type": "string", "minLength": 1 },
        "name": { "type": "string", "minLength": 1 },
        "type": { "type": ["string", "null"] },
        "description": { "type": ["string", "null"] },
        "evidence_refs": { "$ref": "#/$defs/evidenceRefList" },
        "confidence": { "$ref": "#/$defs/confidence" }
      }
    },
    "interface": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "name", "kind"],
      "properties": {
        "id": { "type": "string", "minLength": 1 },
        "name": { "type": "string", "minLength": 1 },
        "kind": { "type": "string", "enum": ["screen", "view", "route", "fragment", "activity", "page", "component", "other"] },
        "parent_id": { "type": ["string", "null"] },
        "entry": { "type": "boolean" },
        "navigation_targets": { "type": "array", "items": { "type": "string" } },
        "resource_refs": { "type": "array", "items": { "type": "string" } },
        "evidence_refs": { "$ref": "#/$defs/evidenceRefList" },
        "confidence": { "$ref": "#/$defs/confidence" }
      }
    },
    "behavior": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "name"],
      "properties": {
        "id": { "type": "string", "minLength": 1 },
        "name": { "type": "string", "minLength": 1 },
        "trigger": { "type": ["string", "null"] },
        "effect": { "type": ["string", "null"] },
        "state_changes": { "type": "array", "items": { "type": "string" } },
        "evidence_refs": { "$ref": "#/$defs/evidenceRefList" },
        "confidence": { "$ref": "#/$defs/confidence" }
      }
    },
    "api": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "base"],
      "properties": {
        "id": { "type": "string", "minLength": 1 },
        "base": { "type": "string", "minLength": 1 },
        "endpoints": { "type": "array", "items": { "type": "string" } },
        "auth_dependency": { "type": ["string", "null"] },
        "evidence_refs": { "$ref": "#/$defs/evidenceRefList" },
        "confidence": { "$ref": "#/$defs/confidence" }
      }
    },
    "component": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "name", "role", "members", "evidence_refs", "confidence"],
      "properties": {
        "id": { "type": "string", "minLength": 1 },
        "name": { "type": "string", "minLength": 1 },
        "role": {
          "type": "string",
          "enum": [
            "catalog",
            "search",
            "detail",
            "player",
            "favorites",
            "profiles",
            "authentication",
            "ads",
            "downloads",
            "navigation",
            "data_source",
            "stream_resolution",
            "subtitles",
            "analytics",
            "settings",
            "other"
          ]
        },
        "description": { "type": ["string", "null"] },
        "members": { "type": "array", "items": { "type": "string" }, "uniqueItems": true },
        "depends_on": { "type": "array", "items": { "type": "string" }, "uniqueItems": true },
        "required_permissions": { "type": "array", "items": { "type": "string" } },
        "external_services": { "type": "array", "items": { "type": "string" } },
        "reuse_assessment": {
          "type": "string",
          "enum": ["unknown", "reusable", "adaptable", "rebuild_recommended", "not_reusable"]
        },
        "evidence_refs": { "$ref": "#/$defs/evidenceRefList" },
        "confidence": { "$ref": "#/$defs/confidence" }
      }
    },
    "dependency": {
      "type": "object",
      "additionalProperties": false,
      "required": ["from", "to", "kind"],
      "properties": {
        "from": { "type": "string", "minLength": 1 },
        "to": { "type": "string", "minLength": 1 },
        "kind": {
          "type": "string",
          "enum": ["code", "resource", "runtime", "data", "network", "auth", "media", "navigation", "library", "service", "other"]
        },
        "required": { "type": "boolean" },
        "evidence_refs": { "$ref": "#/$defs/evidenceRefList" }
      }
    },
    "evidence": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id", "kind", "locator"],
      "properties": {
        "id": { "type": "string", "minLength": 1 },
        "kind": {
          "type": "string",
          "enum": ["file", "class", "method", "resource", "manifest", "endpoint", "network_trace", "screenshot", "runtime_trace", "certificate", "library", "other"]
        },
        "locator": { "type": "string", "minLength": 1 },
        "excerpt": { "type": ["string", "null"] },
        "hash_sha256": { "type": ["string", "null"] },
        "tool": { "type": ["string", "null"] },
        "observed_at": { "type": ["string", "null"] }
      }
    }
  }
}
JSON

echo "=== 2. INSTALL OBJECTIVE SCHEMA V1 ==="
cat >"$ROOT/objective.schema.json" <<'JSON'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://central.local/schema/v1/objective.schema.json",
  "title": "Central Objective V1",
  "type": "object",
  "additionalProperties": false,
  "required": ["schema_version", "analysis_id", "keep", "remove", "adapt", "rebuild", "target"],
  "properties": {
    "schema_version": { "const": "central.objective.v1" },
    "analysis_id": { "type": "string", "minLength": 1 },
    "keep": { "type": "array", "items": { "type": "string" }, "uniqueItems": true },
    "remove": { "type": "array", "items": { "type": "string" }, "uniqueItems": true },
    "adapt": { "type": "array", "items": { "type": "string" }, "uniqueItems": true },
    "rebuild": { "type": "array", "items": { "type": "string" }, "uniqueItems": true },
    "target": {
      "type": "object",
      "additionalProperties": true,
      "required": ["platform"],
      "properties": {
        "platform": { "type": "string", "minLength": 1 },
        "form_factor": { "type": ["string", "null"] },
        "orientation": { "type": ["string", "null"] },
        "constraints": { "type": "array", "items": { "type": "string" } }
      }
    },
    "notes": { "type": "array", "items": { "type": "string" } }
  }
}
JSON

echo "=== 3. INSTALL TRANSFORMATION PLAN SCHEMA V1 ==="
cat >"$ROOT/transformation-plan.schema.json" <<'JSON'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://central.local/schema/v1/transformation-plan.schema.json",
  "title": "Central Transformation Plan V1",
  "type": "object",
  "additionalProperties": false,
  "required": ["schema_version", "analysis_id", "objective_id", "steps"],
  "properties": {
    "schema_version": { "const": "central.transformation-plan.v1" },
    "analysis_id": { "type": "string", "minLength": 1 },
    "objective_id": { "type": "string", "minLength": 1 },
    "steps": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["id", "action", "strategy", "targets", "verification"],
        "properties": {
          "id": { "type": "string", "minLength": 1 },
          "action": { "type": "string", "minLength": 1 },
          "strategy": { "type": "string", "enum": ["reuse", "adapt", "rebuild", "remove", "verify"] },
          "targets": { "type": "array", "items": { "type": "string" } },
          "depends_on_steps": { "type": "array", "items": { "type": "string" } },
          "verification": { "type": "array", "items": { "type": "string" } },
          "risk": { "type": "string", "enum": ["low", "medium", "high"] }
        }
      }
    }
  }
}
JSON

echo "=== 4. INSTALL RESULT SCHEMA V1 ==="
cat >"$ROOT/result.schema.json" <<'JSON'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://central.local/schema/v1/result.schema.json",
  "title": "Central Build Result V1",
  "type": "object",
  "additionalProperties": false,
  "required": ["schema_version", "analysis_id", "status", "artifacts", "validation"],
  "properties": {
    "schema_version": { "const": "central.result.v1" },
    "analysis_id": { "type": "string", "minLength": 1 },
    "status": { "type": "string", "enum": ["completed", "partial", "failed"] },
    "artifacts": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["name", "path"],
        "properties": {
          "name": { "type": "string" },
          "path": { "type": "string" },
          "sha256": { "type": ["string", "null"] }
        }
      }
    },
    "validation": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["check", "ok"],
        "properties": {
          "check": { "type": "string" },
          "ok": { "type": "boolean" },
          "detail": { "type": ["string", "null"] }
        }
      }
    },
    "notes": { "type": "array", "items": { "type": "string" } }
  }
}
JSON

echo "=== 5. INSTALL README + EXAMPLE ==="
cat >"$ROOT/README.md" <<'EOF'
# Central Canonical Model V1

Este directorio define el idioma interno de Central para analizar y transformar productos.

## Documentos

1. analysis.schema.json
   Describe qué es el producto actual y qué evidencia respalda cada conclusión.

2. objective.schema.json
   Describe qué quiere conservar, eliminar, adaptar o reconstruir el usuario.

3. transformation-plan.schema.json
   Describe cómo ir del estado analizado al objetivo.

4. result.schema.json
   Describe qué se construyó y cómo fue validado.

## Regla central

Toda conclusión importante del análisis debe poder apuntar a evidencia.
Los componentes funcionales son la unidad de conversación con el usuario.
Las clases, archivos, endpoints y recursos son evidencia y miembros técnicos, no la interfaz principal del sistema.

## Estrategias permitidas

- reuse
- adapt
- rebuild
- remove
- verify

## Entradas soportadas conceptualmente

- APK
- XAPK
- aplicación Android instalada
- URL/web/PWA
- proyecto con código
- paquete de escritorio
- otras fuentes futuras

Todas las fuentes deben normalizarse a analysis.schema.json antes de pasar a objetivo o transformación.
EOF

cat >"$ROOT/example-analysis.json" <<'JSON'
{
  "schema_version": "central.analysis.v1",
  "analysis_id": "AN-DEMO-001",
  "created_at": "2026-09-22T00:00:00Z",
  "source": {
    "kind": "apk",
    "origin": "demo.apk",
    "artifact_name": "demo.apk",
    "package_name": "example.demo",
    "version": "1.0",
    "hash_sha256": null,
    "captured_at": null
  },
  "identity": {
    "name": "Demo",
    "platform": "android",
    "description": "Ejemplo mínimo",
    "entrypoints": ["MainActivity"]
  },
  "interfaces": [],
  "behaviors": [],
  "data": {
    "models": [],
    "local_storage": [],
    "apis": [],
    "formats": []
  },
  "media": {
    "players": [],
    "streams": [],
    "codecs": [],
    "drm": [],
    "subtitles": []
  },
  "security": {
    "authentication": [],
    "permissions": [],
    "certificates": [],
    "restrictions": []
  },
  "components": [
    {
      "id": "component.catalog",
      "name": "Catálogo",
      "role": "catalog",
      "description": "Listado principal",
      "members": ["MainActivity"],
      "depends_on": [],
      "required_permissions": [],
      "external_services": [],
      "reuse_assessment": "unknown",
      "evidence_refs": ["ev.main"],
      "confidence": "high"
    }
  ],
  "dependencies": [],
  "evidence": [
    {
      "id": "ev.main",
      "kind": "class",
      "locator": "MainActivity",
      "excerpt": null,
      "hash_sha256": null,
      "tool": "demo",
      "observed_at": null
    }
  ],
  "notes": []
}
JSON

echo "=== 6. INSTALL STDLIB VALIDATOR ==="
cat >"$ROOT/validate_canon.py" <<'PY'
#!/usr/bin/env python3
import json,sys
from pathlib import Path

ROOT=Path(__file__).resolve().parent
SCHEMAS={
    "central.analysis.v1":"analysis.schema.json",
    "central.objective.v1":"objective.schema.json",
    "central.transformation-plan.v1":"transformation-plan.schema.json",
    "central.result.v1":"result.schema.json",
}

REQUIRED={
    "central.analysis.v1":["analysis_id","created_at","source","identity","components","dependencies","evidence"],
    "central.objective.v1":["analysis_id","keep","remove","adapt","rebuild","target"],
    "central.transformation-plan.v1":["analysis_id","objective_id","steps"],
    "central.result.v1":["analysis_id","status","artifacts","validation"],
}

def fail(msg):
    print("CANON_INVALID: "+msg)
    raise SystemExit(1)

def main():
    if len(sys.argv)!=2:
        fail("usage validate_canon.py <file.json>")
    p=Path(sys.argv[1])
    try:
        obj=json.loads(p.read_text(encoding="utf-8"))
    except Exception as e:
        fail("bad_json: "+str(e))
    version=obj.get("schema_version")
    if version not in SCHEMAS:
        fail("unknown schema_version: "+str(version))
    missing=[k for k in REQUIRED[version] if k not in obj]
    if missing:
        fail("missing fields: "+",".join(missing))

    # Cross-reference checks for analysis.
    if version=="central.analysis.v1":
        ev={x.get("id") for x in obj.get("evidence",[]) if isinstance(x,dict)}
        comps={x.get("id") for x in obj.get("components",[]) if isinstance(x,dict)}
        for c in obj.get("components",[]):
            for ref in c.get("evidence_refs",[]):
                if ref not in ev:
                    fail("component evidence ref not found: "+str(ref))
            for dep in c.get("depends_on",[]):
                if dep not in comps:
                    fail("component dependency not found: "+str(dep))
        for d in obj.get("dependencies",[]):
            for side in ("from","to"):
                val=d.get(side)
                if val and val not in comps:
                    # Technical dependencies may point to members/resources and are allowed.
                    pass

    print("CANON_VALID")
    print("schema_version="+version)

if __name__=="__main__":
    main()
PY
chmod 755 "$ROOT/validate_canon.py"

echo "=== 7. VERIFY SCHEMAS + EXAMPLE ==="
python3 - <<'PY'
import json
from pathlib import Path
root=Path("/home/ubuntu/Central/canon/v1")
for name in (
    "analysis.schema.json",
    "objective.schema.json",
    "transformation-plan.schema.json",
    "result.schema.json",
):
    x=json.load(open(root/name,encoding="utf-8"))
    assert x["$schema"].endswith("2020-12/schema")
    assert x["title"]
    print("SCHEMA_JSON_OK",name)
PY

python3 "$ROOT/validate_canon.py" "$ROOT/example-analysis.json"
echo CANON_V1_EXAMPLE_VALID_OK

echo "=== 8. VERIFY REQUIRED CONTRACT ELEMENTS ==="
python3 - <<'PY'
import json
p="/home/ubuntu/Central/canon/v1/analysis.schema.json"
x=json.load(open(p,encoding="utf-8"))
props=x["properties"]
for k in ("source","identity","interfaces","behaviors","data","media","security","components","dependencies","evidence"):
    assert k in props,k
roles=x["$defs"]["component"]["properties"]["role"]["enum"]
for r in ("catalog","search","detail","player","authentication","ads","data_source","stream_resolution"):
    assert r in roles,r
print("CANON_V1_CORE_CONTRACT_OK")
PY

echo CENTRAL_CANONICAL_MODEL_V1_READY
echo "root=$ROOT"
echo "backup=$BACKUP"
