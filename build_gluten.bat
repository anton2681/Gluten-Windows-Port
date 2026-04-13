@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
cd /d C:\Users\penggang\code\gluten\cpp\build
ninja -j4 gluten
echo NINJA_EXIT=%ERRORLEVEL%
