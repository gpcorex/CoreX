#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/ubuntu/Central/repository_backend_v1
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/home/ubuntu/Central/backups/repository-backend-v1-$STAMP
mkdir -p "$ROOT" "$BACKUP"

echo "=== 1. FIND LATEST REAL COMPLETED PROJECT ==="
LATEST=$(python3 - <<'PY'
import json
rows=json.load(open("/home/ubuntu/Central/auditor_ui_v1/data/runs.json",encoding="utf-8"))
for r in rows:
    if r.get("status")=="COMPLETED" and r.get("project_id"):
        print(r["project_id"])
        break
PY
)
test -n "$LATEST"
echo "project=$LATEST"

SC="/home/ubuntu/Central/projects/$LATEST/work/component-packages/detail/CLEAN_ADAPTER"
test -d "$SC"

echo "=== 2. INSTALL CLEAN FILE BACKEND ==="
mkdir -p "$SC/backend" "$SC/data"

cat >"$SC/backend/FileRepositoryBackend.kt" <<'KT'
package central.clean.detailmetadata.backend

import central.clean.detailmetadata.adapter.RepositoryBackend
import central.clean.detailmetadata.models.*
import java.io.File

class FileRepositoryBackend(
    private val dataDir: File
) : RepositoryBackend {

    private data class RepoRow(
        val repoId: Long,
        val address: String,
        val username: String?,
        val password: String?,
        val certificate: String?,
        val mirrors: List<String>
    )

    private data class VersionRow(
        val repoId: Long,
        val versionCode: Long?,
        val versionName: String?,
        val fileName: String?,
        val fileUrl: String?,
        val fileSize: Long?
    )

    private fun unescape(s: String): String =
        s.replace("\\t", "\t").replace("\\n", "\n").replace("\\\\", "\\")

    private fun nullable(s: String): String? =
        unescape(s).takeIf { it.isNotEmpty() }

    private fun readRepos(): List<RepoRow> {
        val f = File(dataDir, "repositories.tsv")
        require(f.isFile) { "repositories.tsv not found: " + f.absolutePath }
        return f.readLines()
            .filter { it.isNotBlank() && !it.startsWith("#") }
            .map { line ->
                val p = line.split("\t")
                require(p.size >= 6) { "Invalid repository row: " + line }
                RepoRow(
                    repoId = p[0].toLong(),
                    address = unescape(p[1]),
                    username = nullable(p[2]),
                    password = nullable(p[3]),
                    certificate = nullable(p[4]),
                    mirrors = if (p[5].isBlank()) emptyList() else p[5].split("|").map(::unescape)
                )
            }
    }

    private fun readVersions(): List<VersionRow> {
        val f = File(dataDir, "versions.tsv")
        require(f.isFile) { "versions.tsv not found: " + f.absolutePath }
        return f.readLines()
            .filter { it.isNotBlank() && !it.startsWith("#") }
            .map { line ->
                val p = line.split("\t")
                require(p.size >= 6) { "Invalid version row: " + line }
                VersionRow(
                    repoId = p[0].toLong(),
                    versionCode = nullable(p[1])?.toLong(),
                    versionName = nullable(p[2]),
                    fileName = nullable(p[3]),
                    fileUrl = nullable(p[4]),
                    fileSize = nullable(p[5])?.toLong()
                )
            }
    }

    override suspend fun loadRepositoryById(repoId: Long): RepositoryModel {
        val r = readRepos().firstOrNull { it.repoId == repoId }
            ?: error("Repository not found: " + repoId)
        return RepositoryModel(
            repoId = r.repoId,
            address = r.address,
            username = r.username,
            password = r.password,
            certificate = r.certificate
        )
    }

    override suspend fun listMirrors(repoId: Long): List<MirrorModel> {
        val r = readRepos().firstOrNull { it.repoId == repoId }
            ?: error("Repository not found: " + repoId)
        return r.mirrors.map(::MirrorModel)
    }

    override suspend fun repositoryAddress(repoId: Long): String =
        loadRepositoryById(repoId).address
            ?: error("Repository address missing: " + repoId)

    override suspend fun repositoryCredentials(repoId: Long): Map<String, String?> {
        val r = loadRepositoryById(repoId)
        return mapOf(
            "username" to r.username,
            "password" to r.password,
            "certificate" to r.certificate
        )
    }

    override suspend fun repositoryForVersion(version: VersionModel): RepositoryModel =
        loadRepositoryById(version.repoId)

    override suspend fun versionFile(version: VersionModel): VersionFileModel {
        val rows = readVersions().filter { it.repoId == version.repoId }
        val v = rows.firstOrNull {
            (version.versionCode == null || it.versionCode == version.versionCode) &&
            (version.versionName == null || it.versionName == version.versionName)
        } ?: error("Version file not found")
        return VersionFileModel(
            name = v.fileName,
            url = v.fileUrl,
            size = v.fileSize
        )
    }
}
KT

cat >"$SC/data/repositories.tsv" <<'EOF'
# repoId	address	username	password	certificate	mirrors
1	https://repo.example.invalid/fdroid				https://mirror1.example.invalid/fdroid|https://mirror2.example.invalid/fdroid
2	https://repo2.example.invalid/fdroid	user	pass	CERTIFICATE_PLACEHOLDER	https://mirror3.example.invalid/fdroid
EOF

cat >"$SC/data/versions.tsv" <<'EOF'
# repoId	versionCode	versionName	fileName	fileUrl	fileSize
1	100	1.0.0	app-1.0.0.apk	https://repo.example.invalid/fdroid/app-1.0.0.apk	123456
1	110	1.1.0	app-1.1.0.apk	https://repo.example.invalid/fdroid/app-1.1.0.apk	234567
2	200	2.0.0	app2-2.0.0.apk	https://repo2.example.invalid/fdroid/app2-2.0.0.apk	345678
EOF

echo REPOSITORY_BACKEND_V1_SOURCE_OK

echo "=== 3. REPLACE SMOKE TEST WITH STDLIB-ONLY RUNNER ==="
cp -a "$SC/tests/SmokeTest.kt" "$BACKUP/SmokeTest.kt.before"

cat >"$SC/tests/SmokeTest.kt" <<'KT'
package central.clean.detailmetadata.tests

import central.clean.detailmetadata.adapter.RepositoryServiceAdapter
import central.clean.detailmetadata.backend.FileRepositoryBackend
import central.clean.detailmetadata.models.VersionModel
import java.io.File
import kotlin.coroutines.*

fun <T> runSuspend(block: suspend () -> T): T {
    var value: T? = null
    var failure: Throwable? = null
    block.startCoroutine(object : Continuation<T> {
        override val context: CoroutineContext = EmptyCoroutineContext
        override fun resumeWith(result: Result<T>) {
            result.fold({ value = it }, { failure = it })
        }
    })
    failure?.let { throw it }
    @Suppress("UNCHECKED_CAST")
    return value as T
}

object SmokeTest {
    @JvmStatic
    fun main(args: Array<String>) {
        val dataDir = File(args.firstOrNull() ?: error("data directory argument required"))
        val service = RepositoryServiceAdapter(FileRepositoryBackend(dataDir))

        runSuspend {
            val repo = service.loadRepository(1)
            check(repo.repoId == 1L)
            check(repo.address == "https://repo.example.invalid/fdroid")

            val mirrors = service.getRepositoryMirrors(1)
            check(mirrors.size == 2)
            check(mirrors.first().url.contains("mirror1"))

            check(service.getRepositoryAddress(1) == "https://repo.example.invalid/fdroid")

            val creds = service.getRepositoryCredentials(2)
            check(creds["username"] == "user")
            check(creds["password"] == "pass")

            val version = VersionModel(repoId = 1, versionCode = 110, versionName = "1.1.0")
            check(service.getRepositoryForVersion(version).repoId == 1L)

            val file = service.getAppVersionFile(version)
            check(file.name == "app-1.1.0.apk")
            check(file.size == 234567L)
        }

        println("CLEAN_REPOSITORY_BACKEND_SMOKE_OK")
    }
}
KT

echo REPOSITORY_BACKEND_V1_SMOKE_SOURCE_OK

echo "=== 4. ENSURE KOTLIN COMPILER ==="
if ! command -v kotlinc >/dev/null 2>&1; then
  sudo apt-get update -y >/dev/null
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y kotlin >/dev/null
fi
kotlinc -version 2>&1 | head -n1
echo REPOSITORY_BACKEND_V1_KOTLIN_OK

echo "=== 5. COMPILE CLEAN ADAPTER + FILE BACKEND ==="
BUILD="$SC/build-v1"
rm -rf "$BUILD"
mkdir -p "$BUILD"

kotlinc   "$SC/models/Models.kt"   "$SC/adapter/RepositoryService.kt"   "$SC/adapter/RepositoryBackend.kt"   "$SC/adapter/RepositoryServiceAdapter.kt"   "$SC/backend/FileRepositoryBackend.kt"   "$SC/tests/SmokeTest.kt"   -include-runtime   -d "$BUILD/detail-backend-v1.jar"

test -s "$BUILD/detail-backend-v1.jar"
echo REPOSITORY_BACKEND_V1_COMPILE_OK

echo "=== 6. RUN RUNTIME SMOKE TEST ==="
java -cp "$BUILD/detail-backend-v1.jar" central.clean.detailmetadata.tests.SmokeTest "$SC/data"
echo REPOSITORY_BACKEND_V1_RUNTIME_OK

echo "=== 7. WRITE BACKEND STATUS ==="
python3 - "$SC" "$BUILD/detail-backend-v1.jar" <<'PY'
import json,sys
from pathlib import Path
sc=Path(sys.argv[1]); jar=Path(sys.argv[2])
plan=json.load(open(sc/"build-plan.json",encoding="utf-8"))
plan["implementation_status"]="FUNCTIONAL_LOCAL_BACKEND"
plan["runtime_backend_required"]=False
plan["backend"]={
  "kind":"file_tsv",
  "implementation":"backend/FileRepositoryBackend.kt",
  "data":["data/repositories.tsv","data/versions.tsv"],
  "compiled_jar":str(jar),
  "validated":True,
  "scope":"clean local data source; no original Activities/UI dependency"
}
plan["next_step"]="Replace or extend the file data source with a live clean repository source while preserving RepositoryService."
(sc/"build-plan.json").write_text(json.dumps(plan,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
readme=sc/"README.md"
txt=readme.read_text(encoding="utf-8")
if "FUNCTIONAL_LOCAL_BACKEND" not in txt:
    txt += "\n## Runtime backend\nFUNCTIONAL_LOCAL_BACKEND\n\nThe six clean operations compile and pass a runtime smoke test against FileRepositoryBackend.\n"
readme.write_text(txt,encoding="utf-8")
print("REPOSITORY_BACKEND_V1_STATUS_OK")
PY

echo CENTRAL_REPOSITORY_BACKEND_V1_READY
echo "project_tested=$LATEST"
echo "scaffold=$SC"
echo "jar=$BUILD/detail-backend-v1.jar"
echo "backup=$BACKUP"
