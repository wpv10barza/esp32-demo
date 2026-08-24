# Waveshare Next Meeting

Minimal Google Calendar countdown for **Waveshare ESP32-S3-Touch-AMOLED-2.16 (480×480)**.

The ESP32 displays the next timed event from Google Calendar and a live `HH:MM:SS` countdown.

## Architecture

`Google Calendar → Apps Script Web App → HTTPS → ESP32-S3 → AMOLED`

This deliberately keeps Google OAuth off the microcontroller.

## Security-first repository layout

Credentials are **not committed**.

1. Copy `secrets.example.h` to `secrets.h`.
2. Edit only `secrets.h`:

```cpp
#define WIFI_SSID_VALUE "YOUR_WIFI_NAME"
#define WIFI_PASSWORD_VALUE "YOUR_WIFI_PASSWORD"
#define CALENDAR_URL_VALUE "YOUR_GOOGLE_APPS_SCRIPT_EXEC_URL"
```

`secrets.h` is excluded by `.gitignore`, so future `git pull` operations do not overwrite or publish the local credentials.

## Fastest Windows workflow

Connect the Waveshare board by USB and run:

```text
RUN_FIX_AND_FLASH.bat
```

The default serial-port mode is now **AUTO**. Before flashing, the script safely probes all visible COM ports with Espressif `esptool chip-id`, selects the single port that identifies itself as **ESP32-S3**, and refuses to flash ESP32, ESP32-C3, or other chips by mistake.

The PowerShell automation:

- uses an existing `arduino-cli`, or downloads a portable official copy into `.tools/`;
- uses Espressif's official package index;
- pins ESP32 Arduino Core `3.3.11`, matching Waveshare's current Arduino CI;
- downloads and verifies Waveshare's patched `GFX Library for Arduino 1.6.4` from pinned upstream revision `225a62b`;
- forces that exact GFX library with Arduino CLI `--library`, so an older Library Manager copy cannot win dependency resolution;
- builds from a safe temporary path without parentheses, avoiding ESP32 Windows `cmd.exe` recipe failures;
- compiles for `esp32:esp32:esp32s3`;
- uses `CDCOnBoot=cdc,FlashSize=16M,PSRAM=opi`;
- auto-detects the real ESP32-S3 serial port before upload;
- refuses to flash a port that identifies as another ESP32 family chip;
- stops on the first real error;
- uploads only after a successful compile;
- removes the temporary sketch containing `secrets.h` after success or failure.

The globally installed Arduino libraries are not modified.

To force a specific port instead of AUTO:

```powershell
.\FIX_AND_FLASH.ps1 -Port COM8
```

The explicit port is still verified as an ESP32-S3 before flashing.

Compile without uploading:

```powershell
.\FIX_AND_FLASH.ps1 -CompileOnly
```

## One-click updates after GitHub is linked

Run:

```text
PULL_AND_FLASH.bat
```

It performs `git pull --ff-only` first and only flashes if the update succeeded.

## Google Apps Script

1. Create a project at Google Apps Script.
2. Replace its code with `Code.gs`.
3. Set project timezone to `America/Lima` if appropriate.
4. Deploy as **Web app**.
5. Execute as: **Me**.
6. Access: **Anyone**.
7. Authorize Google Calendar.
8. Copy the deployment URL ending in `/exec` into local `secrets.h`.

Treat the `/exec` URL as private because the endpoint returns the next event title and start time.

## Display pins

The sketch follows the Waveshare board wiring used by its Arduino example:

- QSPI SDIO0: GPIO 4
- QSPI SDIO1: GPIO 5
- QSPI SDIO2: GPIO 6
- QSPI SDIO3: GPIO 7
- LCD SCLK: GPIO 38
- LCD RESET: GPIO 39
- LCD CS: GPIO 12
- Resolution: 480×480

## Repository

Remote: `https://github.com/wpv10barza/esp32-demo.git`

For a clean Windows clone:

```powershell
git clone https://github.com/wpv10barza/esp32-demo.git
```
