# Gluten + Velox Windows Port — Status Report

**Last updated:** 2026-05-26
**Author:** [anton2681](https://github.com/anton2681) (Huajiang Jiang, Microsoft intern, 2026)
**Base work:** Forked from [gangpeng/gluten](https://github.com/gangpeng/gluten) commit `2fcfd4acf [WINDOWS] Add MSVC/Windows support for Gluten Velox backend` and [gangpeng/velox](https://github.com/gangpeng/velox) commit `d62c6b425 [WINDOWS] Add MSVC/Windows port for Velox`.

---

## TL;DR

The base Windows port from gangpeng got the code to **compile** on MSVC. This branch takes it from "compile passes" to **"spark-submit actually runs SQL queries end-to-end"** by fixing 19+ runtime issues spanning CMake, JNI, packaging, native time-zone parsing, Arrow C Data Interface, and JVM module-system access.

### Final state

```text
=== Spark 3.5.3 session created with Gluten plugin ===

== Physical Plan ==
VeloxColumnarToRow
+- ^(3) SortExecTransformer [mod5#5L ASC NULLS FIRST]
   +- ^(2) HashAggregateTransformer(keys=[mod5#5L], functions=[sum(doubled#4L)])
      +- ^(1) ProjectExecTransformer [(id#0L * 2) AS doubled#4L, (id#0L % 5) AS mod5#5L]
         +- ArrowColumnarToVeloxColumnar
            +- OffloadArrowData

=== Result ===
  mod5=0, total=1900
  mod5=1, total=1940
  mod5=2, total=1980
  mod5=3, total=2020
  mod5=4, total=2060
```

Plan operators all carry the `*Transformer` suffix → full Velox native offload confirmed.

---

## What works ✅

| Feature | Status | Notes |
|---|---|---|
| Compile `velox.dll` (80 MB) | ✅ | Static CRT (/MT), 116 sublibs auto-discovered |
| Compile `gluten.dll` (12 MB) | ✅ | `WINDOWS_EXPORT_ALL_SYMBOLS=ON` |
| `mvn package` produces gluten-velox-bundle JAR | ✅ | Includes shaded substrait/arrow/core classes |
| `spark-submit + GlutenPlugin` loads | ✅ | DLLs extract from JAR via `windows/amd64/` |
| `arrow_cdata_jni.dll` interop | ✅ | Built separately, injected at `x86_64/` resource path |
| Tzdb init with minimal UTC-only `tzdata.zi` | ✅ | At `C:\tools\velox-tzdata\` |
| SELECT / GROUP BY / SUM / aggregations | ✅ | Offloaded to Velox |
| Inner joins (SHJ) | ✅ | Default config |
| Left/Right outer joins (non-NULL keys) | ✅ | Default config |
| Broadcast hash join (non-NULL keys) | ✅ | Requires `spark.gluten.velox.buildHashTableOncePerExecutor.enabled=false` — see `tests/windows/run_test_bhj_narrow.bat` |

## What doesn't work ❌ (Known Limitations)

| Limitation | Root cause | Workaround | Proper fix |
|---|---|---|---|
| Full IANA `tzdata.zi` crashes `velox::tzdb::time_zone::__create` | Bug in gangpeng's velox tzdb parser on Windows (specific Zone record triggers bad `unique_ptr`) | Use minimal UTC-only `tzdata.zi` + `spark.sql.session.timeZone=UTC` | Debug which Zone record triggers; fix tzdb parser |
| Broadcast hash join returns empty results | Default `spark.gluten.velox.buildHashTableOncePerExecutor.enabled=true` ships only the prebuilt hash table to executors. Our 10-arg `HashJoinNode` drops the reuse args, so velox can't recover the prebuilt table and the "fall back to building new table" path has no input rows | Set `spark.gluten.velox.buildHashTableOncePerExecutor.enabled=false` — gluten then rebuilds the hash table per task with the actual rows in scope. Verified by `tests/windows/run_test_bhj_narrow.bat` | Backport upstream 12-arg signature into gangpeng's velox and re-enable prebuilt-table reuse |
| Joins with NULL keys in key column | NULL keys leave velox memory state in a way that produces bogus reservations (e.g. 459 GiB request); periodic stats poll previously deref'd `0xff...` inside `protobuf::SerializeToArray` and crashed the JVM | JVM crash fixed in `cpp/core/jni/JniWrapper.cc` (SEH guard around `ByteSizeLong` / `SerializeToArray` — stats degrade to empty blob instead of killing the process). Underlying OOM in left outer with NULL keys still fails the query — use `WHERE key IS NOT NULL` to dodge | Root-cause the velox NULL-key memory accounting (likely size_t underflow); alternative is to detect `joinHasNullKeys` in `SubstraitToVeloxPlan` SHJ path and `VELOX_NYI` so gluten falls back to vanilla Spark |
| Non-UTC session timezones not supported | Linked to tzdata limitation above | Force UTC | Same as tzdata fix |
| `arrow-dataset` JNI native lib (`arrow_dataset_jni.dll`) missing | We only built `arrow_cdata_jni.dll`; dataset JNI requires Arrow C++ runtime presence | Avoid `arrow.dataset.*` Java APIs | Build arrow_dataset_jni against Arrow C++ install |
| `kAllowInt32NarrowingSession` config not honored | Constant absent in gangpeng's velox snapshot — we pass the literal string `"allow_int32_narrowing"` which velox silently ignores | Live with default narrowing behavior | Use new config name once velox upstream is merged |
| `backends-velox` unit tests excluded | Test deps (scalatest, gluten-core test-jar) not resolved on Windows; renamed `src/test` → `src/test.bak` | None | Fix test classifier resolution in poms |

---

## Architecture overview

```text
┌──────────────────────────────────────────────────────────────┐
│  PySpark (Python)                                            │
└────────────────────┬─────────────────────────────────────────┘
                     │ Py4J
┌────────────────────▼─────────────────────────────────────────┐
│  Spark 3.5.3 (JVM, JDK 11)                                   │
│    + GlutenPlugin (Java/Scala)                               │
│    └─ loads windows/amd64/gluten.dll from bundle JAR         │
└────────────────────┬─────────────────────────────────────────┘
                     │ JNI
┌────────────────────▼─────────────────────────────────────────┐
│  gluten.dll (12 MB, MSVC /MT)                                │
│    - Substrait plan conversion (Java→native)                 │
│    - JNI dispatchers                                         │
│    - Loads windows/amd64/velox.dll                           │
└────────────────────┬─────────────────────────────────────────┘
                     │
┌────────────────────▼─────────────────────────────────────────┐
│  velox.dll (80 MB, MSVC /MT)                                 │
│    - Substrait → Velox plan adapter                          │
│    - Velox execution engine (~116 sublibs linked in)         │
│    - Embedded substrait protobuf descriptors (Windows-only   │
│      workaround for missing data globals export)             │
│    - Reads tzdata.zi from C:\tools\velox-tzdata\             │
└────────────────────┬─────────────────────────────────────────┘
                     │ Arrow C Data Interface
                     │ (arrow_cdata_jni.dll at x86_64/)
                     ▼
                  Columnar batch back to Java/Spark
```

---

## Changes made (organized)

### Category A — Build system (CMake / linker)

| File | Change | Why |
|---|---|---|
| `velox/CMakeLists.txt` | Add `CMP0091 NEW` + `CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded` before `project()` | Force /MT static CRT across all velox sublibs |
| `cpp/CMakeLists.txt` (gluten) | Same /MT enforcement + Windows defines: `GLOG_NO_ABBREVIATED_SEVERITIES NOMINMAX WIN32_LEAN_AND_MEAN NO_FIXED_STR_UDL _USE_MATH_DEFINES` | Glog macro conflicts, min/max macro pollution, folly user-defined literal collision |
| `cpp/velox/CMakeLists.txt` | Replace hardcoded `velox_part0..3` with `file(GLOB_RECURSE)` over 116 sublibs; compile substrait `.pb.cc` into velox.dll; add `/NODEFAULTLIB:msvcrt msvcrtd libcmtd` linker flags | `VELOX_MONO_LIBRARY=OFF` produces many sublibs; data globals can't cross DLL boundary on Windows; suppress Thrift's leftover dynamic-CRT hints |
| `cpp/core/CMakeLists.txt` | `ARROW_STATIC PARQUET_STATIC` defines; explicit zstd/snappy/lz4/zlib links; `WINDOWS_EXPORT_ALL_SYMBOLS=ON` | Static Arrow needs explicit compression deps; gluten was written for Linux-default symbol export |

### Category B — Velox source patches

| File | Change | Why |
|---|---|---|
| `velox/CMake/resolve_dependency_modules/arrow/CMakeLists.txt` | Add `-DARROW_PARQUET=ON -DARROW_FILESYSTEM=ON`; force `CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded` + `ARROW_USE_STATIC_CRT=ON` | Velox needs Parquet+filesystem; bundled Thrift must match velox CRT |
| `velox/CMake/resolve_dependency_modules/arrow/thrift-static-crt.patch` (manual edit to generated build) | Branch `EP_MSVC_RUNTIME_LIBRARY` on `ARROW_USE_STATIC_CRT` | Patch line offset didn't apply; manually edited `C:\ae\src\arrow_ep\cpp\cmake_modules\ThirdpartyToolchain.cmake` (**TODO: promote to a real patch file**) |

### Category C — Gluten C++ side (API drift fixes)

| File | Change | Why |
|---|---|---|
| `cpp/velox/substrait/SubstraitToVeloxPlan.cc` | `core::OpaqueHashTable` → `exec::BaseHashTable` (3 sites); `BOOLEAN()` → `::facebook::velox::BOOLEAN_()`; `HashJoinNode` 12-arg → 10-arg | gangpeng's velox snapshot uses different exec namespace; macro name collision with Windows headers; HashJoinNode missing trailing reuse args |
| `cpp/velox/substrait/SubstraitParser.cc`, `SubstraitToVeloxExpr.cc`, `VeloxSubstraitSignature.cc` | `BOOLEAN()` → `::facebook::velox::BOOLEAN_()` | Same as above |
| `cpp/velox/utils/ConfigExtractor.cc` | `HiveConfig::kAllowInt32NarrowingSession` → literal `"allow_int32_narrowing"` | Constant not exposed in gangpeng's snapshot; **velox silently ignores unknown configs — this feature may be inactive** |

### Category D — Backends-velox Scala patches (API drift)

| File | Change | Why |
|---|---|---|
| `backends-velox/src/main/scala/org/apache/gluten/backendsapi/velox/VeloxListenerApi.scala` | Add `case n if n.contains("Windows") => "windows"` in `platformLibDir` | Windows case missing; was defaulting to "linux/amd64" path that doesn't exist in our JAR |
| `ColumnarBuildSideRelation.scala`, `UnsafeColumnarBuildSideRelation.scala`, `ExecUtil.scala` | `info.memoryAddress + offset` → `info.data` + `Platform.BYTE_ARRAY_OFFSET + offset` (3 sites) | `NativeColumnarToRowInfo` API changed: `memoryAddress: Long` removed, `data: byte[]` added. Match pattern already used by gangpeng in `VeloxColumnarToRowExec.scala` |

### Category E — Packaging (poms)

| File | Change | Why |
|---|---|---|
| `backends-velox/pom.xml` | Add explicit `hadoop-client`, `spark-hive`, `caffeine`, `jimfs` deps | The `systemPath` dep on the not-yet-built `gluten-velox-bundle` JAR (chicken-and-egg) was the only source of these classes |
| `package/pom.xml` | Add `gluten-substrait`, `gluten-arrow`, `gluten-core`, `gluten-ui` to the `backends-velox` profile | Without these, the shaded fat JAR was missing `ColumnarShuffleManager` and other classes |

### Category F — vcpkg ports

| File | Change | Why |
|---|---|---|
| `dev/vcpkg/ports/folly/portfile.cmake` | Make `FOLLY_HAVE_INT128_T` platform-conditional | Linux-only flag broke MSVC build |
| `dev/vcpkg/ports/folly/windows-nominmax.patch` (new) | Add `NOMINMAX` to `FollyCompilerMSVC.cmake` | Avoid min/max macro pollution |
| `dev/vcpkg/vcpkg.json` | `libdwarf` `platform="!windows"` | Autotools-based ELF/DWARF deps don't build on MSVC |

### Category G — Build scripts (new files)

| File | Purpose |
|---|---|
| `build-gluten-windows.ps1` | Configure + build gluten cpp with vcpkg env, vcvars64, ARROW_HOME=C:\ae |

### Category H — JAR / DLL injection

| File | Change | Why |
|---|---|---|
| `update_jars.ps1` | Replace gangpeng's hardcoded paths with `C:\src\gluten\...`; add DLLs at `windows/amd64/` even if absent in original JAR | gangpeng's path was personal; jar `uf` only updates existing entries by default |

### Category I — External runtime data (not in repo)

These live OUTSIDE the repo and must be set up manually by users — see [SETUP.md](SETUP.md) (**TODO**).

| Path | Purpose |
|---|---|
| `C:\tools\velox-tzdata\tzdata.zi` | Minimal UTC-only IANA timezone data; full IANA tzdata.zi crashes velox |
| `C:\ae\` | Arrow C++ install prefix (built by `build-velox-windows.ps1`) |
| `C:\tmp\winflexbison\` | Win-flex/bison for velox SQL parser generation |

---

## Future work (prioritized)

### P0 — Bugs that must be fixed for production

1. **Tzdb parser crash on full IANA tzdata** — debug `time_zone::__create` to find which Zone record triggers bad `unique_ptr`. Without this, non-UTC users can't use the build.
2. **NULL key memory blowup** — JVM-crash symptom mitigated (SEH guard in `cpp/core/jni/JniWrapper.cc::collectUsage`). Underlying issue is that NULL keys produce a 459 GiB bogus reservation in shuffle-read after the join — likely a `size_t` underflow in velox HashJoin or in columnar batch serialize. Track to the actual underflow site, or short-circuit via `VELOX_NYI` in `SubstraitToVeloxPlan` when `joinHasNullKeys`.
3. **BHJ proper-fix** — current workaround is per-task rebuild via `buildHashTableOncePerExecutor=false`; the real fix is to backport upstream HashJoinNode 12-arg signature into gangpeng's velox snapshot, then restore the `joinHasNullKeys` + `opaqueSharedHashTable` arguments so the prebuilt table is actually reusable.

### P1 — Promote workarounds into proper patches

1. **Move Arrow `ThirdpartyToolchain.cmake` edit into `thrift-static-crt.patch`** — current state lives in `C:\ae\` build dir which gets wiped on clean rebuild.
2. **Move folly-targets.cmake post-install fix into folly portfile** — currently a sed strip that vcpkg overwrites.
3. **Restore `backends-velox/src/test/`** with proper test deps (scalatest, gluten-core test-jar resolution).
4. **Generate `arrow_dataset_jni.dll`** — needed for any Java code that uses Arrow Dataset APIs.

### P2 — Polish

1. **Write SETUP.md** with step-by-step build instructions for a fresh Windows machine.
2. **CI on Windows** — GitHub Actions workflow that runs the build + smoke test on `windows-latest`.
3. **Send `windows` profile patch to apache/gluten parent pom** — currently bundle JAR classifier shows `unknown` instead of `windows_amd64`.
4. **Document `kAllowInt32NarrowingSession` literal-string workaround** so future devs know to revisit.

---

## Setup for a smoke test (quick reference)

Prereqs:
- Visual Studio 2022 (MSVC v143)
- CMake 3.28+, Ninja
- JDK 11 (`C:\Program Files\Java\jdk-11\`)
- Apache Maven 3.9+
- Python 3.12 + `pip install pyspark==3.5.3`
- Git Bash (for build scripts)

Build:
```powershell
# 1. Velox engine (~2h first time)
cd C:\src\gluten\ep\build-velox
.\build-velox-windows.ps1 -BuildType Release

# 2. Gluten cpp (velox.dll + gluten.dll, ~10min)
.\build-gluten-windows.ps1

# 3. Java jars (~5min)
$env:JAVA_HOME = "C:\Program Files\Java\jdk-11"
mvn clean package -P backends-velox,spark-3.5 -DskipTests `
  -Dscalastyle.skip=true -Dcheckstyle.skip=true -Dspotless.check.skip=true `
  -Dbash.executable="C:\Program Files\Git\bin\bash.exe"

# 4. Rename bundle classifier from "unknown" to "windows_amd64"
cd package\target
cp "gluten-velox-bundle-spark3.5_2.12-unknown-1.7.0-SNAPSHOT.jar" `
   "gluten-velox-bundle-spark3.5_2.12-windows_amd64-1.7.0-SNAPSHOT.jar"

# 5. Inject DLLs
.\update_jars.ps1
```

Setup tzdata (minimal):
```powershell
mkdir C:\tools\velox-tzdata
@"
# version 2026b
Zone	Etc/UTC	0	-	UTC
Link	Etc/UTC	UTC
Link	Etc/UTC	GMT
Link	Etc/UTC	Etc/GMT
Link	Etc/UTC	Etc/Universal
Link	Etc/UTC	Etc/Zulu
"@ | Out-File C:\tools\velox-tzdata\tzdata.zi -Encoding utf8
```

Run smoke test:
```python
from pyspark.sql import SparkSession
spark = SparkSession.builder \
    .appName("smoke") \
    .master("local[2]") \
    .config("spark.plugins", "org.apache.gluten.GlutenPlugin") \
    .config("spark.memory.offHeap.enabled", "true") \
    .config("spark.memory.offHeap.size", "1g") \
    .config("spark.shuffle.manager", "org.apache.spark.shuffle.sort.ColumnarShuffleManager") \
    .config("spark.gluten.sql.columnar.backend.lib", "velox") \
    .config("spark.sql.adaptive.enabled", "false") \
    .config("spark.sql.session.timeZone", "UTC") \
    .config("spark.sql.autoBroadcastJoinThreshold", "-1") \
    .config("spark.driver.extraJavaOptions", "-Dio.netty.tryReflectionSetAccessible=true") \
    .config("spark.executor.extraJavaOptions", "-Dio.netty.tryReflectionSetAccessible=true") \
    .getOrCreate()

spark.sql("SELECT mod5, SUM(doubled) FROM (SELECT id, id*2 AS doubled, id%5 AS mod5 FROM range(100)) GROUP BY mod5 ORDER BY mod5").show()
```

---

## Debug methodology that worked

When `velox.dll` crashed with access violation in `nativeValidateWithFailureReason`, the path that finally got real diagnostic info:

1. **Rebuild velox.dll with `CMAKE_BUILD_TYPE=RelWithDebInfo`** → produces `velox.pdb` (~700 MB symbol file).
2. **Install LLVM** for `llvm-symbolizer.exe` (`winget install LLVM.LLVM`).
3. **From `hs_err_pid*.log` extract offset** (`velox.dll+0xb4ea3be`).
4. **Resolve symbol**:
   ```bash
   llvm-symbolizer.exe --obj=velox.dll --relative-address 0xb4ea3be
   # → facebook::velox::tzdb::time_zone::__create(...)
   ```

This single technique cracked open multiple "mysterious native crashes" without needing WinDbg or a full minidump workflow.

---

## Attribution

This port stands on:
- **Apache Gluten** (Apache License 2.0) — base project
- **Meta Velox** (Apache License 2.0) — execution engine
- **[gangpeng](https://github.com/gangpeng)** — initial MSVC compile-passing port (`[WINDOWS]` commits on both repos)
- **wudanzy** — mentor at Microsoft, scoped the project

Modifications in this branch are released under Apache License 2.0 (matching upstream).
