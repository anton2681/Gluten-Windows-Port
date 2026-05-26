@echo off
rem Build velox.dll target (gluten-side velox bridge library).
rem Run AFTER build-gluten-windows.ps1 has done a full cmake configure once.
setlocal
if not defined GLUTEN_REPO set GLUTEN_REPO=%~dp0..\..
call "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat" >nul
cd /d %GLUTEN_REPO%\cpp\build
echo === Building velox.dll target ===
cmake --build . --target velox --parallel
echo === Exit code: %ERRORLEVEL% ===
endlocal
