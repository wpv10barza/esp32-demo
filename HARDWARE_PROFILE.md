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
PSRAM: not found
```

`ESP32-D0WD-V3` is a classic ESP32. A CH340 serial bridge plus this chip identity must never be treated as an ESP32-S3 target by this repository.

Do **not** solve this mismatch by changing the FQBN to `esp32:esp32:esp32`, disabling PSRAM, or changing flash size to 4 MB. The application uses the pinout and display interface of the Waveshare ESP32-S3 board and would then be targeting different hardware.

## Safe decision rule

The flasher may continue only when the physical port answers `esptool chip-id` as **ESP32-S3**. Otherwise it must stop before compilation/upload.

The Windows launcher additionally prefers an Espressif native USB device (`VID_303A`) and ignores Bluetooth virtual COM ports and CH340/CH341 bridges for this specific Waveshare board.

## Quick diagnosis

Run:

```text
IDENTIFY_HARDWARE.bat
```

or:

```text
IDENTIFY_BOARD.bat
```

Neither command flashes firmware.

If Windows only shows Bluetooth COM ports plus `USB-SERIAL CH340`, connect the Waveshare through its own USB-C **data** port. If necessary, disconnect it, hold **BOOT**, reconnect USB-C while holding BOOT, then release BOOT. A native Espressif USB/JTAG/serial device should enumerate before this firmware is flashed.

## CI verification

GitHub Actions verifies this hardware guard together with PowerShell syntax, native-USB routing, the ESP32-S3-only target, Waveshare's patched GFX library, and a real firmware compilation before this verification change is merged.
