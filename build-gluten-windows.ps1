# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# Mirror of build-velox-windows.ps1 for the gluten cpp side.

param(
    [string]$BuildType = "Release",
    [int]$NumThreads = 0
)

$ErrorActionPreference = "Stop"

$GlutenRoot = "C:\src\gluten"
$VeloxHome  = "$GlutenRoot\ep\build-velox\build\velox_ep"
$VcpkgDir   = "$GlutenRoot\dev\vcpkg"
$BuildDir   = switch ($BuildType.ToLower()) { "debug" { "debug" } default { "release" } }
$VeloxBuildPath = "$VeloxHome\_build\$BuildDir"
$ArrowHome  = "C:\ae"
$CppBuild   = "$GlutenRoot\cpp\build"

Write-Host "GlutenRoot     = $GlutenRoot"
Write-Host "VeloxHome      = $VeloxHome"
Write-Host "VeloxBuildPath = $VeloxBuildPath"
Write-Host "ArrowHome      = $ArrowHome"
Write-Host "CppBuild       = $CppBuild"

# vcpkg env (same as build-velox-windows.ps1)
$env:VCPKG_ROOT               = "$VcpkgDir\.vcpkg"
$env:VCPKG                    = "$VcpkgDir\.vcpkg\vcpkg.exe"
$env:VCPKG_TRIPLET            = "x64-windows-static"
$env:VCPKG_MANIFEST_DIR       = $VcpkgDir
$env:VCPKG_TRIPLET_INSTALL_DIR = "$VcpkgDir\vcpkg_installed\$env:VCPKG_TRIPLET"
$env:CMAKE_TOOLCHAIN_FILE     = "$VcpkgDir\toolchain.cmake"
$env:CMAKE_PREFIX_PATH        = $env:VCPKG_TRIPLET_INSTALL_DIR
$env:GLUTEN_VCPKG_ENABLED     = $env:VCPKG_ROOT

# Source MSVC env
$vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsInstallPath = & $vsWhere -latest -property installationPath 2>$null
$vcvarsAll = "$vsInstallPath\VC\Auxiliary\Build\vcvars64.bat"
Write-Host "Sourcing MSVC env from: $vcvarsAll"
$vsInstallerDir = Split-Path $vsWhere -Parent
$envDump = cmd.exe /c "set PATH=$vsInstallerDir;%PATH% && `"$vcvarsAll`" && set" 2>$null
foreach ($line in $envDump) {
    if ($line -match "^([^=]+)=(.*)$") {
        [System.Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], "Process")
    }
}

# winflexbison
$winFlexBisonDir = "C:\tmp\winflexbison"
if (Test-Path "$winFlexBisonDir\bison.exe") {
    $env:PATH = "$winFlexBisonDir;$env:PATH"
}

New-Item -ItemType Directory -Force -Path $CppBuild | Out-Null

$CmakeOptions = @(
    "-DCMAKE_BUILD_TYPE=$BuildType",
    "-DBUILD_VELOX_BACKEND=ON",
    "-DBUILD_TESTS=OFF",
    "-DBUILD_EXAMPLES=OFF",
    "-DBUILD_BENCHMARKS=OFF",
    "-DBUILD_TEST_UTILS=OFF",
    "-DENABLE_HDFS=OFF",
    "-DENABLE_S3=OFF",
    "-DENABLE_GCS=OFF",
    "-DENABLE_ABFS=OFF",
    "-DENABLE_ORC=OFF",
    "-DENABLE_GPU=OFF",
    "-DENABLE_ENHANCED_FEATURES=OFF",
    "-DVELOX_HOME=$VeloxHome",
    "-DVELOX_BUILD_PATH=$VeloxBuildPath",
    "-DARROW_HOME=$ArrowHome",
    "-DPROTOBUF_WELLKNOWN_PROTO_DIR=$env:VCPKG_TRIPLET_INSTALL_DIR\include"
)

Write-Host ""
Write-Host "=== Configuring Gluten cpp with CMake ==="
$configArgs = @(
    "-B", $CppBuild,
    "-S", "$GlutenRoot\cpp",
    "--toolchain", $env:CMAKE_TOOLCHAIN_FILE,
    "-GNinja"
) + $CmakeOptions
Write-Host "cmake $($configArgs -join ' ')"
cmake @configArgs
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed" }

Write-Host ""
Write-Host "=== Building Gluten ==="
$parallelArgs = @()
if ($NumThreads -gt 0) {
    $parallelArgs = @("--parallel", $NumThreads)
} else {
    $cores = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    $parallelArgs = @("--parallel", $cores)
}

cmake --build $CppBuild @parallelArgs --target gluten
if ($LASTEXITCODE -ne 0) { throw "CMake build failed" }

Write-Host ""
Write-Host "=== Gluten built successfully! ==="
Write-Host "Outputs:"
Get-ChildItem -Recurse -Filter "*.dll" -Path $CppBuild | Select-Object FullName
