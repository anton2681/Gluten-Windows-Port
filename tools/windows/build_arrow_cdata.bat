@echo off
rem Build the arrow_cdata_jni.dll standalone (Windows port).
rem
rem Why this is separate: arrow's official mvn profile generate-libs-cdata-all-os
rem only targets Linux/Mac. On Windows we build the JNI bridge directly with cmake.
rem
rem Prerequisites:
rem  - JDK 11
rem  - Arrow 15.0.0 source extracted at C:\src\gluten\ep\_ep\arrow_ep\
rem    (download from https://github.com/apache/arrow/archive/refs/tags/apache-arrow-15.0.0.tar.gz,
rem     then patch with files under gluten/ep/build-velox/src/modify_arrow*.patch)
rem  - cmake + ninja
rem
rem Output: <build_dir>\arrow_cdata_jni.dll  (~222 KB)
rem        Inject into the bundle JAR via inject_arrow_cdata.ps1.
setlocal
call "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat" >NUL
if not defined JAVA_HOME set "JAVA_HOME=C:\PROGRA~1\Java\jdk-11"
set "PATH=%JAVA_HOME%\bin;%PATH%"

set SRC=%~dp0arrow_cdata_jni
if not defined ARROW_CDATA_BUILD_DIR set ARROW_CDATA_BUILD_DIR=C:\tmp\arrow_cdata_build

if exist %ARROW_CDATA_BUILD_DIR% rmdir /s /q %ARROW_CDATA_BUILD_DIR%
mkdir %ARROW_CDATA_BUILD_DIR%
cd /D %ARROW_CDATA_BUILD_DIR%

echo === Configuring standalone arrow_cdata_jni ===
cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded %SRC% || exit /b 1

echo === Building ===
cmake --build . || exit /b 1

echo === Output ===
dir /S *.dll
exit /b 0
