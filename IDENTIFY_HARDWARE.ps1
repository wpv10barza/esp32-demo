param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Find-Esptool {
    $roots = @()
    if ($env:LOCALAPPDATA) {
        $roots += (Join-Path $env:LOCALAPPDATA "Arduino15\packages\esp32\tools\esptool_py")
    }
    if ($env:USERPROFILE) {
        $roots += (Join-Path $env:USERPROFILE ".arduino15\packages\esp32\tools\esptool_py")
    }

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory | Sort-Object LastWriteTime -Descending)) {
            $exe = Join-Path $dir.FullName "esptool.exe"
            if (Test-Path -LiteralPath $exe) { return $exe }
        }
    }

    throw "No se encontro esptool.exe. Ejecuta primero PULL_AND_FLASH.bat o instala el core ESP32 3.3.11."
}

function Get-PnpPortMap {
    $map = @{}

    try {
        $devices = @(Get-CimInstance Win32_PnPEntity | Where-Object { [string]$_.Name -match '\(COM\d+\)' })
        foreach ($dev in $devices) {
            $match = [regex]::Match([string]$dev.Name, '\((COM\d+)\)')
            if (-not $match.Success) { continue }

            $port = $match.Groups[1].Value.ToUpperInvariant()
            $name = [string]$dev.Name
            $id = [string]$dev.PNPDeviceID

            $map[$port] = [pscustomobject]@{
                FriendlyName = $name
                PnpDeviceId = $id
                IsBluetooth = ($name -match '(?i)Bluetooth') -or ($id -match '(?i)^BTH')
                IsCh340 = ($name -match '(?i)CH340|CH341') -or ($id -match '(?i)VID_1A86')
                IsEspressifNative = ($id -match '(?i)VID_303A')
            }
        }
    }
    catch {
        Write-Host "Aviso: no se pudo leer metadata PnP completa; se continuara con los nombres COM." -ForegroundColor Yellow
    }

    return $map
}

function Probe-Chip([string]$Esptool, [string]$Port) {
    $output = ""
    $exitCode = -1
    $oldPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = "Continue"
        $output = (& $Esptool "--port" $Port "--connect-attempts" "1" "--after" "hard-reset" "chip-id" 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
    }
    catch {
        $output = $_.Exception.Message
        $exitCode = -1
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    $family = "NO_RESPONSE"
    if ($output -match '(?i)ESP32-S3') { $family = "ESP32-S3" }
    elseif ($output -match '(?i)ESP32-S2') { $family = "ESP32-S2" }
    elseif ($output -match '(?i)ESP32-C3') { $family = "ESP32-C3" }
    elseif ($output -match '(?i)ESP32-C5') { $family = "ESP32-C5" }
    elseif ($output -match '(?i)ESP32-C6') { $family = "ESP32-C6" }
    elseif ($output -match '(?i)ESP32-H2') { $family = "ESP32-H2" }
    elseif ($output -match '(?i)ESP32-P4') { $family = "ESP32-P4" }
    elseif ($output -match '(?i)\bESP32\b') { $family = "ESP32" }

    $model = $family
    if ($output -match '(?im)^Chip type:\s*(.+)$') {
        $model = $Matches[1].Trim()
    }

    return [pscustomobject]@{
        Family = $family
        Model = $model
        ExitCode = $exitCode
        Raw = $output.Trim()
    }
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " WAVESHARE ESP32-S3 - HARDWARE DIAGNOSTIC " -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Objetivo: ESP32-S3 / ESP32-S3R8 / 16 MB flash / 8 MB PSRAM / USB nativo" -ForegroundColor White
Write-Host "Modo seguro: este script NO compila y NO escribe firmware." -ForegroundColor Green

$ports = @([System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object)
if ($ports.Count -eq 0) {
    Write-Host "`nNo hay puertos COM presentes." -ForegroundColor Yellow
    exit 0
}

$pnpMap = Get-PnpPortMap
$esptool = Find-Esptool

Write-Step "Inventario PnP + identificacion fisica con esptool"
Write-Host "esptool: $esptool" -ForegroundColor DarkGray

$foundS3 = @()
$foundClassic = @()

foreach ($port in $ports) {
    $meta = $null
    if ($pnpMap.ContainsKey($port)) { $meta = $pnpMap[$port] }

    $friendly = if ($meta) { $meta.FriendlyName } else { "$port (sin metadata PnP)" }
    $pnpId = if ($meta) { $meta.PnpDeviceId } else { "" }

    Write-Host "`n$port" -ForegroundColor White
    Write-Host "  Windows : $friendly" -ForegroundColor DarkGray
    if ($pnpId) { Write-Host "  PnP ID  : $pnpId" -ForegroundColor DarkGray }

    if ($meta -and $meta.IsBluetooth) {
        Write-Host "  Estado  : BLUETOOTH VIRTUAL COM - ignorado" -ForegroundColor DarkGray
        continue
    }

    Write-Host "  Probe   : ejecutando chip-id..." -ForegroundColor DarkGray
    $probe = Probe-Chip -Esptool $esptool -Port $port

    if ($probe.Family -eq "NO_RESPONSE") {
        if ($meta -and $meta.IsCh340) {
            Write-Host "  Chip    : sin respuesta Espressif" -ForegroundColor Yellow
            Write-Host "  Estado  : CH340 presente, pero ningun chip Espressif respondio" -ForegroundColor Yellow
        }
        else {
            Write-Host "  Chip    : sin respuesta Espressif" -ForegroundColor DarkGray
            Write-Host "  Estado  : no es un objetivo identificable en este momento" -ForegroundColor DarkGray
        }
        continue
    }

    Write-Host "  Chip    : $($probe.Model)" -ForegroundColor $(if ($probe.Family -eq 'ESP32-S3') { 'Green' } else { 'Yellow' })

    if ($probe.Family -eq "ESP32-S3") {
        $usbTag = if ($meta -and $meta.IsEspressifNative) { "USB nativo Espressif VID_303A" } else { "ESP32-S3 verificado por esptool" }
        Write-Host "  Estado  : COMPATIBLE CANDIDATO - $usbTag" -ForegroundColor Green
        $foundS3 += $port
    }
    else {
        $bridge = if ($meta -and $meta.IsCh340) { "CH340 + " } else { "" }
        Write-Host "  Estado  : INCOMPATIBLE - ${bridge}$($probe.Family) no es ESP32-S3" -ForegroundColor Yellow
        if ($probe.Model -match '(?i)ESP32-D0WD') {
            $foundClassic += $port
            Write-Host "  Nota    : ESP32-D0WD es ESP32 clasico. Algunos modulos clasicos pueden usar SPI PSRAM," -ForegroundColor Yellow
            Write-Host "            pero no sustituyen el hardware S3/OPI/USB nativo/pinout de esta pantalla." -ForegroundColor Yellow
        }
    }
}

Write-Step "Resultado"
if ($foundS3.Count -eq 1) {
    Write-Host "ESP32-S3 compatible detectado en $($foundS3[0])." -ForegroundColor Green
    Write-Host "Puedes ejecutar .\PULL_AND_FLASH.bat para compilar y cargar con verificacion adicional." -ForegroundColor Green
}
elseif ($foundS3.Count -gt 1) {
    Write-Host "Hay varios ESP32-S3: $($foundS3 -join ', '). Deja conectado solo el Waveshare objetivo." -ForegroundColor Yellow
}
else {
    Write-Host "No hay ningun ESP32-S3 detectado actualmente." -ForegroundColor Yellow
    if ($foundClassic.Count -gt 0) {
        Write-Host "El ESP32 clasico detectado en $($foundClassic -join ', ') NO debe recibir este firmware." -ForegroundColor Yellow
    }
    Write-Host "Conecta el USB-C DE DATOS del Waveshare. Si no aparece, manten BOOT presionado mientras reconectas USB-C y luego suelta BOOT." -ForegroundColor Cyan
}

Write-Host "`nDiagnostico finalizado. No se escribio firmware." -ForegroundColor Green
exit 0
