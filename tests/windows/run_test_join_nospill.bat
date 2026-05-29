@echo off
setlocal
if not defined JAVA_HOME set JAVA_HOME=C:\PROGRA~1\Java\jdk-11
if not defined GLUTEN_REPO set GLUTEN_REPO=%~dp0..\..
set GLUTEN_JAR_PATH=%GLUTEN_REPO%\package\target\gluten-velox-bundle-spark3.5_2.12-windows_amd64-1.7.0-SNAPSHOT.jar
set GLUTEN_JAR_URL=file:///%GLUTEN_JAR_PATH:\=/%
set GLUTEN_JAR_FS=%GLUTEN_JAR_PATH:\=/%
set PATH=%JAVA_HOME%\bin;%PATH%
set SPARK_SCALA_VERSION=2.12
set SPARK_HOME=
set PYSPARK_SUBMIT_ARGS=--jars %GLUTEN_JAR_URL% --conf spark.driver.extraClassPath=%GLUTEN_JAR_FS% --conf spark.executor.extraClassPath=%GLUTEN_JAR_FS% pyspark-shell
python "%~dp0test_join_nospill.py"
exit /b %ERRORLEVEL%
