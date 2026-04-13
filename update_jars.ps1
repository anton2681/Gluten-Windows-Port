$jar1 = 'C:\Users\penggang\code\gluten\package\target\gluten-package-1.7.0-SNAPSHOT.jar'
$jar2 = 'C:\Users\penggang\code\gluten\package\target\gluten-velox-bundle-spark3.5_2.12-windows_amd64-1.7.0-SNAPSHOT.jar'
$newGluten = 'C:\Users\penggang\code\gluten\cpp\build\core\gluten.dll'
$newVelox = 'C:\Users\penggang\code\gluten\cpp\build\velox\velox.dll'
$javahome = 'C:\Program Files\Eclipse Adoptium\jdk-21.0.10.7-hotspot'
$jarCmd = "$javahome\bin\jar.exe"
$tmpDir = 'C:\Users\penggang\code\gluten\jar_tmp'

function Update-Jar {
    param($jarPath, $glutenPath, $veloxPath)
    Write-Host "Updating $jarPath ..."

    # Clean and recreate temp dir
    if (Test-Path $tmpDir) { Remove-Item -Recurse -Force $tmpDir }
    New-Item -ItemType Directory -Path $tmpDir | Out-Null

    # Extract the JAR
    Push-Location $tmpDir
    & $jarCmd xf $jarPath
    $extractResult = $LASTEXITCODE
    Pop-Location

    if ($extractResult -ne 0) {
        Write-Host "ERROR: Failed to extract JAR"
        return
    }

    # Update DLLs
    if (Test-Path "$tmpDir\windows\amd64\gluten.dll") {
        Copy-Item $glutenPath "$tmpDir\windows\amd64\gluten.dll" -Force
        Write-Host "  Updated windows/amd64/gluten.dll"
    }
    if (Test-Path "$tmpDir\windows\amd64\velox.dll") {
        Copy-Item $veloxPath "$tmpDir\windows\amd64\velox.dll" -Force
        Write-Host "  Updated windows/amd64/velox.dll"
    }
    if (Test-Path "$tmpDir\velox.dll") {
        Copy-Item $veloxPath "$tmpDir\velox.dll" -Force
        Write-Host "  Updated top-level velox.dll"
    }

    # Repack the JAR
    $backupPath = $jarPath + ".bak"
    Copy-Item $jarPath $backupPath -Force
    Write-Host "  Backed up to $backupPath"

    Push-Location $tmpDir
    # Get all files/dirs for jar creation
    $items = Get-ChildItem -Name | Where-Object { $_ -ne "" }
    & $jarCmd cf $jarPath $items
    $packResult = $LASTEXITCODE
    Pop-Location

    if ($packResult -ne 0) {
        Write-Host "ERROR: Failed to repack JAR"
        Copy-Item $backupPath $jarPath -Force
    } else {
        Write-Host "  Successfully repacked $jarPath"
        Write-Host "  New size: $((Get-Item $jarPath).Length) bytes"
    }

    # Cleanup
    Remove-Item -Recurse -Force $tmpDir
}

Update-Jar $jar1 $newGluten $newVelox
Update-Jar $jar2 $newGluten $newVelox
