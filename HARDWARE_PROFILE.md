# Hardware profile — Waveshare ESP32-S3-Touch-AMOLED-2.16

This project intentionally targets only the **Waveshare ESP32-S3-Touch-AMOLED-2.16**.

## Expected target

- MCU family: **ESP32-S3**
- Board module: **ESP32-S3R8**
- PSRAM: **8 MB embedded PSRAM**
- Flash: **16 MB**
- USB: **native ESP32-S3 USB** on GPIO19/GPIO20
- Display: CO5300, 480x480, QSPI
- Arduino FQBN: `esp32:esp32:esp32s3`
- Board options used by this repository: `CDCOnBoot=cdc,FlashSize=16M,PSRAM=opi`

## Explicitly incompatible device observed during diagnosis

The following real hardware identification is **not** the Waveshare target:

```text
Windows PnP: USB-SERIAL CH340 (COM10)
esptool: Connected to ESP32 on COM10
Chip type: ESP32-D0WD-V3 (revision v3.1)
Flash observed by diagnostic firmware: ~4 MB
PSRAM: not found in that diagnostic configuration
```

`ESP32-D0WD-V3` is a classic ESP32, not an ESP32-S3. A CH340 serial bridge plus this chip identity must never be treated as an ESP32-S3 target by this repository.

### Important PSRAM clarification

Some classic ESP32 modules can use **external SPI PSRAM**. Therefore the correct diagnosis is **not** “every ESP32-D0WD can never use external RAM.” The actual incompatibility here is broader and decisive:

- the detected silicon family is classic **ESP32**, not **ESP32-S3**;
- this Waveshare target is configured for the S3 board profile with **OPI PSRAM**;
- the Waveshare display uses the S3 board's specific QSPI/display pinout;
- this board uses the ESP32-S3 native USB path, whereas the observed COM10 device is behind a **CH340** bridge;
- the observed device reports approximately **4 MB flash**, while the target board profile is **16 MB flash**.

Do **not** solve this mismatch by changing the FQBN to `esp32:esp32:esp32`, disabling PSRAM, or changing flash size to 4 MB. That would create firmware for different hardware rather than fixing the Waveshare target.

## Safe decision rule

The flasher may continue only when the physical port answers `esptool chip-id` as **ESP32-S3**. Otherwise it must stop before compilation/upload.

The Windows launcher additionally prefers an Espressif native USB device (`VID_303A`) and ignores Bluetooth virtual COM ports and CH340/CH341 bridges for this specific Waveshare board.

## Quick diagnosis

Run:

```text
IDENTIFY_HARDWARE.bat
```

This now combines Windows PnP metadata with `esptool chip-id` and prints, for every relevant COM port:

- the Windows friendly name;
- the PnP device ID when available;
- Bluetooth / CH340 / native Espressif classification;
- the physical Espressif chip model when it responds;
- a final compatible/incompatible decision.

It does **not** compile or flash firmware.

`IDENTIFY_BOARD.bat` remains available as the lower-level `esptool` inventory.

If Windows only shows Bluetooth COM ports plus `USB-SERIAL CH340`, connect the Waveshare through its own USB-C **data** port. If necessary, disconnect it, hold **BOOT**, reconnect USB-C while holding BOOT, then release BOOT. A native Espressif USB/JTAG/serial device should enumerate before this firmware is flashed.

## CI verification

GitHub Actions verifies this hardware guard together with PowerShell syntax, PnP diagnostic rules, native-USB routing, the ESP32-S3-only target, Waveshare's patched GFX library, and a real firmware compilation.
