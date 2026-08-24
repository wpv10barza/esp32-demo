param(
    [string]$Port = "AUTO",
    [switch]$CompileOnly
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

    [pscustomobject]@{
        Port = $CandidatePort
        Chip = $Chip
        ExitCode = $ProbeExitCode
        Output = $ProbeOutput.Trim()
    }
}

function Resolve-Esp32S3Port([string]$RequestedPort) {
    Write-Step "Detectando automaticamente el Waveshare ESP32-S3"

    $Ports = @([System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object)
    if ($Ports.Count -eq 0) {
        Fail "No se detectaron puertos COM. Conecta el Waveshare por USB y vuelve a ejecutar."
    }

    Write-Host "Puertos seriales detectados: $($Ports -join ', ')" -ForegroundColor DarkGray
    Write-Host "Dispositivos visibles para Arduino CLI:" -ForegroundColor DarkGray
    & $script:ArduinoCli board list

    $Esptool = Find-Esptool
    Write-Host "Identificador de chip: $Esptool" -ForegroundColor DarkGray

    if ($RequestedPort -and $RequestedPort.ToUpperInvariant() -ne "AUTO") {
        $ExplicitPort = $RequestedPort.ToUpperInvariant()
        if ($Ports -notcontains $ExplicitPort) {
            Fail "No existe $ExplicitPort. Puertos detectados: $($Ports -join ', ')"
        }

        Write-Host "Probando puerto solicitado $ExplicitPort..." -ForegroundColor Cyan
        $Probe = Probe-EspChip -EsptoolPath $Esptool -CandidatePort $ExplicitPort
        Write-Host ("  {0} -> {1}" -f $Probe.Port, $Probe.Chip) -ForegroundColor $(if ($Probe.Chip -eq "ESP32-S3") { "Green" } else { "Yellow" })

        if ($Probe.Chip -ne "ESP32-S3") {
            Fail "$ExplicitPort no es un ESP32-S3; se detecto '$($Probe.Chip)'. No se intentara flashear un chip equivocado. Usa -Port AUTO o conecta el Waveshare."
        }

        return $ExplicitPort
    }

    $Matches = @()
    foreach ($CandidatePort in $Ports) {
        Write-Host "Probando $CandidatePort..." -ForegroundColor DarkGray
        $Probe = Probe-EspChip -EsptoolPath $Esptool -CandidatePort $CandidatePort

        if ($Probe.Chip -eq "ESP32-S3") {
            Write-Host "  $CandidatePort -> ESP32-S3  [WAVESHARE CANDIDATO]" -ForegroundColor Green
            $Matches += $CandidatePort
        }
        elseif ($Probe.Chip -eq "NO_RESPONSE") {
            Write-Host "  $CandidatePort -> sin respuesta Espressif" -ForegroundColor DarkGray
        }
        else {
            Write-Host "  $CandidatePort -> $($Probe.Chip)  [ignorado]" -ForegroundColor Yellow
        }
    }

    if ($Matches.Count -eq 1) {
        Write-Host "Puerto ESP32-S3 seleccionado automaticamente: $($Matches[0])" -ForegroundColor Green
        return $Matches[0]
    }

    if ($Matches.Count -gt 1) {
        Fail "Se detectaron varios ESP32-S3: $($Matches -join ', '). Ejecuta .\FIX_AND_FLASH.ps1 -Port COMx para elegir uno."
    }

    Fail "No se detecto ningun ESP32-S3. COM9 anteriormente respondio como ESP32 clasico. Desconecta otras placas ESP, conecta el Waveshare ESP32-S3 por USB y vuelve a ejecutar."
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

    Ensure-ArduinoCli

    Write-Step "Actualizando indices oficiales"
    Run-Cli @("core", "update-index", "--additional-urls", $EspressifIndex)
    Run-Cli @("lib", "update-index")

    Write-Step "Instalando ESP32 Arduino Core 3.3.11"
    Run-Cli @("core", "install", $Esp32Core, "--additional-urls", $EspressifIndex)

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

    $ResolvedPort = Resolve-Esp32S3Port -RequestedPort $Port

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