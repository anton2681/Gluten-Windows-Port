@echo off
rem ============================================================================
rem Smoke test runner for the Gluten Windows port.
rem
rem Prerequisites:
rem  - JDK 11 at %JAVA_HOME% (or update JAVA_HOME below)
rem  - PySpark 3.5.3 installed: pip install pyspark==3.5.3
rem  - mvn package has produced the bundle jar (see tools/windows/SETUP.md)
rem  - update_jars.ps1 has injected velox.dll + gluten.dll into the bundle
rem  - Minimal tzdata.zi at %VELOX_TZDATA_PATH% (or default C:\tools\velox-tzdata)
rem ============================================================================
setlocal

rem ---- User-configurable paths ----
if not defined JAVA_HOME set JAVA_HOME=C:\PROGRA~1\Java\jdk-11
if not defined GLUTEN_REPO set GLUTEN_REPO=%~dp0..\..
set GLUTEN_JAR_PATH=%GLUTEN_REPO%\package\target\gluten-velox-bundle-spark3.5_2.12-windows_amd64-1.7.0-SNAPSHOT.jar
rem Forward slashes for spark/hadoop URI parser
set GLUTEN_JAR_URL=file:///%GLUTEN_JAR_PATH:\=/%
set GLUTEN_JAR_FS=%GLUTEN_JAR_PATH:\=/%

set PATH=%JAVA_HOME%\bin;%PATH%
set SPARK_SCALA_VERSION=2.12
set SPARK_HOME=

set PYSPARK_SUBMIT_ARGS=--jars %GLUTEN_JAR_URL% --conf spark.driver.extraClassPath=%GLUTEN_JAR_FS% --conf spark.executor.extraClassPath=%GLUTEN_JAR_FS% pyspark-shell

python "%~dp0test_gluten.py"
exit /b %ERRORLEVEL%
