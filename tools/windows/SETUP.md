# Windows Port Setup Guide

Step-by-step instructions to build & smoke-test Gluten + Velox on Windows from a clean machine.

> See [PORT_STATUS.md](../../PORT_STATUS.md) for what works, what doesn't, and the architecture overview.

---

## Prerequisites

Install (one-time):

| Tool | Version | Source |
|---|---|---|
| Visual Studio 2022 | Community/Enterprise, with "Desktop development with C++" workload (MSVC v143) | [visualstudio.microsoft.com](https://visualstudio.microsoft.com/) |
| CMake | 3.28+ | bundled with VS or `winget install Kitware.CMake` |
| Ninja | latest | `winget install Ninja-build.Ninja` |
| JDK 11 | Adoptium/OpenLogic | `winget install OpenLogic.OpenJDK.11` (default at `C:\Program Files\Java\jdk-11`) |
| Apache Maven | 3.9+ | `winget install Apache.Maven` |
| Python | 3.10+ | `winget install Python.Python.3.12` |
| PySpark | 3.5.3 | `pip install pyspark==3.5.3` |
| Git for Windows | with Git Bash | `winget install Git.Git` |
| LLVM | optional, for debug-symbol resolution | `winget install LLVM.LLVM` |

Set `JAVA_HOME=C:\Program Files\Java\jdk-11` (or wherever JDK 11 lives).

---

## Repo layout (suggested)

```
C:\src\
├── gluten\         (this repo, anton2681/Gluten-Windows)
└── velox\          (anton2681/Velox-Windows)
```

Velox is also expected at `gluten\ep\build-velox\build\velox_ep` — create a junction:
```cmd
mklink /J C:\src\gluten\ep\build-velox\build\velox_ep C:\src\velox
```

---

## Build order

### 1. vcpkg + dependencies (~2-3 hours first time)

The vcpkg manifest pulls 35+ deps. Some patches need LF line endings, hence `.gitattributes` with `*.patch -text`.

```cmd
cd C:\src\gluten\dev\vcpkg
.\.vcpkg\bootstrap-vcpkg.bat -disableMetrics
.\.vcpkg\vcpkg.exe install --triplet x64-windows-static --x-manifest-root=.
```

Expect ~7 GB at `vcpkg_installed/x64-windows-static/`.

### 2. win_flex_bison (~30 sec)

```cmd
mkdir C:\tmp\winflexbison
cd C:\tmp\winflexbison
curl -L -o wfb.zip https://github.com/lexxmark/winflexbison/releases/download/v2.5.25/win_flex_bison-2.5.25.zip
tar -xf wfb.zip
```

### 3. Velox engine (~2 hours first time, ~20 min incremental)

```cmd
cd C:\src\gluten\ep\build-velox
.\build-velox-windows.ps1 -BuildType Release
```

Produces ~116 `.lib` files under `_build\release\velox\` + Arrow C++ build at `C:\ae\`.

### 4. gluten.dll + velox.dll (~10 min)

```cmd
cd C:\src\gluten
.\build-gluten-windows.ps1
```

Produces `cpp\build\core\gluten.dll` (12 MB) and `cpp\build\velox\velox.dll` (80 MB).

For incremental velox.dll only rebuilds, use [`tools/windows/build_velox_dll.bat`](build_velox_dll.bat).

### 5. Arrow Java JARs (Windows-specific shortcut)

The upstream `build-arrow.sh` runs profiles that only work on Linux/Mac. On Windows we install pre-built Arrow 15.0.0 JARs from Maven Central into `~/.m2/repository` under the `15.0.0-gluten` version that gluten requires.

```bash
# git-bash
cd ~
mkdir -p arrow-jars && cd arrow-jars
for a in arrow-memory-unsafe arrow-memory-core arrow-vector arrow-c-data arrow-dataset arrow-format arrow-memory; do
  curl -sSLo $a-15.0.0.jar https://repo.maven.apache.org/maven2/org/apache/arrow/$a/15.0.0/$a-15.0.0.jar
  curl -sSLo $a-15.0.0.pom https://repo.maven.apache.org/maven2/org/apache/arrow/$a/15.0.0/$a-15.0.0.pom
done
# arrow-memory is pom-only
rm -f arrow-memory-15.0.0.jar

for a in arrow-memory-unsafe arrow-memory-core arrow-vector arrow-c-data arrow-dataset arrow-format; do
  mvn install:install-file -Dfile=$a-15.0.0.jar -DgroupId=org.apache.arrow -DartifactId=$a \
    -Dversion=15.0.0-gluten -Dpackaging=jar -DpomFile=$a-15.0.0.pom
done
mvn install:install-file -Dfile=arrow-memory-15.0.0.pom -DgroupId=org.apache.arrow \
  -DartifactId=arrow-memory -Dversion=15.0.0-gluten -Dpackaging=pom
```

> **Note**: This bypasses the gluten patches against Arrow Java (`modify_arrow.patch`, `modify_arrow_dataset_scan_option.patch`). Those patches add `FragmentScanOptions` and friends. Without them, queries using `arrow.dataset.scanner.csv` features will fail. For our smoke tests this is fine. To do it properly: extract `apache-arrow-15.0.0.tar.gz`, apply the 4 patches under `ep/build-velox/src/*.patch`, then `cd java && mvn versions:set -DnewVersion=15.0.0-gluten && mvn install -Parrow-c-data,arrow-jni -pl c,dataset -am -DskipTests`.

### 6. Build arrow_cdata_jni.dll (Windows-specific)

```cmd
set GLUTEN_REPO=C:\src\gluten
%GLUTEN_REPO%\tools\windows\build_arrow_cdata.bat
```

Produces `C:\tmp\arrow_cdata_build\arrow_cdata_jni.dll` (~222 KB).

### 7. mvn package (~5 min)

```cmd
cd C:\src\gluten
mvn clean package -P backends-velox,spark-3.5 -DskipTests ^
  -Dscalastyle.skip=true -Dcheckstyle.skip=true -Dspotless.check.skip=true ^
  -Dbash.executable="C:\Program Files\Git\bin\bash.exe"
```

Produces JARs under `package\target\`. **Note**: classifier shows `unknown` instead of `windows_amd64` — rename:

```cmd
cd package\target
copy gluten-velox-bundle-spark3.5_2.12-unknown-1.7.0-SNAPSHOT.jar ^
     gluten-velox-bundle-spark3.5_2.12-windows_amd64-1.7.0-SNAPSHOT.jar
```

### 8. Inject DLLs into the bundle JAR

```powershell
cd C:\src\gluten
.\update_jars.ps1
.\tools\windows\inject_arrow_cdata.ps1
```

### 9. Setup minimal tzdata.zi (one-time)

Velox crashes on the full IANA tzdata. Use the minimal UTC-only file shipped in this repo:

```cmd
mkdir C:\tools\velox-tzdata
copy C:\src\gluten\tools\windows\tzdata.minimal.zi C:\tools\velox-tzdata\tzdata.zi
```

### 10. Smoke test

```cmd
C:\src\gluten\tests\windows\run_test_gluten.bat
```

Expected output:
```
=== Spark 3.5.3 session created with Gluten plugin ===
== Physical Plan ==
VeloxColumnarToRow
+- ^(3) SortExecTransformer ...
...
mod5=0, total=1900
mod5=1, total=1940
mod5=2, total=1980
mod5=3, total=2020
mod5=4, total=2060
=== Done ===
```

If plan operators carry the `*Transformer` suffix, Gluten + Velox offload is working.

---

## Other tests

| Test | Purpose |
|---|---|
| `tests/windows/run_test_gluten.bat` | Aggregations: SELECT/GROUP BY/SUM/ORDER BY |
| `tests/windows/run_test_off.bat` | Sanity: plugin loads but offload disabled (vanilla Spark via our JARs) |
| `tests/windows/run_test_join.bat` | Join validation: inner / left+null / BHJ |
| `tests/windows/run_test_join_narrow.bat` | Joins with all-NOT-NULL keys (currently the only join shape that works without BHJ) |
| `tests/windows/run_test_bhj_narrow.bat` | Broadcast hash join with non-NULL keys (requires `spark.gluten.velox.buildHashTableOncePerExecutor.enabled=false`) |

---

## Known issues you'll hit

| Symptom | Workaround |
|---|---|
| `'C:\Program' is not recognized as an internal or external command` from spark-submit | Use the 8.3 short path: `set JAVA_HOME=C:\PROGRA~1\Java\jdk-11` |
| `java.lang.UnsupportedOperationException: sun.misc.Unsafe or java.nio.DirectByteBuffer.<init>` | Add `-Dio.netty.tryReflectionSetAccessible=true` to driver+executor JVM opts (already in our run scripts) |
| `corrupt tzdb: expected character 'v' from string 'version'` | Re-check `C:\tools\velox-tzdata\tzdata.zi` has the `# version <year>X` first line (see `tzdata.minimal.zi`) |
| `VeloxUserError: session 'session_timezone' set with invalid value 'Asia/Shanghai'` | Set `spark.sql.session.timeZone=UTC` (already in our test scripts) |
| `error exporting columnar batch` / `FileNotFoundException: x86_64/arrow_cdata_jni.dll` | Did you run `inject_arrow_cdata.ps1` after building arrow_cdata_jni.dll? |
| `linux/amd64/gluten.dll not found` | Bundle JAR doesn't have the DLLs injected. Re-run `update_jars.ps1` |
| `EXCEPTION_ACCESS_VIOLATION` JVM crash in `velox.dll+0xXXXX` | See "Debug methodology" in [PORT_STATUS.md](../../PORT_STATUS.md) — use `llvm-symbolizer` against `velox.pdb` |
| `BroadcastHashJoinExecTransformer` returns empty | Set `spark.gluten.velox.buildHashTableOncePerExecutor.enabled=false` — gluten then rebuilds the table per task instead of relying on the prebuilt-table-reuse path that gangpeng's velox doesn't expose |
| Native crash in `gluten.dll!protobuf::SerializeToArray` during stats poll | Should not occur after the SEH-guard fix landed in `cpp/core/jni/JniWrapper.cc::collectUsage`; if it does, rebuild gluten.dll and re-inject via `update_jars.ps1` |

---

## Debug methodology cheat sheet

When you hit a native crash:

1. **Rebuild velox.dll with debug info:**
   ```cmd
   cd C:\src\gluten\cpp\build
   cmake -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo .
   cmake --build . --target velox
   ```
   This produces `velox.pdb` alongside `velox.dll`.

2. **From the `hs_err_pid*.log` extract the crash address:**
   ```
   # C  [velox.dll+0xb4ea3be]
   ```

3. **Resolve to function name:**
   ```cmd
   "C:\Program Files\LLVM\bin\llvm-symbolizer.exe" ^
     --obj=C:\src\gluten\cpp\build\velox\velox.dll ^
     --relative-address 0xb4ea3be
   ```

   Output:
   ```
   facebook::velox::tzdb::time_zone::__create(...)
   ```

This was how we cracked the "protobuf descriptor red herring" — the real cause was velox's tzdb parser.
