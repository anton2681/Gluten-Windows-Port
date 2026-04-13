# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Windows equivalent of build-velox.sh.
# Configures and builds Velox using MSVC + CMake + Ninja.

param(
    [string]$VeloxHome = "",
    [string]$BuildType = "Release",
    [switch]$EnableS3 = $false,
    [switch]$EnableGcs = $false,
    [switch]$EnableHdfs = $false,
    [switch]$EnableAbfs = $false,
    [switch]$BuildTestUtils = $false,
    [switch]$BuildTests = $false,
    [int]$NumThreads = 0
)

$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$GlutenRoot  = Split-Path -Parent (Split-Path -Parent $ScriptRoot)
$VcpkgDir    = "$GlutenRoot\dev\vcpkg"

# ── Locate Velox source ───────────────────────────────────────────────────────
if ($VeloxHome -eq "") {
    $VeloxHome = "$ScriptRoot\build\velox_ep"
}
if (-not (Test-Path "$VeloxHome\CMakeLists.txt")) {
    throw "Velox source not found at $VeloxHome. Run get-velox.sh first or pass -VeloxHome."
}

Write-Host "VeloxHome  = $VeloxHome"
Write-Host "BuildType  = $BuildType"

# ── Set up vcpkg environment ──────────────────────────────────────────────────
$env:VCPKG_ROOT               = "$VcpkgDir\.vcpkg"
$env:VCPKG                    = "$VcpkgDir\.vcpkg\vcpkg.exe"
$env:VCPKG_TRIPLET            = "x64-windows-static"
$env:VCPKG_MANIFEST_DIR       = $VcpkgDir
$env:VCPKG_TRIPLET_INSTALL_DIR = "$VcpkgDir\vcpkg_installed\$env:VCPKG_TRIPLET"
$env:CMAKE_TOOLCHAIN_FILE     = "$VcpkgDir\toolchain.cmake"
$env:CMAKE_PREFIX_PATH        = $env:VCPKG_TRIPLET_INSTALL_DIR
$env:GLUTEN_VCPKG_ENABLED     = $env:VCPKG_ROOT

# ── Find MSVC via vswhere ─────────────────────────────────────────────────────
$vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vsWhere)) {
    $vsWhere = "${env:ProgramFiles}\Microsoft Visual Studio\Installer\vswhere.exe"
}

$vsInstallPath = & $vsWhere -latest -property installationPath 2>$null
if (-not $vsInstallPath) {
    throw "Visual Studio not found. Install VS 2022 with C++ workload."
}

# Source the VS developer environment
$vcvarsAll = "$vsInstallPath\VC\Auxiliary\Build\vcvars64.bat"
Write-Host "Sourcing MSVC environment from: $vcvarsAll"

# Run vcvars64.bat and capture the env changes.
# vcvars64.bat internally calls vswhere.exe; prepend the VS Installer directory
# to PATH so cmd.exe can find it even when launched from a non-native shell.
$vsInstallerDir = Split-Path $vsWhere -Parent
$envDump = cmd.exe /c "set PATH=$vsInstallerDir;%PATH% && `"$vcvarsAll`" && set" 2>$null
foreach ($line in $envDump) {
    if ($line -match "^([^=]+)=(.*)$") {
        [System.Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], "Process")
    }
}

# ── Find CMake and Ninja ──────────────────────────────────────────────────────
$cmakeCmd = Get-Command cmake -ErrorAction SilentlyContinue
$cmakePath = if ($cmakeCmd) { $cmakeCmd.Source } else { $null }
if (-not $cmakePath) {
    # Try VS-bundled cmake
    $cmakePath = "$vsInstallPath\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
    if (Test-Path $cmakePath) {
        $env:PATH = "$vsInstallPath\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin;$env:PATH"
    } else {
        throw "cmake not found. Install CMake or the VS CMake component."
    }
}
Write-Host "CMake: $(cmake --version | Select-Object -First 1)"

$ninjaCmd = Get-Command ninja -ErrorAction SilentlyContinue
$ninjaPath = if ($ninjaCmd) { $ninjaCmd.Source } else { $null }
if (-not $ninjaPath) {
    $ninjaPath = "$vsInstallPath\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe"
    if (Test-Path $ninjaPath) {
        $env:PATH = "$vsInstallPath\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja;$env:PATH"
    }
}

# ── Find Bison and Flex (winflexbison) ────────────────────────────────────────
# Use winflexbison from a known local path; the executables must be named
# bison.exe / flex.exe (copies of win_bison.exe / win_flex.exe) so CMake's
# FindBISON / FindFLEX modules can locate them.
$winFlexBisonDir = "C:\tmp\winflexbison"
if (Test-Path "$winFlexBisonDir\bison.exe") {
    $env:PATH = "$winFlexBisonDir;$env:PATH"
    Write-Host "Bison: $winFlexBisonDir\bison.exe"
} else {
    throw "winflexbison not found at $winFlexBisonDir. Run: Expand-Archive win_flex_bison-*.zip -DestinationPath $winFlexBisonDir; copy bison/flex exes."
}
$BuildDir = switch ($BuildType.ToLower()) {
    "debug"   { "debug" }
    default   { "release" }
}
$BuildPath = "$VeloxHome\_build\$BuildDir"
New-Item -ItemType Directory -Force -Path $BuildPath | Out-Null

# ── Assemble CMake options ────────────────────────────────────────────────────
$CmakeOptions = @(
    "-DCMAKE_BUILD_TYPE=$BuildType",
    "-DVELOX_ENABLE_PARQUET=ON",
    "-DVELOX_BUILD_TESTING=OFF",
    "-DVELOX_MONO_LIBRARY=ON",
    "-DVELOX_BUILD_RUNNER=OFF",
    "-DVELOX_SIMDJSON_SKIPUTF8VALIDATION=ON",
    "-DVELOX_ENABLE_GEO=ON",
    "-DVELOX_GFLAGS_TYPE=static",
    "-DTREAT_WARNINGS_AS_ERRORS=0",
    "-DENABLE_ALL_WARNINGS=1",
    # Tell Velox to use pre-installed libraries when available, fall back to bundled
    "-DVELOX_DEPENDENCY_SOURCE=AUTO",
    # Arrow is not in vcpkg; always build it from source as an ExternalProject
    "-DArrow_SOURCE=BUNDLED",
    # Disable features that require Linux-specific tooling
    "-DVELOX_ENABLE_HDFS=OFF",
    "-DVELOX_BUILD_BENCHMARKS=OFF"
)

if ($BuildTestUtils) { $CmakeOptions += "-DVELOX_BUILD_TEST_UTILS=ON" }
if ($BuildTests)     { $CmakeOptions += "-DVELOX_BUILD_TESTING=ON" }
if ($EnableS3)       { $CmakeOptions += "-DVELOX_ENABLE_S3=ON" }
if ($EnableGcs)      { $CmakeOptions += "-DVELOX_ENABLE_GCS=ON" }
if ($EnableHdfs)     { $CmakeOptions += "-DVELOX_ENABLE_HDFS=ON" }
if ($EnableAbfs)     { $CmakeOptions += "-DVELOX_ENABLE_ABFS=ON" }

# Ninja generator
$GeneratorArgs = @("-GNinja")

# ── CMake configure ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Configuring Velox with CMake ==="
Write-Host "Build path: $BuildPath"

$configArgs = @(
    "-B", $BuildPath,
    "-S", $VeloxHome,
    "--toolchain", $env:CMAKE_TOOLCHAIN_FILE
) + $GeneratorArgs + $CmakeOptions

Write-Host "cmake $($configArgs -join ' ')"
cmake @configArgs
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed" }

# ── CMake build ───────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Building Velox ==="

$parallelArgs = @()
if ($NumThreads -gt 0) {
    $parallelArgs = @("--parallel", $NumThreads)
} else {
    $cores = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    $parallelArgs = @("--parallel", $cores)
}

cmake --build $BuildPath @parallelArgs
if ($LASTEXITCODE -ne 0) { throw "CMake build failed" }

Write-Host ""
Write-Host "=== Velox built successfully! ==="
Write-Host "Output: $BuildPath"
