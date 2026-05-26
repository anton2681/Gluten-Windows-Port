# Gluten + Velox Windows 移植 复现报告

**日期：** 2026-05-18
**作者：** v-huajiang（实习生）
**目标：** 在自己的 Windows 机器上复现 gangpeng 的 Gluten + Velox MSVC 移植，跑通 `spark-submit` 加载 Gluten 插件
**结论：** 复现进行中，**核心 `gluten.dll` 已编译通过；`velox/velox.dll`（gluten 到 velox 的 JNI 桥）因 gangpeng 仓库内部 API 不一致暂时受阻**，已暴露 16 个具体可修复的问题。

---

## 总体状态

| 阶段 | 状态 | 产物 |
|---|---|---|
| 0. 环境（MSVC 2022 / CMake 3.31 / Ninja 1.12） | ✅ 完成 | VS Enterprise 17.14 already on machine |
| 1. vcpkg 内嵌（`gluten/dev/vcpkg/.vcpkg/`，branch 2025.09.17） | ✅ 完成 | vcpkg 2025-09-03 |
| 2. vcpkg install（35+ 依赖） | ✅ 完成 | 7.0 GB at `vcpkg_installed/x64-windows-static/` |
| 3. win_flex_bison | ✅ 完成 | `C:\tmp\winflexbison\{bison,flex}.exe` |
| 4. velox 源（junction → `C:\src\velox`） | ✅ 完成 | gangpeng/velox `windows/msvc-port` @ d62c6b425 |
| 5. velox 编译（116 个 sublib） | ✅ 完成 | `_build/release/velox/**/*.lib` 共 8.7 GB |
| 6. Arrow ExternalProject（PARQUET+FILESYSTEM 开启重建） | ✅ 完成 | `C:\ae\install\lib\{arrow_static,parquet_static,arrow_bundled_dependencies}.lib` |
| 7. `core/gluten.dll`（gluten 核心 JNI lib） | ✅ 完成 | 7.9 MB |
| 8. `velox/velox.dll`（gluten 到 velox 桥） | ❌ 受阻 | 见下方 "未解" |
| 9. mvn package + 注入 dll 到 JAR | ⏳ 未做 | |
| 10. spark-submit 端到端 | ⏳ 未做 | |

---

## 16 个发现（按发生顺序）

### 环境/工具链类（不是 gangpeng 的 bug，是 Windows 自带坑）

#### 1. Git autocrlf 把 `.patch` 文件转 CRLF，破坏 vcpkg 的 patch apply
- **现象：** vcpkg 装 folly 时 `z_vcpkg_apply_patches` 报 `corrupt patch at line 8`，前 4 个 folly patch 蒙混过关，`adding-api.patch` 因 hunk header 校验严格直接挂
- **根因：** git for Windows 默认 `core.autocrlf=true`，所有 `.patch`/`.diff` 被 LF→CRLF 转换
- **修法（已做）：**
  - `git config core.autocrlf false` for gluten 和 velox 两个仓库
  - `*.patch -text` 和 `*.diff -text` 加入 `.gitattributes`
  - 一次性把已损坏的 32 个 overlay patch + 20 个 velox patch 用 `sed -i 's/\r$//'` 转回 LF
- **建议给 mentor：** 在 `dev/vcpkg/init.sh`、Windows 上手文档明确写"先 set core.autocrlf=false"，避免每个新人都踩

#### 2. `git clone --depth 1` shallow-clone vcpkg 破坏 builtin-baseline 解析
- **现象：** 加 `--depth 1` 后 vcpkg 装包瞬间挂，报 `failed to unpack tree object ... vcpkg was cloned as a shallow repository`，每个 port 都报
- **根因：** vcpkg manifest 模式靠 git `read-tree <commit>` 拿 port 的精确版本；shallow clone 把历史 commit 丢了
- **修法：** `git fetch --unshallow`（或重 clone 不带 `--depth`）
- **建议：** init.sh 里那行 `git clone https://github.com/microsoft/vcpkg.git --branch 2025.09.17 "$VCPKG_ROOT"` 注释里加一句"切勿加 --depth 1"

---

### Upstream Linux 配置漏掉 Windows 平台（gangpeng 没拦截）

#### 3. folly portfile.cmake 强制 `FOLLY_HAVE_INT128_T=ON`，MSVC 编不过
- **现象：** vcpkg 编 folly 时 `Conv.h / Traits.h / Hash.h` 全炸：`error C4235: '__int128' keyword not supported on this architecture`，30+ 处级联语法错误
- **根因：** `dev/vcpkg/ports/folly/portfile.cmake:60` 写死 `-DFOLLY_HAVE_INT128_T=ON`（注释 `# Required by Velox`）。`git log` 显示 **gangpeng 从未改过这个文件**，是 upstream Linux-only 继承的
- **gangpeng 的 UT 为啥能跑通：** 大概率本地 vcpkg binary cache 命中，没真在干净机器上 install 过
- **修法（已做）：** portfile 改成平台条件
  ```cmake
  if(VCPKG_TARGET_IS_WINDOWS)
      set(FOLLY_INT128_T_OPT "-DFOLLY_HAVE_INT128_T=OFF")
  else()
      set(FOLLY_INT128_T_OPT "-DFOLLY_HAVE_INT128_T=ON")
  endif()
  ```
- **遗留风险：** Velox link 时若需要 `folly::to<__int128>(...)`，会缺符号；目前未触发

#### 4. folly 缺 NOMINMAX → glog `ERROR` 宏冲突 + windows.h `max/min` 宏污染
- **现象：** folly 装到一半挂在 `CheckedMath.h / ConstexprMath.h / CancellationToken-inl.h`，几百行 `warning C4003: not enough arguments for function-like macro invocation 'max'` + `C2589: '(': illegal token on right side of '::'`
- **根因：** folly 的 `FollyCompilerMSVC.cmake:300` 只加了 `WIN32_LEAN_AND_MEAN`（由 `MSVC_ENABLE_LEAN_AND_MEAN_WINDOWS` 开关控制），**没加 `NOMINMAX`**。`windows.h` 把 `max`/`min` 当宏，`std::numeric_limits<T>::max()` 整个被宏吞掉
- **修法（已做）：** 新增 `dev/vcpkg/ports/folly/windows-nominmax.patch`，把 `NOMINMAX` 加进 folly 的 `target_compile_definitions`，注册到 portfile 的 patches 列表
- **建议：** 这是 folly upstream 的疏漏，可顺手给 folly 提 PR

#### 5. libelf / libdwarf 在 Windows 上根本不该装
- **现象：** vcpkg 装 libelf 时走 autotools+MSVC，cl.exe 出 `.obj`、autotools `ar` 找 `.o` → `ar: begin.o: No such file or directory`，加几百行 `cl : Command line warning D9002 : ignoring unknown option '-Xcompiler'`
- **根因：** ELF/DWARF 是 Linux 二进制+调试格式，Windows 用 PE/COFF + PDB。`dev/vcpkg/vcpkg.json` 把 `libdwarf` 列为无条件依赖，libdwarf 又依赖 libelf
- **修法（已做）：** vcpkg.json 改成 `{"name": "libdwarf", "platform": "!windows"}`，transitively 跳过 libelf

#### 6. folly 把 `/std:c++17` 写进 `INTERFACE_COMPILE_OPTIONS`，传染 velox（强制降到 C++17）
- **现象：** velox 编了 ~875 个 .cpp 文件，每个都 `cl : Command line warning D9025 : overriding '/std:c++20' with '/std:c++17'`，然后 `error C2039: 'span': is not a member of 'std'` / `'strong_ordering': is not a member of 'std'` / `error C2098: unexpected token after data member '<='`（spaceship `<=>`）—— C++20 特性全炸
- **根因：** `vcpkg_installed/x64-windows-static/share/folly/folly-targets.cmake:64,81,90` 三处 `INTERFACE_COMPILE_OPTIONS` 硬编码 `/std:c++17`，velox `target_link_libraries(velox folly::folly)` 后传染所有 velox target；MSVC 后到 `/std:c++17` 覆盖前面的 `/std:c++20`
- **修法（已做）：** sed 把已装的 folly-targets.cmake 三处 `/std:c++17;` 拿掉
- **长远修法：** 应该 patch `dev/vcpkg/ports/folly/FollyCompilerMSVC.cmake`，让它**不**把 `/std:c++17` 加到 PUBLIC/INTERFACE compile options，让 consumer 自己用 `CMAKE_CXX_STANDARD` 控制。可同步给 folly upstream 提 PR

---

### gangpeng 自己的脚本/CMake 配置遗漏

#### 7. `VELOX_MONO_LIBRARY=ON` 撞 Windows 静态库 4 GB 上限
- **现象：** velox 1684/1688 任务成功，最后 link `velox.lib` 时 `lib.exe: fatal error LNK1248: image size (100FD2724) exceeds maximum allowable size (FFFFFFFF)`（即 4.01 GB 超过 4 GB 硬上限）
- **根因：** `build-velox-windows.ps1:130` 写死 `-DVELOX_MONO_LIBRARY=ON`。Windows COFF 静态归档格式成员偏移是 32 位 → 4 GB 硬上限；Linux `ar` 没此限制
- **为啥之前能跑：** velox 主线最近半年加了大量新算子/函数，体积从 ~3.x GB 涨到 4.01 GB，**刚刚超线**。这是会随着 velox 主线同步**自动恶化**的隐藏雷
- **修法（已做）：** ps1 改成 `MONO_LIBRARY=OFF`，velox 切成 116 个 per-module sublib
- **副作用：** 见发现 #8

#### 8. gluten cpp/velox 期望 `velox_part0..3.lib` 但 split 脚本不存在
- **现象：** gluten cmake configure 报 `Library does not exist: velox_part0.lib`
- **根因：** `cpp/velox/CMakeLists.txt:293-300` 写死 `foreach(_part 0 1 2 3) import_library(... velox_part${_part}.lib)`，注释"On Windows, velox is split into multiple lib files"——**但 velox 仓库和 gluten 仓库都没有 split 脚本**。这是 gangpeng**预想但没实现**的工作
- **修法（已做）：** 改成 `file(GLOB_RECURSE)` 发现所有 116 个 per-module sublib，全部 import 给 `facebook::velox` INTERFACE target
- **建议给 mentor：** 这是个真实的设计缺陷——要么写 split 脚本（复杂），要么按我改的 glob 方式去掉这层期望（已验证可行）

#### 9. `PROTOBUF_WELLKNOWN_PROTO_DIR` 整个 gluten 只用不设
- **现象：** gluten build 第 1 步 protoc 报 `Missing value for flag: --proto_path`，命令是 `--proto_path X/ --proto_path --cpp_out Y`（中间那个 `--proto_path` 没值）
- **根因：** `cpp/core/CMakeLists.txt:200` 用 `${PROTOBUF_WELLKNOWN_PROTO_DIR}`，但**整个 gluten 仓库都没设**这个变量。Linux protoc 默认搜 `/usr/include` 兜底，Windows 没默认路径
- **修法（已做）：** 在 `build-gluten-windows.ps1` 命令行传 `-DPROTOBUF_WELLKNOWN_PROTO_DIR=$VCPKG_TRIPLET_INSTALL_DIR\include`
- **长远：** gluten 应该在 cmake 里写 fallback：`if(NOT DEFINED PROTOBUF_WELLKNOWN_PROTO_DIR) set(...) endif()`

#### 10. gluten cpp/CMakeLists.txt MSVC 分支漏掉 5 个 Windows 必备 define
- **现象：** gluten 编 17/42 时挂在 `glog/log_severity.h: fatal error C1189: #error: ERROR macro is defined. Define GLOG_NO_ABBREVIATED_SEVERITIES before including logging.h`
- **根因：** `cpp/CMakeLists.txt:90` 的 `if(MSVC)` 分支只设了 `NDEBUG`/`/Od`，**velox 自己的 CMakeLists.txt:461 设了一整套 Windows 必备 define，gluten 完全没复制过来**：
  - `GLOG_NO_ABBREVIATED_SEVERITIES` —— 避免 `ERROR` 宏冲突
  - `NOMINMAX` —— 避免 `min`/`max` 宏污染
  - `WIN32_LEAN_AND_MEAN` —— 缩 windows.h 表面
  - `NO_FIXED_STR_UDL` —— 关 folly FixedString `_fs` UDL（MSVC 解析不了）
  - `_USE_MATH_DEFINES` —— 让 `M_PI` 之类可用
- **修法（已做）：** 在 gluten cpp MSVC 分支补 `add_definitions(...)` 把这 5 个都加上
- **建议：** velox 已经有完整 Windows define 集，gluten 应该直接 INTERFACE 继承或复制，而不是从零再写

#### 11. CRT 链接错配 `/MD` vs `/MT`（LNK2038）
- **现象：** gluten 编译 41/41 任务全过，link `gluten.dll` 时几十个 `libprotobuf.lib(...): mismatch detected for 'RuntimeLibrary': value 'MT_StaticRelease' doesn't match value 'MD_DynamicRelease' in algebra.pb.cc.obj`
- **根因：** vcpkg `x64-windows-static` triplet 装的所有库都用 `/MT`（静态 CRT），gluten 自己 cl 默认 `/MD`（动态 CRT），混用必挂
- **修法（已做）：** `cpp/CMakeLists.txt` 顶部 `project()` 之前加：
  ```cmake
  if(WIN32)
      cmake_policy(SET CMP0091 NEW)
      set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
  endif()
  ```
- **要点：** CMP0091 必须在 `project()` 之前 set，否则 `CMAKE_MSVC_RUNTIME_LIBRARY` 不生效

#### 12. 缺 `-DARROW_STATIC` 导致 Arrow 头文件出 `__declspec(dllimport)`，找不到符号
- **现象：** Link 报 `LocalPartitionWriter.cc.obj : error LNK2019: unresolved external symbol "__declspec(dllimport) public: static ... arrow::io::BufferedOutputStream::Create"` 等 `__imp_` 前缀符号
- **根因：** Arrow 头文件用 `ARROW_EXPORT` 宏控制 export/import；没定义 `ARROW_STATIC` 时默认是 `__declspec(dllimport)`（期望从 DLL 加载），但我们 link 的是 `arrow_static.lib`
- **修法（已做）：** `cpp/core/CMakeLists.txt` 加 `target_compile_definitions(gluten PUBLIC ARROW_STATIC PARQUET_STATIC)`

#### 13. zstd / snappy / lz4 / zlib 显式 link 缺失
- **现象：** Link 报 ~52 个 `arrow_static.lib(compression_zstd.cc.obj) : error LNK2019: unresolved external symbol ZSTD_*`，类似的还有 `deflate / inflate`（zlib）
- **根因：** `arrow_bundled_dependencies.lib` 在 Linux 包含静态化的 ZSTD/Snappy/LZ4/zlib，**Windows 上不包含**（vcpkg 已经提供单独的 .lib，Arrow build 选择不再 bundle）。gluten cpp/core/CMakeLists.txt 没显式 link 这几个
- **修法（已做）：** `cpp/core/CMakeLists.txt` 在 `if(WIN32)` 分支显式 `target_link_libraries(gluten PRIVATE zstd::libzstd_static Snappy::snappy lz4::lz4 ZLIB::ZLIB)`

#### 14. velox 的 Arrow ExternalProject 默认 `ARROW_PARQUET=OFF` + 没启用 `ARROW_FILESYSTEM`
- **现象：** gluten 编 velox 桥时 `cannot open include file: 'arrow/filesystem/filesystem.h'`
- **根因：** `velox/CMake/resolve_dependency_modules/arrow/CMakeLists.txt:72` 写 `-DARROW_PARQUET=OFF`，没设 `ARROW_FILESYSTEM`（默认 OFF）。velox 自己用 Arrow 不需要这俩，但 gluten cpp/velox 写 Parquet/读文件**必须有**
- **修法（已做）：** velox 的 arrow/CMakeLists.txt 加 `-DARROW_PARQUET=ON -DARROW_FILESYSTEM=ON`，wipe `C:\ae` 让 velox 重 build Arrow（约 15-20 分钟）
- **建议给 mentor：** 这是 velox+gluten 协作上的盲区——velox 单跑不需要，但下游 gluten 需要。应在 velox 的 Arrow 配置写注释说明，或在 gluten 这边 fail-fast 提示

#### 15. velox 的 `BOOLEAN()` MSVC 宏不兼容 qualified `velox::BOOLEAN()` 调用
- **现象：** gluten cpp/velox 4 个文件挂 `error C2039: 'BOOLEAN': is not a member of 'facebook::velox'`，10 处用法
- **根因：** velox `Type.h:2227-2238` 在 MSVC 上把 `BOOLEAN` 函数重命名为 `BOOLEAN_`，提供 macro `#define BOOLEAN() ::facebook::velox::BOOLEAN_()`——只对**裸 `BOOLEAN()`** 起作用。velox 自己的注释明确写"All qualified calls (velox::BOOLEAN()) must use ScalarType<TypeKind::BOOLEAN>::create() directly instead"。**gangpeng 自己写下了这条注释，但 gluten 代码里照用 `facebook::velox::BOOLEAN()` 没改**
- **修法（已做）：** sed 把 4 个文件里 10 处 `facebook::velox::BOOLEAN()` 替换成 `::facebook::velox::BOOLEAN_()`
- **关键性：** 这是大老板**自己留了 TODO 没做完**的典型证据

---

### 未解：gangpeng 自己两个仓库 API 不一致（**报告核心**）

#### 16. gluten 引用了 velox 不存在的 API（API 漂移）

**Meta 发现：**

| 时间 | 仓库 | 顶 commit |
|---|---|---|
| 2026-04-22 | `gangpeng/gluten` `windows/port` | `[WINDOWS] Add MSVC/Windows support for Gluten Velox backend` |
| 2026-04-28 | `gangpeng/velox` `windows/msvc-port` | `[WINDOWS] Add MSVC/Windows port for Velox`（基于 2026-03-25 主线分叉） |

gangpeng 的 gluten cpp/velox 代码引用了 **2026-03-25 之后才进 velox 主线的 API**：

| API（gluten 引用） | velox 现实情况 |
|---|---|
| `connector::hive::HiveConfig::kAllowInt32NarrowingSession` | **gangpeng velox 没有；velox 主线 commit `01b86e20d refactor filebased datasource` 把它移到了新类 `FileConfig`** |
| `core::OpaqueHashTable` | **velox 主线和 gangpeng velox 都不存在**，是 gangpeng 自创类型；只有 gluten cpp 3 处引用，无定义 |
| `core::HashJoinNode(12 个参数)` | velox 的 `HashJoinNode` 不接受 12 参数构造 |

**翻译成结论：** gangpeng 这次 Windows 移植是一个**未收尾的半成品**：
- velox 那边只把现有功能 MSVC 化了，**没把 gluten 计划用的新 API 加进去**
- gluten 那边照着"velox 应该有的"写代码，引用了 velox 没的东西
- 他自己的 UT 能跑通，大概率因为：
  - 走的测试路径不经过 BHJ / Int32 narrowing / 新 HashJoinNode 签名
  - 本地有未提交的修改
  - 用了 binary cache 把这些代码绕过去了

**我已修好的部分（OpaqueHashTable）：** 把 `core::OpaqueHashTable` 替换成 `exec::BaseHashTable`，因为 gluten 的 `HashTableBuilder::hashTable()` 实际返回的就是 `BaseHashTable`。这是 gangpeng 自己代码内部的命名错误，本来 30 秒能改对。

**我没动的部分（剩下两个）：** 需要 mentor 决策语义：
1. `kAllowInt32NarrowingSession` —— 是把 velox 升到包含此常量的主线 commit，还是 cherry-pick `01b86e20d` 到 gangpeng velox 分支，还是直接把 gluten 这段改成默认值
2. `HashJoinNode` 12 参数 —— 需要看 velox 当前 `HashJoinNode` 签名，决定 gluten 这边怎么对齐

---

## 已应用修改清单（文件级）

- `C:\src\gluten\.gitattributes`（新增 `*.patch -text`, `*.diff -text`）
- `C:\src\velox\.gitattributes`（同上）
- `C:\src\gluten\dev\vcpkg\ports\folly\portfile.cmake`（FOLLY_HAVE_INT128_T 平台条件）
- `C:\src\gluten\dev\vcpkg\ports\folly\windows-nominmax.patch`（新增）
- `C:\src\gluten\dev\vcpkg\ports\folly\portfile.cmake`（注册新 patch）
- `C:\src\gluten\dev\vcpkg\vcpkg.json`（libdwarf 平台条件）
- `C:\src\gluten\dev\vcpkg\vcpkg_installed\x64-windows-static\share\folly\folly-targets.cmake`（剥 `/std:c++17`，post-install 改动；clean install 后需 re-apply）
- `C:\src\velox\CMake\resolve_dependency_modules\arrow\CMakeLists.txt`（ARROW_PARQUET=ON, ARROW_FILESYSTEM=ON）
- `C:\src\gluten\ep\build-velox\build-velox-windows.ps1`（VELOX_MONO_LIBRARY=OFF）
- `C:\src\gluten\cpp\CMakeLists.txt`（CMP0091, MSVC_RUNTIME_LIBRARY, Windows 5 个 define）
- `C:\src\gluten\cpp\velox\CMakeLists.txt`（用 `file(GLOB_RECURSE)` 替换 `velox_part0..3` 硬编码）
- `C:\src\gluten\cpp\core\CMakeLists.txt`（ARROW_STATIC define + 显式 link zstd/snappy/lz4/zlib）
- `C:\src\gluten\cpp\velox\substrait\SubstraitParser.cc`（BOOLEAN_）
- `C:\src\gluten\cpp\velox\substrait\SubstraitToVeloxExpr.cc`（BOOLEAN_）
- `C:\src\gluten\cpp\velox\substrait\SubstraitToVeloxPlan.cc`（BOOLEAN_ + OpaqueHashTable → BaseHashTable）
- `C:\src\gluten\cpp\velox\substrait\VeloxSubstraitSignature.cc`（BOOLEAN_）
- `C:\src\gluten\build-gluten-windows.ps1`（新增）
- `C:\src\build_velox_dll.bat`（新增）

---

## 建议给 mentor 的下一步

### 短期（解锁 velox.dll）
1. **决策 `kAllowInt32NarrowingSession` 路线**：cherry-pick 上游 velox refactor (`01b86e20d`) 到 gangpeng velox 分支，还是把 gluten 这边改成不依赖该常量
2. **决策 `HashJoinNode` 12 参数路线**：对比 gangpeng velox 的 `HashJoinNode` 签名和 gluten 调用，要么改 velox 加重载，要么改 gluten 删/换参数
3. 完成后，可继续走 `mvn package` + `update_jars.ps1` + `spark-submit` 路径

### 中期（让 gangpeng 的工作变成可复现）
4. **建立 velox + gluten 两个仓库的"版本对照表"**：明确"gluten 顶 commit X 对应 velox 顶 commit Y"
5. **把所有上面 1-15 项的修复推进 gangpeng 的两个仓库**——目前他的 commit 在干净机器上**编不出**，这是仓库可信度问题
6. **在 CI 上加 Windows clean build job**：避免 binary cache 蒙混过关

### 长期（向 upstream 输出）
7. folly 的 `/std:c++17` INTERFACE 泄漏（发现 #6）可给 folly upstream 提 PR
8. folly 的 NOMINMAX 缺失（发现 #4）同理

---

## 附：可复用资源

- `MEMORY.md` 索引下的 8 篇技术备忘录（位于 `C:\Users\v-huajiang\.claude\projects\C--Users-v-huajiang\memory\`）
- 所有 .log 文件保留在 `C:\src\install_vcpkg.log`、`C:\src\velox_build.log`、`C:\src\gluten_build.log`、`C:\src\gluten_velox_build.log`
- 复现路径：clone gangpeng/gluten + gangpeng/velox → 应用本报告"已应用修改清单"里的所有改动 → 跑 `build-velox-windows.ps1` → 跑 `build-gluten-windows.ps1` → 跑 `build_velox_dll.bat`
