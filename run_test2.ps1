$env:JAVA_HOME = 'C:\Program Files\Eclipse Adoptium\jdk-21.0.10.7-hotspot'
$env:SPARK_HOME = 'C:\tools\spark'
$env:PATH = 'C:\Program Files\Eclipse Adoptium\jdk-21.0.10.7-hotspot\bin;C:\tools\spark\bin;' + $env:PATH

$JAR1 = 'C:\Users\penggang\code\gluten\package\target\gluten-package-1.7.0-SNAPSHOT.jar'
$JAR2 = 'C:\Users\penggang\code\gluten\package\target\gluten-velox-bundle-spark3.5_2.12-windows_amd64-1.7.0-SNAPSHOT.jar'
$TEST = 'C:\Users\penggang\code\gluten\test_gluten.py'
$OUT  = 'C:\Users\penggang\code\gluten\test_output.txt'
$ERR  = 'C:\Users\penggang\code\gluten\test_err.txt'

Write-Host 'Launching spark-submit...'

$proc = Start-Process `
    -FilePath 'C:\tools\spark\bin\spark-submit.cmd' `
    -ArgumentList @(
        '--master', 'local[2]',
        '--driver-class-path', "$JAR1;$JAR2",
        '--conf', "spark.executor.extraClassPath=$JAR1;$JAR2",
        '--conf', 'spark.plugins=org.apache.gluten.GlutenPlugin',
        '--conf', 'spark.gluten.sql.enable.native.validation=false',
        '--conf', 'spark.memory.offHeap.enabled=true',
        '--conf', 'spark.memory.offHeap.size=1g',
        '--conf', 'spark.sql.session.timeZone=UTC',
        $TEST
    ) `
    -RedirectStandardOutput $OUT `
    -RedirectStandardError $ERR `
    -NoNewWindow `
    -Wait `
    -PassThru

Write-Host "Exit code: $($proc.ExitCode)"
Write-Host "`n=== STDOUT ==="
Get-Content $OUT
Write-Host "`n=== STDERR (last 50 lines) ==="
Get-Content $ERR | Select-Object -Last 50
