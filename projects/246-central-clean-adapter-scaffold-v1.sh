#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/ubuntu/Central/clean_adapter_scaffold_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/clean-adapter-scaffold-v1-$STAMP
mkdir -p "$ROOT" "$BACKUP"

echo "=== 1. INSTALL CLEAN ADAPTER SCAFFOLD V1 ==="
cat >"$ROOT/build_clean_adapter_scaffold.py" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, re, textwrap
from pathlib import Path

PROJECTS=Path("/home/ubuntu/Central/projects")

def kt_type(t:str)->str:
    m={
      "long":"Long","String":"String","String?":"String?",
      "Repository":"RepositoryModel","List<URL>":"List<MirrorModel>",
      "AppVersion":"VersionModel","FileV1":"VersionFileModel"
    }
    return m.get(t,t)

def safe_ident(name:str)->str:
    return re.sub(r'[^A-Za-z0-9_]','_',name)

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("project_id")
    ap.add_argument("role")
    args=ap.parse_args()

    root=PROJECTS/args.project_id
    iface_path=root/"work"/"component-packages"/args.role/"INTERFACE"/"interface.json"
    if not iface_path.is_file():
        raise SystemExit("INTERFACE_NOT_FOUND")

    iface=json.load(open(iface_path,encoding="utf-8"))
    ops=iface.get("operations") or []
    if not ops:
        raise SystemExit("NO_INTERFACE_OPERATIONS")

    out=root/"work"/"component-packages"/args.role/"CLEAN_ADAPTER"
    (out/"adapter").mkdir(parents=True,exist_ok=True)
    (out/"models").mkdir(parents=True,exist_ok=True)
    (out/"tests").mkdir(parents=True,exist_ok=True)
    (out/"contracts").mkdir(parents=True,exist_ok=True)

    # Contract snapshot
    (out/"contracts"/"interface.json").write_text(json.dumps(iface,ensure_ascii=False,indent=2)+chr(10),encoding="utf-8")

    # Models
    models = """package central.clean.detailmetadata.models

data class RepositoryModel(
    val repoId: Long,
    val address: String? = null,
    val username: String? = null,
    val password: String? = null,
    val certificate: String? = null
)

data class MirrorModel(
    val url: String
)

data class VersionModel(
    val repoId: Long,
    val versionCode: Long? = null,
    val versionName: String? = null
)

data class VersionFileModel(
    val name: String? = null,
    val url: String? = null,
    val size: Long? = null
)
"""
    (out/"models"/"Models.kt").write_text(models,encoding="utf-8")

    # Interface generated only from synthesized operations.
    lines=[
      "package central.clean.detailmetadata.adapter",
      "",
      "import central.clean.detailmetadata.models.*",
      "",
      "interface RepositoryService {"
    ]
    for op in ops:
        params=", ".join(f"{safe_ident(x['name'])}: {kt_type(x['type'])}" for x in op.get("inputs",[]))
        outs=op.get("outputs") or []
        if len(outs)==1:
            ret=kt_type(outs[0]["type"])
        else:
            ret="Map<String, Any?>"
        lines.append(f"    suspend fun {safe_ident(op['name'])}({params}): {ret}")
    lines.append("}")
    (out/"adapter"/"RepositoryService.kt").write_text("\n".join(lines)+chr(10),encoding="utf-8")

    # Backend boundary keeps original implementation details out of public contract.
    backend = """package central.clean.detailmetadata.adapter

import central.clean.detailmetadata.models.*

interface RepositoryBackend {
    suspend fun loadRepositoryById(repoId: Long): RepositoryModel
    suspend fun listMirrors(repoId: Long): List<MirrorModel>
    suspend fun repositoryAddress(repoId: Long): String
    suspend fun repositoryCredentials(repoId: Long): Map<String, String?>
    suspend fun repositoryForVersion(version: VersionModel): RepositoryModel
    suspend fun versionFile(version: VersionModel): VersionFileModel
}
"""
    (out/"adapter"/"RepositoryBackend.kt").write_text(backend,encoding="utf-8")

    impl = """package central.clean.detailmetadata.adapter

import central.clean.detailmetadata.models.*

class RepositoryServiceAdapter(
    private val backend: RepositoryBackend
) : RepositoryService {

    override suspend fun loadRepository(repoId: Long): RepositoryModel =
        backend.loadRepositoryById(repoId)

    override suspend fun getRepositoryMirrors(repoId: Long): List<MirrorModel> =
        backend.listMirrors(repoId)

    override suspend fun getRepositoryAddress(repoId: Long): String =
        backend.repositoryAddress(repoId)

    override suspend fun getRepositoryCredentials(repoId: Long): Map<String, Any?> =
        backend.repositoryCredentials(repoId)

    override suspend fun getRepositoryForVersion(version: VersionModel): RepositoryModel =
        backend.repositoryForVersion(version)

    override suspend fun getAppVersionFile(version: VersionModel): VersionFileModel =
        backend.versionFile(version)
}
"""
    (out/"adapter"/"RepositoryServiceAdapter.kt").write_text(impl,encoding="utf-8")

    fake = """package central.clean.detailmetadata.tests

import central.clean.detailmetadata.adapter.RepositoryBackend
import central.clean.detailmetadata.models.*

class FakeRepositoryBackend : RepositoryBackend {
    override suspend fun loadRepositoryById(repoId: Long) =
        RepositoryModel(repoId = repoId, address = "https://example.invalid")

    override suspend fun listMirrors(repoId: Long) =
        listOf(MirrorModel("https://mirror.example.invalid/$repoId"))

    override suspend fun repositoryAddress(repoId: Long) =
        "https://example.invalid/$repoId"

    override suspend fun repositoryCredentials(repoId: Long) =
        mapOf("username" to null, "password" to null, "certificate" to null)

    override suspend fun repositoryForVersion(version: VersionModel) =
        RepositoryModel(repoId = version.repoId)

    override suspend fun versionFile(version: VersionModel) =
        VersionFileModel(name = version.versionName)
}
"""
    (out/"tests"/"FakeRepositoryBackend.kt").write_text(fake,encoding="utf-8")

    test = """package central.clean.detailmetadata.tests

import central.clean.detailmetadata.adapter.RepositoryServiceAdapter
import central.clean.detailmetadata.models.VersionModel
import kotlinx.coroutines.runBlocking

object SmokeTest {
    @JvmStatic
    fun main(args: Array<String>) = runBlocking {
        val service = RepositoryServiceAdapter(FakeRepositoryBackend())
        check(service.loadRepository(1).repoId == 1L)
        check(service.getRepositoryMirrors(1).isNotEmpty())
        check(service.getRepositoryAddress(1).isNotBlank())
        check(service.getRepositoryCredentials(1).isNotEmpty())
        check(service.getRepositoryForVersion(VersionModel(1)).repoId == 1L)
        service.getAppVersionFile(VersionModel(1))
        println("CLEAN_ADAPTER_SMOKE_OK")
    }
}
"""
    (out/"tests"/"SmokeTest.kt").write_text(test,encoding="utf-8")

    # Build plan deliberately keeps runtime connection unresolved.
    plan={
      "schema_version":"central.clean-adapter-plan.v1",
      "project_id":args.project_id,
      "role":args.role,
      "source_interface":str(iface_path),
      "operation_count":len(ops),
      "implementation_status":"SCAFFOLDED_NOT_CONNECTED",
      "runtime_backend_required":True,
      "operations":[
        {
          "name":op["name"],
          "confidence":op["confidence"],
          "evidence_count":len(op.get("evidence") or [])
        } for op in ops
      ],
      "next_step":"Implement RepositoryBackend against a clean data source and validate each operation with fixtures."
    }
    (out/"build-plan.json").write_text(json.dumps(plan,ensure_ascii=False,indent=2)+chr(10),encoding="utf-8")

    readme=f"""# Clean Adapter Scaffold — {args.role}

This scaffold was generated from the synthesized clean interface.

## Status
SCAFFOLDED_NOT_CONNECTED

## Structure
- adapter/RepositoryService.kt — public clean contract
- adapter/RepositoryBackend.kt — backend boundary
- adapter/RepositoryServiceAdapter.kt — adapter implementation
- models/Models.kt — clean DTOs
- tests/ — fake backend + smoke test
- contracts/interface.json — source interface evidence
- build-plan.json — implementation state

## Important
This scaffold does not copy original app UI code and is not yet connected to a live backend.
Its purpose is to freeze the clean contract before implementing behavior.
"""
    (out/"README.md").write_text(readme,encoding="utf-8")

    result={
      "ok":True,
      "project_id":args.project_id,
      "role":args.role,
      "scaffold_path":str(out),
      "operation_count":len(ops),
      "files":[str(p.relative_to(out)) for p in sorted(out.rglob("*")) if p.is_file()],
      "status":"SCAFFOLDED_NOT_CONNECTED"
    }
    print(json.dumps(result,ensure_ascii=False))

if __name__=="__main__":
    main()
PY

chmod 755 "$ROOT/build_clean_adapter_scaffold.py"
python3 -m py_compile "$ROOT/build_clean_adapter_scaffold.py"
echo CLEAN_ADAPTER_SCAFFOLD_V1_SOURCE_OK

echo "=== 2. BUILD DETAIL METADATA SCAFFOLD ==="
LATEST=$(python3 - <<'PY'
import json
rows=json.load(open("/home/ubuntu/Central/auditor_ui_v1/data/runs.json",encoding="utf-8"))
for r in rows:
    if r.get("status")=="COMPLETED" and r.get("project_id"):
        print(r["project_id"]);break
PY
)
test -n "$LATEST"
echo "project=$LATEST"

OUT=$(sudo -u ubuntu python3 "$ROOT/build_clean_adapter_scaffold.py" "$LATEST" detail)
echo "$OUT"

python3 - "$OUT" <<'PY'
import json,sys,os
x=json.loads(sys.argv[1])
assert x["ok"] is True
assert x["status"]=="SCAFFOLDED_NOT_CONNECTED"
assert x["operation_count"]==6
root=x["scaffold_path"]
required=[
 "adapter/RepositoryService.kt",
 "adapter/RepositoryBackend.kt",
 "adapter/RepositoryServiceAdapter.kt",
 "models/Models.kt",
 "tests/FakeRepositoryBackend.kt",
 "tests/SmokeTest.kt",
 "contracts/interface.json",
 "build-plan.json",
 "README.md"
]
for rel in required:
    assert os.path.isfile(os.path.join(root,rel)), rel
print("DETAIL_CLEAN_ADAPTER_SCAFFOLD_OK")
print("scaffold="+root)
print("files="+json.dumps(x["files"],ensure_ascii=False))
PY

echo "=== 3. VERIFY GENERATED PUBLIC CONTRACT OPERATIONS ==="
SC="/home/ubuntu/Central/projects/$LATEST/work/component-packages/detail/CLEAN_ADAPTER/adapter/RepositoryService.kt"
for op in loadRepository getRepositoryMirrors getRepositoryAddress getRepositoryCredentials getRepositoryForVersion getAppVersionFile; do
  grep -q "fun $op" "$SC"
done
echo DETAIL_CLEAN_ADAPTER_CONTRACT_OK

echo CENTRAL_CLEAN_ADAPTER_SCAFFOLD_V1_READY
echo "project_tested=$LATEST"
echo "backup=$BACKUP"
