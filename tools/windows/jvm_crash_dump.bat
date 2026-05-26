@echo off
rem Wrapper invoked by JVM `-XX:OnError=...` when a fatal native crash happens.
rem Arg %1 is the JVM PID.
rem Configure via env vars: PROCDUMP_EXE, JVM_DUMP_DIR.
if not defined PROCDUMP_EXE set PROCDUMP_EXE=C:\tools\procdump\procdump64.exe
if not defined JVM_DUMP_DIR set JVM_DUMP_DIR=C:\tmp\dumps
if not exist "%JVM_DUMP_DIR%" mkdir "%JVM_DUMP_DIR%"
"%PROCDUMP_EXE%" -accepteula -ma %1 "%JVM_DUMP_DIR%"
