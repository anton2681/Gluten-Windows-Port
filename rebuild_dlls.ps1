$vsDevCmd = 'C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\Tools\VsDevCmd.bat'
$ninja = 'C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe'
$buildDir = 'C:\Users\penggang\code\gluten\cpp\build'

Write-Host "Rebuilding gluten.dll and velox.dll..."
Write-Host "Build dir: $buildDir"

# We need to run in cmd.exe with VsDevCmd sourced first to get MSVC in PATH
# Write a temp bat file and run it
$batFile = 'C:\Users\penggang\code\gluten\rebuild_dlls.bat'

@"
@echo off
call "$vsDevCmd" -arch=x64
if errorlevel 1 (
    echo VsDevCmd failed
    exit /b 1
)
cd /d "$buildDir"
"$ninja" -j4 core/gluten.dll velox/velox.dll
exit /b %ERRORLEVEL%
"@ | Set-Content $batFile

$proc = Start-Process `
    -FilePath 'cmd.exe' `
    -ArgumentList '/c', $batFile `
    -RedirectStandardOutput 'C:\Users\penggang\code\gluten\rebuild_stdout.txt' `
    -RedirectStandardError 'C:\Users\penggang\code\gluten\rebuild_stderr.txt' `
    -NoNewWindow `
    -Wait `
    -PassThru

Write-Host "Exit code: $($proc.ExitCode)"
Write-Host "`n=== STDOUT ==="
Get-Content 'C:\Users\penggang\code\gluten\rebuild_stdout.txt'
Write-Host "`n=== STDERR (last 30 lines) ==="
Get-Content 'C:\Users\penggang\code\gluten\rebuild_stderr.txt' | Select-Object -Last 30
