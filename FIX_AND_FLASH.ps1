param(
    [string]$Port = "AUTO",
    [switch]$CompileOnly,
    [switch]$IdentifyOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Fqbn = "esp32:esp32:esp32s3"
$Esp32Core = "esp32:esp32@3.3.11"
$EspressifIndex = "https://espressif.github.io/arduino-esp32/package_esp32_index.json"
$BoardOptions = "CDCOnBoot=cdc,FlashSize=16M,PSRAM=opi"
$CanonicalSketchName = "Waveshare_Next_Meeting.ino"

# Waveshare's repository carries a patched GFX 1.6.4 that is newer than the
# Library Manager copy with the same version number. Pin the exact upstream
# revision currently used by Waveshare so builds are reproducible.
$WaveshareCommit = "225a62bff11b5d0a0b607873860d39485a9a9685"
$WaveshareArchiveUrl = "https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-2.16/archive/$WaveshareCommit.zip"

$SafeWorkspace = $null
$SafeSketchRoot = $null
$BuildPath = $null
$VendorGfxRoot = $null
$ResolvedPort = $null

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Fail([string]$Message) {
    throw $Message
}

function Run-Cli([string[]]$CliArgs) {
    Write-Host ("    arduino-cli " + ($CliArgs -join " ")) -ForegroundColor DarkGray
    & $script:ArduinoCli @CliArgs
    if ($LASTEXITCODE -ne 0) {
        Fail "arduino-cli termino con codigo $LASTEXITCODE al ejecutar: $($CliArgs -join ' ')"
    }
}

function Test-WritableDirectory([string]$Path) {
    try {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
        $probe = Join-Path $Path (".write-test-" + [guid]::NewGuid().ToString("N"))
        Set-Content -LiteralPath $probe -Value "ok" -Encoding ASCII
        Remove-Item -LiteralPath $probe -Force
        return $true
    }
    catch {
        return $false
    }
}

function Get-SafeWorkspaceRoot {
    # ESP32 Windows recipes invoke cmd.exe internally. Parentheses in paths can
    # break IF/ELSE recipes even when the caller quotes the sketch path.
    $candidates = @()

    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA "WaveshareBuild")
    }
    if ($env:TEMP) {
        $candidates += (Join-Path $env:TEMP "WaveshareBuild")
    }
    if ($env:SystemDrive) {
        $candidates += (Join-Path $env:SystemDrive "WaveshareBuild")
    }

    foreach ($candidate in $candidates) {
        if ($candidate -match '[()]') { continue }
        if (Test-WritableDirectory $candidate) { return $candidate }
    }

    Fail "No se encontro una ruta temporal escribible sin parentesis."
}

function Ensure-ArduinoCli {
    Write-Step "Localizando Arduino CLI"

    $cmd = Get-Command arduino-cli -ErrorAction SilentlyContinue
    if ($cmd) {
        $script:ArduinoCli = $cmd.Source
        Write-Host "Usando Arduino CLI existente: $script:ArduinoCli" -ForegroundColor Green
        Run-Cli @("version")
        return
    }

    $ToolDir = Join-Path $Root ".tools\arduino-cli"
    $script:ArduinoCli = Join-Path $ToolDir "arduino-cli.exe"

    if (-not (Test-Path $script:ArduinoCli)) {
        Write-Host "Arduino CLI no esta en PATH. Instalando copia portable oficial..." -ForegroundColor Yellow
        New-Item -ItemType Directory -Force -Path $ToolDir | Out-Null

        if ([Environment]::Is64BitOperatingSystem) {
            $CliUrl = "https://downloads.arduino.cc/arduino-cli/arduino-cli_latest_Windows_64bit.zip"
        }
        else {
            $CliUrl = "https://downloads.arduino.cc/arduino-cli/arduino-cli_latest_Windows_32bit.zip"
        }

        $ZipPath = Join-Path $env:TEMP ("arduino-cli-" + [guid]::NewGuid().ToString("N") + ".zip")
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $CliUrl -OutFile $ZipPath
            Expand-Archive -Path $ZipPath -DestinationPath $ToolDir -Force
        }
        finally {
            if (Test-Path $ZipPath) {
                Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if (-not (Test-Path $script:ArduinoCli)) {
        Fail "No se pudo instalar arduino-cli.exe en $ToolDir"
    }

    Write-Host "Arduino CLI portable listo: $script:ArduinoCli" -ForegroundColor Green
    Run-Cli @("version")
}

function Find-Esptool {
    $SearchRoots = @()

    if ($env:LOCALAPPDATA) {
        $SearchRoots += (Join-Path $env:LOCALAPPDATA "Arduino15\packages\esp32\tools\esptool_py")
    }
    if ($env:USERPROFILE) {
        $SearchRoots += (Join-Path $env:USERPROFILE ".arduino15\packages\esp32\tools\esptool_py")
    }

    foreach ($SearchRoot in $SearchRoots) {
        if (-not (Test-Path $SearchRoot)) { continue }

        $VersionDirs = Get-ChildItem -LiteralPath $SearchRoot -Directory | Sort-Object LastWriteTime -Descending
        foreach ($VersionDir in $VersionDirs) {
            $Exe = Join-Path $VersionDir.FullName "esptool.exe"
            if (Test-Path $Exe) {
                return $Exe
            }
        }
    }

    Fail "No se encontro esptool.exe instalado por ESP32 Arduino Core."
}

function Probe-EspChip([string]$EsptoolPath, [string]$CandidatePort) {
    $ProbeOutput = ""
    $ProbeExitCode = -1
    $PreviousPreference = $ErrorActionPreference

    try {
        # A failed probe is expected for non-Espressif serial devices, so capture
        # its output instead of treating it as a PowerShell exception.
        $ErrorActionPreference = "Continue"
        $ProbeOutput = (& $EsptoolPath "--port" $CandidatePort "--connect-attempts" "1" "--after" "hard-reset" "chip-id" 2>&1 | Out-String)
        $ProbeExitCode = $LASTEXITCODE
    }
    catch {
        $ProbeOutput = $_.Exception.Message
        $ProbeExitCode = -1
    }
    finally {
        $ErrorActionPreference = $PreviousPreference
    }

    $Chip = "NO_RESPONSE"
    if ($ProbeOutput -match '(?i)ESP32-S3') { $Chip = "ESP32-S3" }
    elseif ($ProbeOutput -match '(?i)ESP32-S2') { $Chip = "ESP32-S2" }
    elseif ($ProbeOutput -match '(?i)ESP32-C3') { $Chip = "ESP32-C3" }
    elseif ($ProbeOutput -match '(?i)ESP32-C5') { $Chip = "ESP32-C5" }
    elseif ($ProbeOutput -match '(?i)ESP32-C6') { $Chip = "ESP32-C6" }
    elseif ($ProbeOutput -match '(?i)ESP32-H2') { $Chip = "ESP32-H2" }
    elseif ($ProbeOutput -match '(?i)ESP32-P4') { $Chip = "ESP32-P4" }
    elseif ($ProbeOutput -match '(?i)\bESP32\b') { $Chip = "ESP32" }

    $ChipModel = $Chip
    if ($ProbeOutput -match '(?im)^Chip type:\s*(.+)$') {
        $ChipModel = $Matches[1].Trim()
    }

    [pscustomobject]@{
        Port = $CandidatePort
        Chip = $Chip
        ChipModel = $ChipModel
        ExitCode = $ProbeExitCode
        Output = $ProbeOutput.Trim()
    }
}

function Get-EspDeviceInventory {
    Write-Step "Identificando chips Espressif conectados"

    $Ports = @([System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object)
    if ($Ports.Count -eq 0) {
        Fail "No se detectaron puertos COM. Conecta el Waveshare por USB y vuelve a ejecutar."
    }

    Write-Host "Puertos seriales detectados: $($Ports -join ', ')" -ForegroundColor DarkGray
    Write-Host "Dispositivos visibles para Arduino CLI:" -ForegroundColor DarkGray
    & $script:ArduinoCli board list | Out-Host

    $Esptool = Find-Esptool
    Write-Host "Identificador de chip: $Esptool" -ForegroundColor DarkGray

    $Inventory = @()
    foreach ($CandidatePort in $Ports) {
        Write-Host "Probando $CandidatePort..." -ForegroundColor DarkGray
        $Inventory += Probe-EspChip -EsptoolPath $Esptool -CandidatePort $CandidatePort
    }

    return $Inventory
}

function Write-EspDeviceInventory([object[]]$Inventory) {
    foreach ($Probe in $Inventory) {
        if ($Probe.Chip -eq "ESP32-S3") {
            Write-Host "  $($Probe.Port) -> $($Probe.ChipModel)  [WAVESHARE S3 CANDIDATO]" -ForegroundColor Green
        }
        elseif ($Probe.Chip -eq "NO_RESPONSE") {
            Write-Host "  $($Probe.Port) -> sin respuesta Espressif" -ForegroundColor DarkGray
        }
        else {
            Write-Host "  $($Probe.Port) -> $($Probe.ChipModel)  [INCOMPATIBLE CON ESTE FIRMWARE]" -ForegroundColor Yellow
        }
    }
}

function Show-EspDeviceInventory {
    $Inventory = @(Get-EspDeviceInventory)
    Write-EspDeviceInventory -Inventory $Inventory

    $EspressifDevices = @($Inventory | Where-Object { $_.Chip -ne "NO_RESPONSE" })
    if ($EspressifDevices.Count -eq 0) {
        Write-Host "No respondio ningun chip Espressif. No se realizo ninguna carga." -ForegroundColor Yellow
        return
    }

    $S3Devices = @($EspressifDevices | Where-Object { $_.Chip -eq "ESP32-S3" })
    if ($S3Devices.Count -eq 0) {
        Write-Host "No hay un ESP32-S3 conectado. Los equipos mostrados no son compatibles con la pantalla Waveshare 2.16." -ForegroundColor Yellow
    }
    else {
        Write-Host "Se detectaron $($S3Devices.Count) dispositivo(s) ESP32-S3 compatible(s)." -ForegroundColor Green
    }
}

function Resolve-Esp32S3Port([string]$RequestedPort) {
    Write-Step "Preflight: validando el Waveshare ESP32-S3 antes de compilar"
    $Inventory = @(Get-EspDeviceInventory)
    Write-EspDeviceInventory -Inventory $Inventory

    if ($RequestedPort -and $RequestedPort.ToUpperInvariant() -ne "AUTO") {
        $ExplicitPort = $RequestedPort.ToUpperInvariant()
        $Probe = $Inventory | Where-Object { $_.Port -eq $ExplicitPort } | Select-Object -First 1
        if (-not $Probe) {
            $DetectedPorts = @($Inventory | ForEach-Object { $_.Port })
            Fail "No existe $ExplicitPort. Puertos detectados: $($DetectedPorts -join ', ')"
        }

        if ($Probe.Chip -ne "ESP32-S3") {
            Fail "$ExplicitPort no es un ESP32-S3; se detecto '$($Probe.ChipModel)'. El firmware AMOLED usa QSPI, PSRAM y pines exclusivos del modelo S3. No se compilara ni flasheara una imagen incompatible."
        }

        return $ExplicitPort
    }

    $Matches = @($Inventory | Where-Object { $_.Chip -eq "ESP32-S3" })

    if ($Matches.Count -eq 1) {
        Write-Host "Puerto ESP32-S3 seleccionado automaticamente: $($Matches[0].Port)" -ForegroundColor Green
        return $Matches[0].Port
    }

    if ($Matches.Count -gt 1) {
        $MatchPorts = @($Matches | ForEach-Object { $_.Port })
        Fail "Se detectaron varios ESP32-S3: $($MatchPorts -join ', '). Ejecuta .\FIX_AND_FLASH.ps1 -Port COMx para elegir uno."
    }

    $OtherDevices = @($Inventory | Where-Object { $_.Chip -ne "NO_RESPONSE" } | ForEach-Object { "$($_.Port)=$($_.ChipModel)" })
    $DetectedSummary = if ($OtherDevices.Count) { $OtherDevices -join ", " } else { "ningun chip Espressif" }
    Fail "No se detecto ningun ESP32-S3. Detectado: $DetectedSummary. Un ESP32-D0WD-V3 es ESP32 clasico y no puede ejecutar el firmware de la pantalla Waveshare ESP32-S3-Touch-AMOLED-2.16. No se realizo ninguna carga."
}

function Test-WaveshareGfxPatch([string]$GfxRoot) {
    $SpiFile = Join-Path $GfxRoot "src\databus\Arduino_ESP32SPI.cpp"
    $QspiFile = Join-Path $GfxRoot "src\databus\Arduino_ESP32QSPI.cpp"
    $Props = Join-Path $GfxRoot "library.properties"

    if (-not (Test-Path $SpiFile) -or -not (Test-Path $QspiFile) -or -not (Test-Path $Props)) {
        return $false
    }

    $SpiText = Get-Content -LiteralPath $SpiFile -Raw
    $PropsText = Get-Content -LiteralPath $Props -Raw

    return (
        $SpiText.Contains("gfxSpiFrequencyToClockDiv") -and
        $SpiText.Contains("spiFrequencyToClockDiv(spi, freq)") -and
        $PropsText.Contains("version=1.6.4")
    )
}

function Ensure-WavesharePatchedGfx {
    Write-Step "Preparando GFX oficial parcheada por Waveshare"

    if (-not $script:SafeWorkspace) {
        $script:SafeWorkspace = Get-SafeWorkspaceRoot
    }

    $VendorRoot = Join-Path $script:SafeWorkspace ("vendor\" + $WaveshareCommit)
    $script:VendorGfxRoot = Join-Path $VendorRoot "GFX_Library_for_Arduino"

    if (Test-WaveshareGfxPatch $script:VendorGfxRoot) {
        Write-Host "GFX Waveshare cacheada y verificada: $script:VendorGfxRoot" -ForegroundColor Green
        return
    }

    if (Test-Path $VendorRoot) {
        Remove-Item -LiteralPath $VendorRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $VendorRoot | Out-Null

    $DownloadZip = Join-Path $script:SafeWorkspace ("waveshare-" + [guid]::NewGuid().ToString("N") + ".zip")
    $ExtractRoot = Join-Path $script:SafeWorkspace ("waveshare-extract-" + [guid]::NewGuid().ToString("N"))

    try {
        Write-Host "Descargando revision oficial Waveshare $WaveshareCommit..." -ForegroundColor DarkGray
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $WaveshareArchiveUrl -OutFile $DownloadZip

        New-Item -ItemType Directory -Force -Path $ExtractRoot | Out-Null
        Expand-Archive -LiteralPath $DownloadZip -DestinationPath $ExtractRoot -Force

        $RepoRoot = Get-ChildItem -LiteralPath $ExtractRoot -Directory | Select-Object -First 1
        if (-not $RepoRoot) {
            Fail "El ZIP oficial de Waveshare no contiene una carpeta raiz valida."
        }

        $SourceGfx = Join-Path $RepoRoot.FullName "examples\arduino\libraries\GFX_Library_for_Arduino"
        if (-not (Test-WaveshareGfxPatch $SourceGfx)) {
            Fail "La copia GFX descargada de Waveshare no contiene el parche esperado para ESP32 >= 3.3.0."
        }

        Copy-Item -LiteralPath $SourceGfx -Destination $script:VendorGfxRoot -Recurse -Force

        if (-not (Test-WaveshareGfxPatch $script:VendorGfxRoot)) {
            Fail "No se pudo validar la copia GFX vendorizada despues de copiarla."
        }
    }
    finally {
        if (Test-Path $DownloadZip) {
            Remove-Item -LiteralPath $DownloadZip -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $ExtractRoot) {
            Remove-Item -LiteralPath $ExtractRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "GFX Waveshare lista: $script:VendorGfxRoot" -ForegroundColor Green
    Write-Host "La GFX global de Documents\Arduino NO sera modificada." -ForegroundColor DarkGray
}

function Prepare-SafeSketch([string]$SecretsPath) {
    Write-Step "Preparando copia temporal segura para ESP32 en Windows"

    if (-not $script:SafeWorkspace) {
        $script:SafeWorkspace = Get-SafeWorkspaceRoot
    }

    $script:SafeSketchRoot = Join-Path $script:SafeWorkspace "Waveshare_Next_Meeting"
    $script:BuildPath = Join-Path $script:SafeWorkspace "build"

    if (Test-Path $script:SafeSketchRoot) {
        Remove-Item -LiteralPath $script:SafeSketchRoot -Recurse -Force
    }
    if (Test-Path $script:BuildPath) {
        Remove-Item -LiteralPath $script:BuildPath -Recurse -Force
    }

    New-Item -ItemType Directory -Force -Path $script:SafeSketchRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $script:BuildPath | Out-Null

    $SourceSketch = Join-Path $Root $CanonicalSketchName
    $LegacySketch = Join-Path $Root "Calendar_Countdown.ino"
    $TargetSketch = Join-Path $script:SafeSketchRoot $CanonicalSketchName

    if (Test-Path $SourceSketch) {
        Copy-Item -LiteralPath $SourceSketch -Destination $TargetSketch -Force
    }
    elseif (Test-Path $LegacySketch) {
        Copy-Item -LiteralPath $LegacySketch -Destination $TargetSketch -Force
    }
    else {
        Fail "No se encontro $CanonicalSketchName ni Calendar_Countdown.ino en $Root"
    }

    $SourceExtensions = @('.h', '.hpp', '.c', '.cpp', '.S', '.s')
    Get-ChildItem -LiteralPath $Root -File | Where-Object {
        $SourceExtensions -contains $_.Extension -and
        $_.Name -ne 'secrets.h' -and
        $_.Name -ne 'secrets.example.h'
    } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $script:SafeSketchRoot $_.Name) -Force
    }

    # secrets.h is copied only into the temporary sketch and deleted in finally{}.
    Copy-Item -LiteralPath $SecretsPath -Destination (Join-Path $script:SafeSketchRoot "secrets.h") -Force

    if ($script:SafeSketchRoot -match '[()]' -or $script:BuildPath -match '[()]') {
        Fail "Error interno: la ruta temporal segura contiene parentesis."
    }

    Write-Host "Proyecto original : $Root" -ForegroundColor DarkGray
    Write-Host "Sketch temporal   : $script:SafeSketchRoot" -ForegroundColor Green
    Write-Host "Build temporal    : $script:BuildPath" -ForegroundColor Green
    Write-Host "GFX forzada       : $script:VendorGfxRoot" -ForegroundColor Green
}

try {
    Ensure-ArduinoCli

    Write-Step "Actualizando indices oficiales"
    Run-Cli @("core", "update-index", "--additional-urls", $EspressifIndex)
    Run-Cli @("lib", "update-index")

    Write-Step "Instalando ESP32 Arduino Core 3.3.11"
    Run-Cli @("core", "install", $Esp32Core, "--additional-urls", $EspressifIndex)

    if ($IdentifyOnly) {
        Show-EspDeviceInventory
        Write-Host "`nIdentifyOnly finalizado: no se compilo ni se cargo firmware." -ForegroundColor Green
        exit 0
    }

    if (-not $CompileOnly) {
        # The physical chip is checked before downloading GFX or compiling. This
        # prevents wasting time and, more importantly, prevents an S3 image from
        # ever being sent to a classic ESP32 such as ESP32-D0WD-V3.
        $ResolvedPort = Resolve-Esp32S3Port -RequestedPort $Port
    }

    Write-Step "Validando credenciales locales"
    $Secrets = Join-Path $Root "secrets.h"
    $SecretsExample = Join-Path $Root "secrets.example.h"

    if (-not (Test-Path $Secrets)) {
        if (-not (Test-Path $SecretsExample)) {
            Fail "No existe secrets.example.h"
        }
        Copy-Item -LiteralPath $SecretsExample -Destination $Secrets
        Write-Host "Se creo secrets.h localmente." -ForegroundColor Yellow
        Write-Host "Edita secrets.h con tu Wi-Fi y CALENDAR_URL y vuelve a ejecutar." -ForegroundColor Yellow
        exit 2
    }

    $SecretsText = Get-Content -LiteralPath $Secrets -Raw
    if ($SecretsText.Contains("YOUR_WIFI_NAME") -or
        $SecretsText.Contains("YOUR_WIFI_PASSWORD") -or
        $SecretsText.Contains("YOUR_GOOGLE_APPS_SCRIPT_EXEC_URL")) {
        Write-Host "secrets.h todavia contiene valores de ejemplo." -ForegroundColor Yellow
        Write-Host "Edita SOLO secrets.h; ese archivo esta protegido por .gitignore." -ForegroundColor Yellow
        exit 2
    }

    # Do not install GFX from Library Manager. Waveshare's patched copy has the
    # same 1.6.4 version string but contains ESP32 3.3.x compatibility changes.
    Ensure-WavesharePatchedGfx

    Write-Step "Validando estructura del sketch"
    $CanonicalSketch = Join-Path $Root $CanonicalSketchName
    $LegacySketch = Join-Path $Root "Calendar_Countdown.ino"

    if (-not (Test-Path $CanonicalSketch) -and -not (Test-Path $LegacySketch)) {
        Fail "No se encontro el sketch principal en $Root"
    }

    Write-Host "Sketch principal: $CanonicalSketchName" -ForegroundColor Green

    Prepare-SafeSketch -SecretsPath $Secrets

    Write-Step "Compilando para Waveshare ESP32-S3"
    Run-Cli @(
        "compile",
        "--fqbn", $Fqbn,
        "--board-options", $BoardOptions,
        "--build-path", $BuildPath,
        "--library", $VendorGfxRoot,
        "--clean",
        "--warnings", "all",
        $SafeSketchRoot
    )
    Write-Host "COMPILACION CORRECTA." -ForegroundColor Green

    if ($CompileOnly) {
        Write-Host "`nCompileOnly activado: no se realizo carga al dispositivo." -ForegroundColor Yellow
        exit 0
    }

    Write-Step "Subiendo firmware al ESP32-S3 en $ResolvedPort"
    Run-Cli @(
        "upload",
        "-p", $ResolvedPort,
        "--fqbn", $Fqbn,
        "--board-options", $BoardOptions,
        "--build-path", $BuildPath,
        $SafeSketchRoot
    )

    Write-Host "`n============================================" -ForegroundColor Green
    Write-Host " EXITO REAL: compilacion y carga completadas " -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "ESP32-S3 cargado por: $ResolvedPort" -ForegroundColor Green
    exit 0
}
catch {
    Write-Host "`n============================================" -ForegroundColor Red
    Write-Host " ERROR: el proceso se detuvo correctamente " -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "`nCopia desde 'ERROR' hasta esta linea y envialo para diagnostico." -ForegroundColor Yellow
    exit 1
}
finally {
    # The temporary sketch contains secrets.h. Remove it after success/failure.
    # Keep the verified Waveshare GFX cache to make subsequent builds fast.
    if ($SafeSketchRoot -and (Test-Path $SafeSketchRoot)) {
        Remove-Item -LiteralPath $SafeSketchRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($BuildPath -and (Test-Path $BuildPath)) {
        Remove-Item -LiteralPath $BuildPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
