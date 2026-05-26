---

## Overall Status

| Stage | Status | Artifact |
|---|---|---|
| 0. Toolchain (MSVC 2022 / CMake 3.31 / Ninja 1.12) | ✅ Done | VS Enterprise 17.14 (pre-existing) |
| 1. In-tree vcpkg (`gluten/dev/vcpkg/.vcpkg/`, branch 2025.09.17) | ✅ Done | vcpkg 2025-09-03 |
| 2. vcpkg install (35+ dependencies) | ✅ Done | 7.0 GB at `vcpkg_installed/x64-windows-static/` |
| 3. win_flex_bison | ✅ Done | `C:\tmp\winflexbison\{bison,flex}.exe` |
| 4. Velox source (junction → `C:\src\velox`) | ✅ Done | gangpeng/velox `windows/msvc-port` @ d62c6b425 |
| 5. Velox compilation (116 per-module sublibs) | ✅ Done | 8.7 GB under `_build/release/velox/**/*.lib` |
| 6. Arrow ExternalProject (rebuilt with PARQUET+FILESYSTEM) | ✅ Done | `C:\ae\install\lib\{arrow_static,parquet_static,arrow_bundled_dependencies}.lib` |
| 7. `core/gluten.dll` (gluten core JNI library) | ✅ Done | 7.9 MB |
| 8. `velox/velox.dll` (gluten-to-velox bridge) | ❌ Blocked | See "Unresolved" |
| 9. mvn package + DLL injection into JAR | ⏳ Not started | |
| 10. spark-submit end-to-end | ⏳ Not started | |

---

## 16 Findings (in order of discovery)

### Environment / Toolchain (not gangpeng's bugs — Windows defaults that bite)

#### 1. Git autocrlf rewrites `.patch` files to CRLF, breaking vcpkg's patch apply
- **Symptom:** While installing folly via vcpkg, `z_vcpkg_apply_patches` reports `corrupt patch at line 8`. The first four folly patches slip through; `adding-api.patch` fails because its hunk header is byte-strict.
- **Root cause:** Git for Windows defaults to `core.autocrlf=true`. All `.patch` / `.diff` files are silently LF→CRLF rewritten on checkout.
- **Fix applied:**
  - `git config core.autocrlf false` in both gluten and velox repos
  - Added `*.patch -text` and `*.diff -text` to `.gitattributes` in both repos
  - One-shot `sed -i 's/\r$//'` on 32 corrupted gluten overlay patches + 20 velox patches
- **Recommendation for mentor:** Add explicit `git config core.autocrlf false` instruction to `dev/vcpkg/init.sh` and the Windows onboarding doc. Every new engineer will otherwise hit this.

#### 2. `git clone --depth 1` shallow-clones vcpkg, breaking builtin-baseline resolution
- **Symptom:** With `--depth 1`, vcpkg install fails immediately with `failed to unpack tree object ... vcpkg was cloned as a shallow repository` on every port.
- **Root cause:** vcpkg's manifest mode uses `git read-tree <commit>` to fetch exact port versions; shallow clones lack the historical commits.
- **Fix:** `git fetch --unshallow` (or reclone without `--depth`).
- **Recommendation:** Add a comment to the existing `git clone https://github.com/microsoft/vcpkg.git --branch 2025.09.17 "$VCPKG_ROOT"` in `init.sh`: "do not add `--depth 1`."

---

### Upstream Linux defaults leaking into Windows (gangpeng didn't intercept)

#### 3. folly portfile.cmake forces `FOLLY_HAVE_INT128_T=ON`, MSVC can't compile
- **Symptom:** vcpkg's folly build dies in `Conv.h / Traits.h / Hash.h`: `error C4235: '__int128' keyword not supported on this architecture`, with 30+ cascading syntax errors.
- **Root cause:** `dev/vcpkg/ports/folly/portfile.cmake:60` hard-codes `-DFOLLY_HAVE_INT128_T=ON` (comment: `# Required by Velox`). `git log` confirms **gangpeng never touched this file** — it's the Linux-only upstream default inherited unchanged.
- **Why gangpeng's UTs pass:** Almost certainly vcpkg binary-cache hits. He has never reproduced this on a clean machine.
- **Fix applied:** Made the portfile platform-conditional:
  ```cmake
  if(VCPKG_TARGET_IS_WINDOWS)
      set(FOLLY_INT128_T_OPT "-DFOLLY_HAVE_INT128_T=OFF")
  else()
      set(FOLLY_INT128_T_OPT "-DFOLLY_HAVE_INT128_T=ON")
  endif()
  ```
- **Open risk:** If velox link requires `folly::to<__int128>(...)`, symbols will be unresolved. Not triggered yet.

#### 4. folly missing NOMINMAX → glog `ERROR` macro clash + windows.h `max/min` macro pollution
- **Symptom:** folly install dies in `CheckedMath.h / ConstexprMath.h / CancellationToken-inl.h` with hundreds of `warning C4003: not enough arguments for function-like macro invocation 'max'` and `C2589: '(': illegal token on right side of '::'`.
- **Root cause:** folly's `FollyCompilerMSVC.cmake:300` adds only `WIN32_LEAN_AND_MEAN` (gated by `MSVC_ENABLE_LEAN_AND_MEAN_WINDOWS`) but **omits `NOMINMAX`**. `windows.h` defines `max`/`min` as macros, and `std::numeric_limits<T>::max()` gets swallowed by the macro expansion.
- **Fix applied:** New `dev/vcpkg/ports/folly/windows-nominmax.patch` injects `NOMINMAX` into folly's `target_compile_definitions`, registered in the portfile's `PATCHES` list.
- **Recommendation:** This is a folly upstream omission. Worth submitting a folly PR.

#### 5. libelf / libdwarf should not be installed on Windows at all
- **Symptom:** vcpkg's libelf port uses GNU autotools against MSVC `cl.exe`. cl produces `.obj`, autotools' `ar` looks for `.o` → `ar: begin.o: No such file or directory`, accompanied by hundreds of `cl : Command line warning D9002 : ignoring unknown option '-Xcompiler'`.
- **Root cause:** ELF/DWARF are Linux binary + debug formats. Windows uses PE/COFF + PDB. `dev/vcpkg/vcpkg.json` lists `libdwarf` as an unconditional dependency, and libdwarf transitively pulls libelf.
- **Fix applied:** Changed vcpkg.json to `{"name": "libdwarf", "platform": "!windows"}` — libelf drops out via transitive pruning.

#### 6. folly bakes `/std:c++17` into `INTERFACE_COMPILE_OPTIONS`, forcing velox down from C++20
- **Symptom:** velox compiles ~875 .cpp files each emitting `cl : Command line warning D9025 : overriding '/std:c++20' with '/std:c++17'`, then `error C2039: 'span': is not a member of 'std'` / `'strong_ordering': is not a member of 'std'` / `error C2098: unexpected token after data member '<='` (spaceship operator `<=>`) — every C++20-only feature breaks.
- **Root cause:** Installed `vcpkg_installed/x64-windows-static/share/folly/folly-targets.cmake` lines 64, 81, 90 each hard-code `/std:c++17` into `INTERFACE_COMPILE_OPTIONS`. velox's `target_link_libraries(velox folly::folly)` propagates this flag to every velox target. Since MSVC takes the later `/std:` flag, `/std:c++17` wins.
- **Fix applied:** `sed`-stripped `/std:c++17;` from the installed folly-targets.cmake (3 occurrences).
- **Long-term fix:** Patch `dev/vcpkg/ports/folly/FollyCompilerMSVC.cmake` so it does **not** add `/std:c++17` to PUBLIC/INTERFACE compile options. Let consumers' `CMAKE_CXX_STANDARD` drive the standard. Also a candidate folly upstream PR.

---

### Gaps in gangpeng's own scripts / CMake

#### 7. `VELOX_MONO_LIBRARY=ON` hits the Windows 4 GB static-library cap
- **Symptom:** velox compiles 1684/1688 ninja tasks successfully, then `lib.exe` fails the final monolithic link: `fatal error LNK1248: image size (100FD2724) exceeds maximum allowable size (FFFFFFFF)` — 4.01 GB exceeding the 4 GB hard cap.
- **Root cause:** `build-velox-windows.ps1:130` hard-codes `-DVELOX_MONO_LIBRARY=ON`. Windows COFF archive member offsets are 32-bit → 4 GB hard cap; Linux `ar` has no such limit.
- **Why this broke now:** velox mainline has grown over the last several months (new operators / scalar functions / connectors); the monolithic archive **just crossed the 4 GB boundary**. This is a time-bomb that detonates as velox grows — not a bug in the original port logic.
- **Fix applied:** Changed ps1 to `MONO_LIBRARY=OFF`. velox now produces 116 per-module sublibs.
- **Cascading consequence:** See finding #8.

#### 8. gluten cpp/velox expects `velox_part0..3.lib` but no split script exists
- **Symptom:** After enabling `MONO_LIBRARY=OFF`, gluten configure fails: `Library does not exist: velox_part0.lib`.
- **Root cause:** `cpp/velox/CMakeLists.txt:293-300` hard-codes `foreach(_part 0 1 2 3) import_library(... velox_part${_part}.lib)` with a comment "On Windows, velox is split into multiple lib files" — **but no split script exists in either repo**. This is planned-but-not-implemented work on gangpeng's part.
- **Fix applied:** Replaced the foreach with `file(GLOB_RECURSE)` that discovers all 116 per-module sublibs and imports them into the `facebook::velox` INTERFACE target.
- **Recommendation:** A genuine design gap. Either implement the split (complex) or accept the glob-based approach (verified working).

#### 9. `PROTOBUF_WELLKNOWN_PROTO_DIR` is referenced but never set in gluten
- **Symptom:** gluten build step 1 invokes protoc and fails: `Missing value for flag: --proto_path`. The actual command emitted is `--proto_path X/ --proto_path --cpp_out Y` — the middle `--proto_path` has no value.
- **Root cause:** `cpp/core/CMakeLists.txt:200` interpolates `${PROTOBUF_WELLKNOWN_PROTO_DIR}`, but **the variable is never set anywhere in the gluten repo**. On Linux, protoc defaults to searching `/usr/include` and finds the well-known protos there; Windows has no such fallback.
- **Fix applied:** Passed `-DPROTOBUF_WELLKNOWN_PROTO_DIR=$VCPKG_TRIPLET_INSTALL_DIR\include` via `build-gluten-windows.ps1`.
- **Long-term:** gluten cmake should write a fallback: `if(NOT DEFINED PROTOBUF_WELLKNOWN_PROTO_DIR) set(... auto-detect ...) endif()`.

#### 10. gluten cpp/CMakeLists.txt MSVC branch omits 5 Windows-required defines
- **Symptom:** gluten compiles up to 17/42 and dies in `glog/log_severity.h: fatal error C1189: #error: ERROR macro is defined. Define GLOG_NO_ABBREVIATED_SEVERITIES before including logging.h`.
- **Root cause:** `cpp/CMakeLists.txt:90`'s `if(MSVC)` branch only sets `NDEBUG` and `/Od`. **velox's own `CMakeLists.txt:461` defines a complete set of Windows-required macros — gluten copied none of them:**
  - `GLOG_NO_ABBREVIATED_SEVERITIES` — prevents clash with Win32 `ERROR` macro
  - `NOMINMAX` — prevents `min`/`max` macro pollution from windows.h
  - `WIN32_LEAN_AND_MEAN` — shrinks the windows.h surface
  - `NO_FIXED_STR_UDL` — disables folly's `FixedString` `_fs` UDL (MSVC can't parse it)
  - `_USE_MATH_DEFINES` — makes `M_PI` and friends available
- **Fix applied:** Added all five to the MSVC branch of gluten cpp/CMakeLists.txt via `add_definitions(...)`.
- **Recommendation:** velox already has a complete Windows defines set. gluten should inherit it as INTERFACE rather than re-declaring from scratch.

#### 11. CRT mismatch `/MD` vs `/MT` (LNK2038)
- **Symptom:** gluten compiles 41/41 .obj files cleanly, then link of `gluten.dll` produces dozens of `libprotobuf.lib(...): mismatch detected for 'RuntimeLibrary': value 'MT_StaticRelease' doesn't match value 'MD_DynamicRelease' in algebra.pb.cc.obj`.
- **Root cause:** vcpkg `x64-windows-static` triplet builds every library with `/MT` (static CRT). gluten's own `cl` defaults to `/MD` (dynamic CRT). Mixed CRT linkage is impossible.
- **Fix applied:** Top of `cpp/CMakeLists.txt`, **before** `project()`:
  ```cmake
  if(WIN32)
      cmake_policy(SET CMP0091 NEW)
      set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
  endif()
  ```
- **Key detail:** CMP0091 must be set NEW **before** `project()`, or `CMAKE_MSVC_RUNTIME_LIBRARY` has no effect.

#### 12. Missing `-DARROW_STATIC` causes Arrow headers to emit `__declspec(dllimport)` — symbols unresolved
- **Symptom:** Link reports `LocalPartitionWriter.cc.obj : error LNK2019: unresolved external symbol "__declspec(dllimport) public: static ... arrow::io::BufferedOutputStream::Create"` and similar `__imp_`-prefixed symbols.
- **Root cause:** Arrow headers use `ARROW_EXPORT` macro to control export/import. Without `ARROW_STATIC` defined, the macro expands to `__declspec(dllimport)` (expecting Arrow to be a DLL), but we are linking `arrow_static.lib`.
- **Fix applied:** `target_compile_definitions(gluten PUBLIC ARROW_STATIC PARQUET_STATIC)` in `cpp/core/CMakeLists.txt`.

#### 13. zstd / snappy / lz4 / zlib not explicitly linked
- **Symptom:** Link reports ~52 unresolved `ZSTD_*` symbols from `arrow_static.lib(compression_zstd.cc.obj)`, plus `deflate / inflate` (zlib) and related.
- **Root cause:** On Linux, `arrow_bundled_dependencies.lib` contains statically-archived ZSTD/Snappy/LZ4/zlib. **On Windows it does not** — vcpkg provides each as its own `.lib`, and Arrow's build chose not to re-bundle. gluten cpp/core/CMakeLists.txt does not explicitly link them.
- **Fix applied:** In the `if(WIN32)` branch of `cpp/core/CMakeLists.txt`:
  ```cmake
  target_link_libraries(gluten PRIVATE
      zstd::libzstd_static Snappy::snappy lz4::lz4 ZLIB::ZLIB)
  ```

#### 14. velox's Arrow ExternalProject defaults to `ARROW_PARQUET=OFF` and never enables `ARROW_FILESYSTEM`
- **Symptom:** When building the gluten-to-velox bridge: `cannot open include file: 'arrow/filesystem/filesystem.h'`.
- **Root cause:** `velox/CMake/resolve_dependency_modules/arrow/CMakeLists.txt:72` sets `-DARROW_PARQUET=OFF` and never sets `ARROW_FILESYSTEM` (defaults to OFF). velox itself doesn't use these, but gluten cpp/velox writes Parquet and reads files — **it requires both.**
- **Fix applied:** Added `-DARROW_PARQUET=ON -DARROW_FILESYSTEM=ON` to velox's arrow/CMakeLists.txt; wiped `C:\ae` so velox rebuilds Arrow (~15-20 minutes).
- **Recommendation for mentor:** A coordination blind spot — velox doesn't need these but downstream gluten does. velox's Arrow config should document the dependency, or gluten should fail fast with a clear error.

#### 15. velox's `BOOLEAN()` MSVC macro doesn't work with qualified `velox::BOOLEAN()` calls
- **Symptom:** 4 files in gluten cpp/velox fail with `error C2039: 'BOOLEAN': is not a member of 'facebook::velox'` (10 occurrences total).
- **Root cause:** velox `Type.h:2227-2238` renames the `BOOLEAN` function to `BOOLEAN_` on MSVC (to dodge the Windows `BOOLEAN` typedef from `wtypes.h`) and provides a function-like macro `#define BOOLEAN() ::facebook::velox::BOOLEAN_()`. The macro only fires on **unqualified** `BOOLEAN()`. velox's own header explicitly comments: *"All qualified calls (velox::BOOLEAN()) must use ScalarType<TypeKind::BOOLEAN>::create() directly instead."* **gangpeng wrote this comment himself but never updated the gluten code that calls `facebook::velox::BOOLEAN()` everywhere.**
- **Fix applied:** `sed`-replaced 10 occurrences of `facebook::velox::BOOLEAN()` with `::facebook::velox::BOOLEAN_()` across 4 files.
- **Significance:** This is direct evidence that gangpeng left a known TODO unfinished.

---

### Unresolved: gangpeng's two repos have inconsistent APIs (**the report's headline**)

#### 16. gluten references velox APIs that don't exist (API drift between his own repos)

**Meta-finding:**

| Date | Repo | Top commit |
|---|---|---|
| 2026-04-22 | `gangpeng/gluten` `windows/port` | `[WINDOWS] Add MSVC/Windows support for Gluten Velox backend` |
| 2026-04-28 | `gangpeng/velox` `windows/msvc-port` | `[WINDOWS] Add MSVC/Windows port for Velox` (forked from 2026-03-25 mainline) |

gangpeng's gluten cpp/velox code references velox APIs that **were added to velox mainline after 2026-03-25** — i.e. after his velox fork point:

| API (referenced by gluten) | Actual situation in velox |
|---|---|
| `connector::hive::HiveConfig::kAllowInt32NarrowingSession` | **Not in gangpeng's velox.** In velox mainline, refactor commit `01b86e20d (refactor filebased datasource)` moved this constant to the new `FileConfig` class. |
| `core::OpaqueHashTable` | **Does not exist in any velox** — mainline or gangpeng's branch. gangpeng-invented type, referenced 3× in gluten cpp, never defined anywhere. |
| `core::HashJoinNode(12-arg constructor)` | velox's `HashJoinNode` does not accept 12 arguments. |

**Bottom line:** gangpeng's Windows port is an **unfinished work-in-progress**:
- The velox side did the MSVC port of *existing* features.
- The gluten side was written against *planned* velox features that gangpeng had not actually committed.
- His UTs pass on his machine almost certainly because:
  - The test path doesn't exercise BHJ / Int32 narrowing / the new HashJoinNode signature
  - Locally uncommitted edits patch the gap
  - Binary cache from a working build masks the inconsistency

---

## Inventory of Applied Changes

- `C:\src\gluten\.gitattributes` (added `*.patch -text`, `*.diff -text`)
- `C:\src\velox\.gitattributes` (same)
- `C:\src\gluten\dev\vcpkg\ports\folly\portfile.cmake` (`FOLLY_HAVE_INT128_T` made platform-conditional)
- `C:\src\gluten\dev\vcpkg\ports\folly\windows-nominmax.patch` (new file)
- `C:\src\gluten\dev\vcpkg\ports\folly\portfile.cmake` (registered new patch)
- `C:\src\gluten\dev\vcpkg\vcpkg.json` (`libdwarf` made platform-conditional)
- `C:\src\gluten\dev\vcpkg\vcpkg_installed\x64-windows-static\share\folly\folly-targets.cmake` (stripped `/std:c++17`; post-install patch — must be re-applied after a clean install)
- `C:\src\velox\CMake\resolve_dependency_modules\arrow\CMakeLists.txt` (`ARROW_PARQUET=ON`, `ARROW_FILESYSTEM=ON`)
- `C:\src\gluten\ep\build-velox\build-velox-windows.ps1` (`VELOX_MONO_LIBRARY=OFF`)
- `C:\src\gluten\cpp\CMakeLists.txt` (CMP0091, `CMAKE_MSVC_RUNTIME_LIBRARY`, 5 Windows defines)
- `C:\src\gluten\cpp\velox\CMakeLists.txt` (replaced `velox_part0..3` hard-coding with `file(GLOB_RECURSE)`)
- `C:\src\gluten\cpp\core\CMakeLists.txt` (`ARROW_STATIC` define + explicit link of zstd/snappy/lz4/zlib)
- `C:\src\gluten\cpp\velox\substrait\SubstraitParser.cc` (BOOLEAN_)
- `C:\src\gluten\cpp\velox\substrait\SubstraitToVeloxExpr.cc` (BOOLEAN_)
- `C:\src\gluten\cpp\velox\substrait\SubstraitToVeloxPlan.cc` (BOOLEAN_ + OpaqueHashTable → BaseHashTable)
- `C:\src\gluten\cpp\velox\substrait\VeloxSubstraitSignature.cc` (BOOLEAN_)
- `C:\src\gluten\build-gluten-windows.ps1` (new file)
- `C:\src\build_velox_dll.bat` (new file)

