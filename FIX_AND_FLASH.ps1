param(
    [string]$Port = "COM9",
    [switch]$CompileOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Fqbn = "esp32:esp32:esp32s3"
$Esp32Core = "esp32:esp32@3.3.10"
$GfxLibrary = "GFX Library for Arduino@1.6.4"
$EspressifIndex = "https://espressif.github.io/arduino-esp32/package_esp32_index.json"
$BoardOptions = "CDCOnBoot=cdc,FlashSize=16M,PSRAM=opi"
$CanonicalSketchName = "Waveshare_Next_Meeting.ino"

$SafeWorkspace = $null
$SafeSketchRoot = $null
$BuildPath = $null

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
    # ESP32's Windows platform recipes contain cmd.exe IF/ELSE expressions.
    # Parentheses in the sketch path can break those recipes even when quoted.
    # Prefer a user-private path, but reject every candidate containing ( or ).
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
        if ($candidate -match '[()]') {
            continue
        }
        if (Test-WritableDirectory $candidate) {
            return $candidate
        }
    }

    Fail "No se encontro una ruta temporal escribible sin parentesis. Renombra/mueve el proyecto a una ruta sin ( ) o configura TEMP a una ruta simple."
}

function Prepare-SafeSketch([string]$SecretsPath) {
    Write-Step "Preparando copia temporal segura para ESP32 en Windows"

    $script:SafeWorkspace = Get-SafeWorkspaceRoot
    $script:SafeSketchRoot = Join-Path $script:SafeWorkspace "Waveshare_Next_Meeting"
    $script:BuildPath = Join-Path $script:SafeWorkspace "build"

    # Eliminate stale source/binaries before every build.
    if (Test-Path $script:SafeSketchRoot) {
        Remove-Item -LiteralPath $script:SafeSketchRoot -Recurse -Force
    }
    if (Test-Path $script:BuildPath) {
        Remove-Item -LiteralPath $script:BuildPath -Recurse -Force
    }

    New-Item -ItemType Directory -Force -Path $script:SafeSketchRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $script:BuildPath | Out-Null

    $sourceSketch = Join-Path $Root $CanonicalSketchName
    $legacySketch = Join-Path $Root "Calendar_Countdown.ino"
    $targetSketch = Join-Path $script:SafeSketchRoot $CanonicalSketchName

    if (Test-Path $sourceSketch) {
        Copy-Item -LiteralPath $sourceSketch -Destination $targetSketch -Force
    }
    elseif (Test-Path $legacySketch) {
        Copy-Item -LiteralPath $legacySketch -Destination $targetSketch -Force
    }
    else {
        Fail "No se encontro $CanonicalSketchName ni Calendar_Countdown.ino en $Root"
    }

    # Copy auxiliary sketch source files. The canonical/legacy .ino is handled above.
    $sourceExtensions = @('.h', '.hpp', '.c', '.cpp', '.S', '.s')
    Get-ChildItem -LiteralPath $Root -File | Where-Object {
        $sourceExtensions -contains $_.Extension -and
        $_.Name -ne 'secrets.h' -and
        $_.Name -ne 'secrets.example.h'
    } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $script:SafeSketchRoot $_.Name) -Force
    }

    # secrets.h is intentionally copied only into the temporary build source and
    # is removed in finally{} after success or failure.
    Copy-Item -LiteralPath $SecretsPath -Destination (Join-Path $script:SafeSketchRoot "secrets.h") -Force

    if ($script:SafeSketchRoot -match '[()]' -or $script:BuildPath -match '[()]') {
        Fail "Error interno: la ruta temporal segura todavia contiene parentesis."
    }

    Write-Host "Proyecto original : $Root" -ForegroundColor DarkGray
    Write-Host "Sketch temporal   : $script:SafeSketchRoot" -ForegroundColor Green
    Write-Host "Build temporal    : $script:BuildPath" -ForegroundColor Green
}

try {
    Write-Step "Validando credenciales locales"
    $Secrets = Join-Path $Root "secrets.h"
    $SecretsExample = Join-Path $Root "secrets.example.h"

    if (-not (Test-Path $Secrets)) {
        if (-not (Test-Path $SecretsExample)) {
            Fail "No existe secrets.example.h"
        }
        Copy-Item $SecretsExample $Secrets
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

    Write-Step "Localizando Arduino CLI"

    $cmd = Get-Command arduino-cli -ErrorAction SilentlyContinue
    if ($cmd) {
        $script:ArduinoCli = $cmd.Source
        Write-Host "Usando Arduino CLI existente: $script:ArduinoCli" -ForegroundColor Green
    }
    else {
        $ToolDir = Join-Path $Root ".tools\arduino-cli"
        $script:ArduinoCli = Join-Path $ToolDir "arduino-cli.exe"

        if (-not (Test-Path $script:ArduinoCli)) {
            Write-Host "Arduino CLI no esta instalado en PATH. Instalando copia portable oficial..." -ForegroundColor Yellow
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
                if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue }
            }
        }

        if (-not (Test-Path $script:ArduinoCli)) {
            Fail "No se pudo instalar arduino-cli.exe en $ToolDir"
        }
        Write-Host "Arduino CLI portable listo: $script:ArduinoCli" -ForegroundColor Green
    }

    Run-Cli @("version")

    Write-Step "Actualizando indices oficiales"
    Run-Cli @("core", "update-index", "--additional-urls", $EspressifIndex)
    Run-Cli @("lib", "update-index")

    Write-Step "Instalando ESP32 Arduino Core 3.3.10"
    Run-Cli @("core", "install", $Esp32Core, "--additional-urls", $EspressifIndex)

    Write-Step "Instalando GFX Library for Arduino 1.6.4"
    Run-Cli @("lib", "install", $GfxLibrary)

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
        "--warnings", "all",
        $SafeSketchRoot
    )
    Write-Host "COMPILACION CORRECTA." -ForegroundColor Green

    if ($CompileOnly) {
        Write-Host "`nCompileOnly activado: no se realizo carga al dispositivo." -ForegroundColor Yellow
        exit 0
    }

    Write-Step "Comprobando puerto $Port"
    $Ports = [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object
    if ($Ports -notcontains $Port) {
        Write-Host "Puertos detectados: $($Ports -join ', ')" -ForegroundColor Yellow
        Fail "No existe $Port. Conecta la placa o ejecuta: .\FIX_AND_FLASH.ps1 -Port COMx"
    }

    Write-Host "Dispositivos visibles para Arduino CLI:" -ForegroundColor DarkGray
    & $script:ArduinoCli board list

    Write-Step "Subiendo firmware a $Port"
    Run-Cli @(
        "upload",
        "-p", $Port,
        "--fqbn", $Fqbn,
        "--board-options", $BoardOptions,
        "--build-path", $BuildPath,
        $SafeSketchRoot
    )

    Write-Host "`n============================================" -ForegroundColor Green
    Write-Host " EXITO REAL: compilacion y carga completadas " -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
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
    # The staged copy contains secrets.h and build binaries, so remove it even
    # when compilation/upload fails. Never touch the original repository files.
    if ($SafeSketchRoot -and (Test-Path $SafeSketchRoot)) {
        Remove-Item -LiteralPath $SafeSketchRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($BuildPath -and (Test-Path $BuildPath)) {
        Remove-Item -LiteralPath $BuildPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
