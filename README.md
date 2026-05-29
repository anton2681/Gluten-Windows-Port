# Gluten on Windows — MSVC Port (In Progress)

This is a **fork of [Apache Gluten](https://github.com/apache/incubator-gluten)** that brings the Gluten + [Velox](https://github.com/facebookincubator/velox) Spark execution stack to **Windows / MSVC**. It is not yet at parity with the Linux build — see [Current state](#current-state) and [Open issues](#open-issues-handover-notes) below.

Companion Velox fork: **[anton2681/Velox-Windows-Port](https://github.com/anton2681/Velox-Windows-Port)** (Gluten depends on a specific Velox snapshot; that repo carries gangpeng's MSVC port commit unchanged).

Upstream sources this fork is based on:
- Apache Gluten `main` (Apache 2.0)
- [gangpeng/gluten](https://github.com/gangpeng/gluten) MSVC port snapshot (Apache 2.0) — adds the initial Windows build wiring
- [gangpeng/velox](https://github.com/gangpeng/velox) `windows/msvc-port` branch (Apache 2.0) — adds MSVC-compatible Velox

For the **original Apache Gluten README** (what the project is, supported backends, general docs), see [`README.upstream.md`](README.upstream.md) or the [upstream repo](https://github.com/apache/incubator-gluten).

---

## Current state

End-to-end Spark 3.5.3 + Velox offload works on Windows for basic workloads via `spark-submit`. Detailed status with reproduction commands and exact error messages lives in [`PORT_STATUS.md`](PORT_STATUS.md).

| | |
|---|---|
| `SELECT` / `GROUP BY` / `SUM` / ordering / aggregations | OK — offloaded to Velox |
| Inner join (SHJ) | OK — default config |
| Left / Right outer join, non-NULL keys | OK — default config |
| Broadcast hash join, non-NULL keys | OK — requires `spark.gluten.velox.buildHashTableOncePerExecutor.enabled=false` |
| Joins with NULL keys in the key column | FAIL — workaround: `WHERE key IS NOT NULL` before the join |
| Full IANA `tzdata.zi` (non-UTC sessions) | FAIL — workaround: minimal UTC-only `tzdata.zi` shipped at `tools/windows/tzdata.minimal.zi` |
| Arrow dataset JNI (`arrow_dataset_jni.dll`) | Skipped — only `arrow_cdata_jni.dll` is built |
| `backends-velox` Scala unit tests | `src/test` renamed to `src/test.bak` to unblock packaging |

See the full per-feature table in `PORT_STATUS.md` for root causes and proper-fix suggestions.

---

## Build & smoke test

Step-by-step build instructions: [`tools/windows/SETUP.md`](tools/windows/SETUP.md).

TL;DR pipeline (each step assumes the previous succeeded):

1. Install Visual Studio 2022 + JDK 11 + Maven + Python 3 + Git Bash + (optional) LLVM
2. `dev/vcpkg/.vcpkg/vcpkg install --triplet x64-windows-static --x-manifest-root=.` (~2–3 hours first time)
3. `ep/build-velox/build-velox-windows.ps1 -BuildType Release` (~2 hours)
4. `build-gluten-windows.ps1` (~10 min, produces `gluten.dll` + `velox.dll`)
5. Build `arrow_cdata_jni.dll` via `tools/windows/build_arrow_cdata.bat`
6. `mvn package -P backends-velox,spark-3.5 -DskipTests …` (~5 min)
7. Inject DLLs into the bundle JAR: `update_jars.ps1` + `tools/windows/inject_arrow_cdata.ps1`
8. Run a smoke test: `tests/windows/run_test_gluten.bat`

Repo layout expected:
```
C:\src\
├── gluten\   (this repo, anton2681/Gluten-Windows-Port)
└── velox\    (anton2681/Velox-Windows-Port)
```
plus a junction `gluten\ep\build-velox\build\velox_ep` → `C:\src\velox`.

Smoke tests under [`tests/windows/`](tests/windows/):

| Test | What it exercises |
|---|---|
| `run_test_gluten.bat` | SELECT / GROUP BY / SUM / ORDER BY — offloaded to Velox |
| `run_test_off.bat` | Plugin loads but offload disabled — sanity for vanilla Spark via our JARs |
| `run_test_join.bat` | Inner / LEFT (with NULL keys, currently fails on T2) / BHJ |
| `run_test_join_narrow.bat` | Joins with all-NOT-NULL keys — passes today |
| `run_test_bhj_narrow.bat` | Broadcast hash join with non-NULL keys (needs the `buildHashTableOncePerExecutor=false` config) |
| `run_test_join_sortshuffle.bat` | NULL-key LEFT JOIN routed through sort-based shuffle (still fails, different symptom) |
| `run_test_join_nospill.bat` | NULL-key LEFT JOIN with velox spill disabled (still fails) |

---

## What was changed vs upstream

Two layers of changes:

1. **Bring-up changes from gangpeng's MSVC port** that already landed before this fork was created (commits `2fcfd4acf`, `78acdd906`). These touch vcpkg manifests, build scripts, dependency portfiles (folly `__int128`, libelf/libdwarf skips, folly `/std:c++17` interface leak, monolithic `velox.lib` 4 GB cap, etc.). Detailed inventory in `PORT_STATUS.md` under "Velox MSVC port changes".

2. **Changes made during the spark-submit bring-up and bug-fix work** (commits `40b657996` → `bb2a06df3`):

| Commit | Subject | What it does |
|---|---|---|
| `40b657996` | Complete spark-submit end-to-end on Windows | Adds Windows platform case in `VeloxListenerApi.platformLibDir`, fixes 3 `NativeColumnarToRowInfo` call sites to use `info.data + Platform.BYTE_ARRAY_OFFSET` instead of the missing `memoryAddress` field, wires `hadoop-client` / `spark-hive` / `caffeine` / `jimfs` into `backends-velox/pom.xml`, adds explicit `substrait/arrow/core/ui` deps to `package/pom.xml`, etc. |
| `5b1d7d5b1` | Windows-port tools, smoke tests, setup guide, early report | Adds `tools/windows/` (build helpers, arrow_cdata_jni standalone CMake, JAR-injection PowerShell scripts, minimal tzdata.zi, JVM crash-dump wrapper) and `tests/windows/` smoke tests, plus `PORT_STATUS.md` + `tools/windows/SETUP.md`. |
| `85150d718` | Fix JVM crash on join-stats poll; document BHJ config workaround | **Bug #3a**: SEH (`__try`/`__except`) guard around `MemoryUsageStats::ByteSizeLong` / `SerializeToArray` in `cpp/core/jni/JniWrapper.cc::collectUsage`. NULL-key joins were leaving the MemoryUsageStats tree in a state that made protobuf dereference `0xff…ff` from the periodic stats poll, taking the JVM down. SEH guard makes stats degrade to empty blob instead of crashing the process. **Bug #2**: documents that `spark.gluten.velox.buildHashTableOncePerExecutor.enabled=false` unblocks BHJ on this port (default `true` ships only the prebuilt hash table, which the 10-arg HashJoinNode signature in gangpeng's velox cannot reuse). |
| `94539b6c2` | Fix uint64 underflow + div-by-zero in shuffle binary buffer sizing | **Bug #3b first layer**: `VeloxHashShuffleWriter.cc::valueBufferSizeForBinaryArray` computed `(totalBytes + numRows - 1) / numRows * newSize + 1024` — underflows + divide-by-zero when `totalInputNumRows_==0`. On Linux that's harmless UB; on MSVC it was emitting garbage that ended up serialized into the shuffle stream as a negative buffer header (`-92`), surfacing later as `Negative buffer resize: -92` from Arrow's `PoolBuffer::Resize`. Also adds defensive sanity checks (16 GiB upper bound, negative-length rejection) on the read side in `cpp/core/shuffle/Payload.cc`. |
| `bb2a06df3` | Bug #3b deep dive: shuffle stream truncation, diagnostic hardening | **Bug #3b second layer**: replaces two MSVC-fragile `(isNull - 1) & stringView.size()` branchless null masks in `VeloxHashShuffleWriter.cc` with explicit `if`/`else`. Hardens `BlockPayload::serialize` with `numBuffers_ == buffers_.size()` assertion + per-buffer-index diagnostic. Hardens `BlockPayload::deserialize` with init-before-Read, short-read detection, upper-bound check, per-buffer diagnostic. Result: the NULL-key LEFT JOIN failure now surfaces as the clean message `Failed reading buffer 5/7 (type=uncompressed, numRows=1): Short read got 0 bytes` instead of bogus 200-700 GiB OOM. Underlying truncation not yet root-caused. |

Files outside the upstream code base added in this fork:

```
PORT_STATUS.md                       # full status table, debug methodology, follow-ups
tools/windows/SETUP.md               # step-by-step build guide
tools/windows/build_arrow_cdata.bat
tools/windows/build_velox_dll.bat
tools/windows/inject_arrow_cdata.ps1
tools/windows/arrow_cdata_jni/CMakeLists.txt
tools/windows/jvm_crash_dump.bat
tools/windows/tzdata.minimal.zi
tests/windows/run_test_*.bat         # smoke tests
tests/windows/test_*.py
update_jars.ps1                      # injects gluten.dll + velox.dll into the bundle JAR
build-gluten-windows.ps1             # gluten DLL build orchestrator
ep/build-velox/build-velox-windows.ps1  # velox build orchestrator
```

---

## Open issues (handover notes)

These are the items left when this fork was last touched. Each one is also annotated in the relevant source file with a `Bug #3b in PORT_STATUS.md`-style pointer.

### Bug #3b — NULL-key LEFT JOIN produces a truncated shuffle stream

**Reproducer**: `tests/windows/run_test_join.bat` — T1 inner join passes, T2 LEFT JOIN with NULL keys fails with:

```
Failed reading buffer 5/7 (type=uncompressed, numRows=1):
  IOError: Short read while reading uncompressed buffer length:
  got 0 bytes, expected 8. Stream likely truncated upstream.
```

**What we know**:
- Failure is NULL-key-specific (`run_test_join_narrow.bat` with no NULL keys passes cleanly).
- Header says `numBuffers=7`, stream physically contains only 5 buffers worth of data.
- Write-time assertion `numBuffers_ == buffers_.size()` doesn't fire, so the BlockPayload's bookkeeping is internally consistent at serialize time. The truncation must happen either inside `outputStream->Write(buffer)` (silent partial write) or in a NULL-key-specific code path that mutates the buffer count between header write and buffer iteration.
- Switching to sort-based shuffle (`run_test_join_sortshuffle.bat`) hits a different symptom (`LZ4 ERROR_frameType_unknown`) — same root cause, different decode path.
- Disabling velox spill (`run_test_join_nospill.bat`) does not avoid it.

**Suggested next step**:
Instrument `BlockPayload::serialize` in `cpp/core/shuffle/Payload.cc` with a byte counter on the `outputStream`, log expected vs actual after each `Write` call. Compare to deserialize-side byte counter. That should pin down which `Write` call is silently short.

Alternative tactical fix: in `cpp/velox/substrait/SubstraitToVeloxPlan.cc`, detect SHJ paths with potentially-nullable join key columns and throw `VELOX_NYI` so gluten's plan-validation layer falls back to vanilla Spark for that operator. Avoids the bug entirely but degrades performance for any join touching nullable keys.

### Bug #1 — Velox tzdb parser crashes on full IANA `tzdata.zi`

**Reproducer**: replace `C:\tools\velox-tzdata\tzdata.zi` with the full IANA tzdata file, run any query with a non-UTC `spark.sql.session.timeZone`.

**What we know**: crash address resolves (via `llvm-symbolizer` against `velox.pdb`) to `facebook::velox::tzdb::time_zone::__create`. Specific Zone record triggering the bad `unique_ptr` not yet identified.

**Suggested next step**: bisect the tzdata file (binary chop) to find the minimal failing Zone record, then debug `time_zone::__create` against that specific record.

### Bug #2 — BHJ proper fix

**Current state**: works with `spark.gluten.velox.buildHashTableOncePerExecutor.enabled=false` (the prebuilt-table-reuse path is bypassed). The proper fix is to backport the upstream 12-arg `HashJoinNode` constructor (with the trailing prebuilt-table args) into gangpeng's velox snapshot, then restore the dropped args in `SubstraitToVeloxPlan.cc:439`.

### Other items in `PORT_STATUS.md`

- Promote ad-hoc PowerShell scripts into proper CMake / Maven targets so the build doesn't depend on `update_jars.ps1` and friends.
- Re-run upstream gluten unit tests on Windows once `arrow-dataset` JNI is available and `backends-velox/src/test` can be re-enabled.
- Drop the renamed `src/test.bak` directories once test resolution is fixed in the poms.
- Replace the unsupported `kAllowInt32NarrowingSession` literal config with the upstream-named constant after velox is merged forward.

---

## Reference materials

- [`PORT_STATUS.md`](PORT_STATUS.md) — exhaustive table of what works / what doesn't / why / how to fix
- [`tools/windows/SETUP.md`](tools/windows/SETUP.md) — operational build & smoke-test guide
- `tests/windows/test_*.py` — minimal pyspark reproducers for each major code path
- `hs_err_pid*.log` files from crashing runs (when present) — resolve crash addresses with `llvm-symbolizer --obj=cpp/build/velox/velox.dll --relative-address <hex>`

## License

Apache License 2.0 — same as Apache Gluten and Apache Arrow. See [`LICENSE`](LICENSE).
