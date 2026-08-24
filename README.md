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

Connect the Waveshare board by its USB-C data port and run:

```text
RUN_FIX_AND_FLASH.bat
```

The Waveshare ESP32-S3-Touch-AMOLED-2.16 uses the **native USB interface of the ESP32-S3**, not a CH340 onboard USB-to-serial bridge. The Windows launcher first runs `WAVESHARE_USB_BOOT.ps1`, which:

- inventories Windows COM/PnP devices;
- ignores Bluetooth virtual COM ports;
- labels CH340/CH341 ports as non-target interfaces for this specific board;
- looks for Espressif native USB devices (`VID_303A`);
- if no native USB device is visible, prints the official Waveshare BOOT reconnect sequence and waits up to 45 seconds for the board to enumerate;
- only after a native USB candidate appears does it call `FIX_AND_FLASH.ps1`;
- `FIX_AND_FLASH.ps1` then independently verifies the selected port with `esptool chip-id` and refuses to flash unless the chip is **ESP32-S3**.

A port such as `USB-SERIAL CH340` that identifies as `ESP32-D0WD-V3` is an ESP32 classic and is **not** the Waveshare ESP32-S3 target.

### If Windows does not show the Waveshare

Use Waveshare's USB BOOT procedure:

1. Use a USB-C cable that supports **data**, not charging only.
2. Disconnect the board USB-C from the PC.
3. Hold the **BOOT** button.
4. While holding BOOT, connect the USB-C cable to the PC.
5. Release BOOT.
6. Leave `RUN_FIX_AND_FLASH.bat` running; it scans for the new native USB device for 45 seconds.

If it still does not enumerate, try a known-good data cable and a different direct USB port on the PC without a hub.

## Build environment

The PowerShell automation:

- uses an existing `arduino-cli`, or downloads a portable official copy into `.tools/`;
- uses Espressif's official package index;
- pins ESP32 Arduino Core `3.3.11`;
- downloads and verifies Waveshare's patched `GFX Library for Arduino 1.6.4` from pinned upstream revision `225a62b`;
- forces that exact GFX library with Arduino CLI `--library`;
- builds from a safe temporary path without parentheses;
- compiles for `esp32:esp32:esp32s3`;
- uses `CDCOnBoot=cdc,FlashSize=16M,PSRAM=opi`;
- stops on the first real error;
- removes the temporary sketch containing `secrets.h` after success or failure.

The globally installed Arduino libraries are not modified.

To force a specific port:

```text
RUN_FIX_AND_FLASH.bat COM12
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

It performs `git pull --ff-only` first and then runs the native-USB/BOOT preflight and ESP32-S3 verified upload.

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
