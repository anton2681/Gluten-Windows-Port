# Inject arrow_cdata_jni.dll into the gluten-velox-bundle JAR at the
# x86_64/arrow_cdata_jni.dll path that arrow-java's JniLoader expects.
#
# Run AFTER build_arrow_cdata.bat has produced arrow_cdata_jni.dll, AND AFTER
# mvn package + update_jars.ps1 has produced the bundle JAR.

param(
    [string]$GlutenRepo  = (Resolve-Path "$PSScriptRoot\..\.."),
    [string]$Jar         = $null,
    [string]$ArrowCdataDll = $null,
    [string]$JavaHome    = $env:JAVA_HOME
)

if (-not $Jar) {
    $Jar = "$GlutenRepo\package\target\gluten-velox-bundle-spark3.5_2.12-windows_amd64-1.7.0-SNAPSHOT.jar"
}
if (-not $ArrowCdataDll) {
    if ($env:ARROW_CDATA_BUILD_DIR) {
        $ArrowCdataDll = "$env:ARROW_CDATA_BUILD_DIR\arrow_cdata_jni.dll"
    } else {
        $ArrowCdataDll = 'C:\tmp\arrow_cdata_build\arrow_cdata_jni.dll'
    }
}
if (-not $JavaHome) {
    $JavaHome = 'C:\Program Files\Java\jdk-11'
}

$jarCmd = "$JavaHome\bin\jar.exe"
$tmpDir = "$env:TEMP\arrow_inject_$([System.Guid]::NewGuid().Guid.Substring(0,8))"

if (-not (Test-Path $Jar)) { Write-Error "Bundle JAR not found: $Jar"; exit 1 }
if (-not (Test-Path $ArrowCdataDll)) { Write-Error "arrow_cdata_jni.dll not found: $ArrowCdataDll"; exit 1 }

New-Item -ItemType Directory -Path $tmpDir | Out-Null
New-Item -ItemType Directory -Path "$tmpDir\x86_64" -Force | Out-Null
Copy-Item $ArrowCdataDll "$tmpDir\x86_64\arrow_cdata_jni.dll" -Force
Write-Host "Adding x86_64/arrow_cdata_jni.dll to $Jar"

Push-Location $tmpDir
& $jarCmd uf $Jar x86_64
$rc = $LASTEXITCODE
Pop-Location

if ($rc -eq 0) {
    Write-Host "Done. New size: $((Get-Item $Jar).Length) bytes"
} else {
    Write-Host "FAIL (exit $rc)"
}
Remove-Item -Recurse -Force $tmpDir
