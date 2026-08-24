param(
    [string]$Port = "AUTO",
    [int]$BootWaitSeconds = 45
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Flasher = Join-Path $Root "FIX_AND_FLASH.ps1"

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Fail([string]$Message, [int]$Code = 1) {
    Write-Host "`n============================================" -ForegroundColor Red
    Write-Host " ERROR USB / BOOT WAVESHARE " -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red
    Write-Host $Message -ForegroundColor Red
    exit $Code
}

function Get-PortInventory {
    $items = @()

    try {
        $pnp = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object {
            $_.Name -match '\(COM\d+\)'
        })

        foreach ($dev in $pnp) {
            $m = [regex]::Match([string]$dev.Name, '\((COM\d+)\)')
            if (-not $m.Success) { continue }

            $items += [pscustomobject]@{
                Port = $m.Groups[1].Value.ToUpperInvariant()
                FriendlyName = [string]$dev.Name
                PnpDeviceId = [string]$dev.PNPDeviceID
                IsBluetooth = (([string]$dev.Name) -match '(?i)Bluetooth') -or (([string]$dev.PNPDeviceID) -match '(?i)^BTH')
                IsEspressifNativeUsb = (([string]$dev.PNPDeviceID) -match '(?i)VID_303A')
                IsCh340 = (([string]$dev.Name) -match '(?i)CH340|CH341') -or (([string]$dev.PNPDeviceID) -match '(?i)VID_1A86')
            }
        }
    }
    catch {
        # Fallback: .NET gives COM names but not VID/PID metadata.
        foreach ($p in @([System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object)) {
            $items += [pscustomobject]@{
                Port = $p.ToUpperInvariant()
                FriendlyName = "$p (metadata PnP no disponible)"
                PnpDeviceId = ""
                IsBluetooth = $false
                IsEspressifNativeUsb = $false
                IsCh340 = $false
            }
        }
    }

    return @($items | Sort-Object Port -Unique)
}

function Show-PortInventory([object[]]$Inventory) {
    Write-Host "Puertos presentes en Windows:" -ForegroundColor DarkGray

    if ($Inventory.Count -eq 0) {
        Write-Host "  (ninguno)" -ForegroundColor Yellow
        return
    }

    foreach ($item in $Inventory) {
        $tag = ""
        $color = "DarkGray"

        if ($item.IsBluetooth) {
            $tag = " [Bluetooth - ignorado]"
            $color = "DarkGray"
        }
        elseif ($item.IsCh340) {
            $tag = " [CH340 - NO es el USB nativo de este Waveshare]"
            $color = "Yellow"
        }
        elseif ($item.IsEspressifNativeUsb) {
            $tag = " [USB nativo Espressif - candidato]"
            $color = "Green"
        }

        Write-Host ("  {0,-6} {1}{2}" -f $item.Port, $item.FriendlyName, $tag) -ForegroundColor $color
        if ($item.PnpDeviceId) {
            Write-Host ("         {0}" -f $item.PnpDeviceId) -ForegroundColor DarkGray
        }
    }
}

function Get-NativeCandidates([object[]]$Inventory) {
    return @($Inventory | Where-Object {
        -not $_.IsBluetooth -and $_.IsEspressifNativeUsb
    })
}

function Invoke-Flasher([string]$ResolvedPort) {
    if (-not (Test-Path -LiteralPath $Flasher)) {
        Fail "No existe FIX_AND_FLASH.ps1 en $Root"
    }

    Write-Step "USB nativo detectado; verificacion final ESP32-S3 + compilacion + carga"
    Write-Host "Puerto candidato: $ResolvedPort" -ForegroundColor Green

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Flasher -Port $ResolvedPort
    $code = $LASTEXITCODE
    exit $code
}

if ($Port -and $Port.ToUpperInvariant() -ne "AUTO") {
    # An explicit port is still checked by FIX_AND_FLASH.ps1 with esptool.
    Invoke-Flasher -ResolvedPort $Port.ToUpperInvariant()
}

Write-Step "Pre-diagnostico USB del Waveshare ESP32-S3"
Write-Host "Objetivo de hardware: Waveshare ESP32-S3-Touch-AMOLED-2.16" -ForegroundColor Cyan
Write-Host "Este modelo programa por USB-C nativo del ESP32-S3; no usa CH340 como interfaz onboard." -ForegroundColor DarkGray

$Inventory = @(Get-PortInventory)
Show-PortInventory -Inventory $Inventory
$Candidates = @(Get-NativeCandidates -Inventory $Inventory)

if ($Candidates.Count -eq 1) {
    Invoke-Flasher -ResolvedPort $Candidates[0].Port
}
elseif ($Candidates.Count -gt 1) {
    Fail "Windows muestra varios dispositivos USB nativos Espressif: $($Candidates.Port -join ', '). Desconecta otros ESP32-S2/S3/C3/C6 o ejecuta RUN_FIX_AND_FLASH.bat COMx."
}

Write-Host "`nNo aparece aun el USB nativo Espressif del Waveshare." -ForegroundColor Yellow
Write-Host "COM con Bluetooth se ignoran. Un USB-SERIAL CH340 que responde como ESP32-D0WD-V3 es un ESP32 clasico y NO es esta placa ESP32-S3." -ForegroundColor Yellow
Write-Host "`nProcedimiento BOOT oficial de Waveshare:" -ForegroundColor Cyan
Write-Host "  1. Usa el puerto USB-C de la placa y un cable USB DE DATOS." -ForegroundColor White
Write-Host "  2. Desconecta el USB-C del Waveshare." -ForegroundColor White
Write-Host "  3. Mantén presionado BOOT." -ForegroundColor White
Write-Host "  4. Sin soltar BOOT, conecta el USB-C al PC." -ForegroundColor White
Write-Host "  5. Suelta BOOT." -ForegroundColor White
Write-Host "`nEsperando hasta $BootWaitSeconds segundos a que aparezca el USB nativo ESP32-S3..." -ForegroundColor Cyan

$deadline = (Get-Date).AddSeconds([Math]::Max(5, $BootWaitSeconds))
$lastSignature = ""

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 750
    $Inventory = @(Get-PortInventory)
    $Candidates = @(Get-NativeCandidates -Inventory $Inventory)

    if ($Candidates.Count -eq 1) {
        Write-Host "`nDetectado tras entrar en BOOT mode:" -ForegroundColor Green
        Show-PortInventory -Inventory $Inventory
        Invoke-Flasher -ResolvedPort $Candidates[0].Port
    }

    if ($Candidates.Count -gt 1) {
        Show-PortInventory -Inventory $Inventory
        Fail "Aparecieron varios USB nativos Espressif: $($Candidates.Port -join ', '). Deja conectado solo el Waveshare objetivo."
    }

    $signature = (($Inventory | ForEach-Object { "$($_.Port)|$($_.PnpDeviceId)" }) -join ';')
    if ($signature -ne $lastSignature) {
        $lastSignature = $signature
    }
}

$Inventory = @(Get-PortInventory)
Write-Host "`nInventario final despues de esperar:" -ForegroundColor Yellow
Show-PortInventory -Inventory $Inventory

Fail @"
Windows nunca enumero el USB nativo Espressif del Waveshare ESP32-S3.

Esto ya no es un error de compilacion: el firmware compila correctamente. Revisa la conexion fisica:
- usa el USB-C de la placa Waveshare (USB nativo en GPIO19/GPIO20),
- prueba otro cable USB-C que sepas que transmite datos,
- conecta directo a otro puerto USB del PC (sin hub),
- repite BOOT mantenido mientras conectas el cable y sueltalo despues,
- si la placa esta apagada, usa PWR segun corresponda.

Cuando Windows muestre un nuevo COM asociado a Espressif/USB JTAG/Serial (normalmente VID_303A), vuelve a ejecutar PULL_AND_FLASH.bat.
"@ 3
