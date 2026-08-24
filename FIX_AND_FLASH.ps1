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
    $FolderName = Split-Path $Root -Leaf
    $ExpectedSketch = Join-Path $Root ($FolderName + ".ino")
    $LegacySketch = Join-Path $Root "Calendar_Countdown.ino"

    if (-not (Test-Path $ExpectedSketch)) {
        if (Test-Path $LegacySketch) {
            Move-Item -Path $LegacySketch -Destination $ExpectedSketch
            Write-Host "Renombrado: Calendar_Countdown.ino -> $FolderName.ino" -ForegroundColor Green
        }
        else {
            Fail "No se encontro el sketch principal: $ExpectedSketch"
        }
    }

    Write-Host "Sketch principal: $ExpectedSketch" -ForegroundColor Green

    Write-Step "Compilando para Waveshare ESP32-S3"
    Run-Cli @(
        "compile",
        "--fqbn", $Fqbn,
        "--board-options", $BoardOptions,
        "--warnings", "all",
        $Root
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
        $Root
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
