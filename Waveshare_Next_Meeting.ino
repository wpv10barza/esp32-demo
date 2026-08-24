#include <Arduino.h>

#if !CONFIG_IDF_TARGET_ESP32S3
#error "WAVESHARE_HARDWARE_GUARD: this firmware requires ESP32-S3; ESP32-D0WD-V3/classic ESP32 is not supported"
#endif

#include <WiFi.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include "Arduino_GFX_Library.h"

// Local credentials live in secrets.h. That file is intentionally ignored by Git.
#include "secrets.h"

const char* WIFI_SSID = WIFI_SSID_VALUE;
const char* WIFI_PASSWORD = WIFI_PASSWORD_VALUE;
const char* CALENDAR_URL = CALENDAR_URL_VALUE;

// Waveshare ESP32-S3-Touch-AMOLED-2.16 official display pins
#define LCD_SDIO0 4
#define LCD_SDIO1 5
#define LCD_SDIO2 6
#define LCD_SDIO3 7
#define LCD_SCLK 38
#define LCD_RESET 39
#define LCD_CS 12
#define LCD_WIDTH 480
#define LCD_HEIGHT 480

constexpr uint32_t REQUIRED_FLASH_BYTES = 16UL * 1024UL * 1024UL;

bool validateWaveshareHardware() {
  const char *chipModel = ESP.getChipModel();
  const uint32_t flashBytes = ESP.getFlashChipSize();
  const bool hasPsram = psramFound() && ESP.getPsramSize() > 0;

  Serial.println("\n====================================");
  Serial.println(" WAVESHARE ESP32-S3 HARDWARE GUARD");
  Serial.println("====================================");
  Serial.printf("Chip Model: %s\n", chipModel);
  Serial.printf("Chip Revision: %u\n", ESP.getChipRevision());
  Serial.printf("CPU Frequency: %u MHz\n", ESP.getCpuFreqMHz());
  Serial.printf("Flash Chip Size: %lu Bytes (~%lu MB)\n",
                static_cast<unsigned long>(flashBytes),
                static_cast<unsigned long>(flashBytes / (1024UL * 1024UL)));
  Serial.printf("PSRAM Size: %lu Bytes\n",
                static_cast<unsigned long>(ESP.getPsramSize()));

  bool compatible = true;
  if (strcmp(chipModel, "ESP32-S3") != 0) {
    Serial.println("[X] Chip incompatible: ESP32-S3 requerido.");
    compatible = false;
  }
  if (flashBytes < REQUIRED_FLASH_BYTES) {
    Serial.println("[X] Flash insuficiente: se requieren 16 MB.");
    compatible = false;
  }
  if (!hasPsram) {
    Serial.println("[X] PSRAM no disponible: configure PSRAM=opi y use el hardware Waveshare correcto.");
    compatible = false;
  }

  if (compatible) {
    Serial.println("[OK] Hardware Waveshare ESP32-S3 compatible.");
  } else {
    Serial.println("[STOP] No se inicializara QSPI, AMOLED, Wi-Fi ni calendario.");
  }
  Serial.println("====================================");
  return compatible;
}

Arduino_DataBus *bus = new Arduino_ESP32QSPI(
  LCD_CS, LCD_SCLK, LCD_SDIO0, LCD_SDIO1, LCD_SDIO2, LCD_SDIO3);

Arduino_CO5300 *gfx = new Arduino_CO5300(
  bus, LCD_RESET, 0, LCD_WIDTH, LCD_HEIGHT, 0, 0, 0, 0);

String meetingTitle = "Connecting...";
String meetingStartText = "";
int64_t serverEpoch = 0;
int64_t meetingEpoch = 0;
uint32_t syncMillis = 0;
uint32_t lastFetchMillis = 0;
bool haveMeeting = false;
bool fetchFailed = false;

const uint32_t FETCH_EVERY_MS = 5UL * 60UL * 1000UL;

void centerText(const String &text, int y, int size, uint16_t color) {
  gfx->setTextSize(size);
  gfx->setTextColor(color);
  int16_t x = (LCD_WIDTH - (int)text.length() * 6 * size) / 2;
  if (x < 8) x = 8;
  gfx->setCursor(x, y);
  gfx->print(text);
}

void drawWrappedTitle(const String &text) {
  const int size = 3;
  const int maxChars = 24;
  String remaining = text;
  int y = 118;
  int lines = 0;

  while (remaining.length() > 0 && lines < 3) {
    String line;
    if ((int)remaining.length() <= maxChars) {
      line = remaining;
      remaining = "";
    } else {
      int cut = maxChars;
      while (cut > 8 && remaining.charAt(cut) != ' ') cut--;
      if (cut <= 8) cut = maxChars;
      line = remaining.substring(0, cut);
      remaining = remaining.substring(cut);
      remaining.trim();
    }
    centerText(line, y, size, RGB565_WHITE);
    y += 35;
    lines++;
  }
}

void drawStaticScreen() {
  gfx->fillScreen(RGB565_BLACK);

  centerText("NEXT MEETING", 42, 2, RGB565_CYAN);
  gfx->drawLine(64, 78, 416, 78, RGB565_DARKGREY);

  drawWrappedTitle(meetingTitle);

  if (meetingStartText.length()) {
    centerText(meetingStartText, 232, 2, RGB565_LIGHTGREY);
  }

  gfx->drawLine(64, 278, 416, 278, RGB565_DARKGREY);
  centerText("STARTS IN", 306, 2, RGB565_LIGHTGREY);
}

void drawCountdown() {
  // Clear only countdown/status region to minimize flicker.
  gfx->fillRect(20, 342, 440, 120, RGB565_BLACK);

  if (!haveMeeting) {
    centerText(fetchFailed ? "Calendar unavailable" : "No upcoming meetings", 380, 2,
               fetchFailed ? RGB565_RED : RGB565_LIGHTGREY);
    return;
  }

  int64_t nowEpoch = serverEpoch + ((uint32_t)(millis() - syncMillis) / 1000ULL);
  int64_t left = meetingEpoch - nowEpoch;

  if (left <= 0) {
    centerText("STARTING NOW", 375, 3, RGB565_GREEN);
    if (millis() - lastFetchMillis > 15000) lastFetchMillis = 0; // force refresh soon
    return;
  }

  uint64_t hours = left / 3600;
  uint8_t minutes = (left % 3600) / 60;
  uint8_t seconds = left % 60;

  char countdown[24];
  snprintf(countdown, sizeof(countdown), "%02llu:%02u:%02u",
           (unsigned long long)hours, minutes, seconds);

  centerText(String(countdown), 365, 5, RGB565_WHITE);
}

bool parseResponse(const String &body) {
  // Payload format:
  // OK\n<serverEpoch>\n<meetingEpoch>\n<title>\n<start text>
  int p1 = body.indexOf('\n');
  if (p1 < 0) return false;
  String status = body.substring(0, p1);
  status.trim();

  if (status == "NONE") {
    haveMeeting = false;
    fetchFailed = false;
    serverEpoch = 0;
    meetingEpoch = 0;
    meetingTitle = "No upcoming meetings";
    meetingStartText = "";
    return true;
  }

  if (status != "OK") return false;

  int p2 = body.indexOf('\n', p1 + 1);
  int p3 = body.indexOf('\n', p2 + 1);
  int p4 = body.indexOf('\n', p3 + 1);
  if (p2 < 0 || p3 < 0 || p4 < 0) return false;

  serverEpoch = body.substring(p1 + 1, p2).toInt();
  meetingEpoch = body.substring(p2 + 1, p3).toInt();
  meetingTitle = body.substring(p3 + 1, p4);
  meetingStartText = body.substring(p4 + 1);
  meetingTitle.trim();
  meetingStartText.trim();

  syncMillis = millis();
  haveMeeting = true;
  fetchFailed = false;
  return true;
}

bool fetchCalendar() {
  if (WiFi.status() != WL_CONNECTED) return false;

  WiFiClientSecure client;
  client.setInsecure(); // simplest setup; HTTPS is still encrypted but cert is not pinned

  HTTPClient https;
  https.setFollowRedirects(HTTPC_STRICT_FOLLOW_REDIRECTS);
  https.setTimeout(10000);

  if (!https.begin(client, CALENDAR_URL)) return false;

  int code = https.GET();
  if (code != HTTP_CODE_OK) {
    https.end();
    return false;
  }

  String body = https.getString();
  https.end();
  return parseResponse(body);
}

void connectWiFi() {
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  gfx->fillScreen(RGB565_BLACK);
  centerText("Connecting to Wi-Fi", 205, 2, RGB565_WHITE);

  uint32_t started = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - started < 20000) {
    delay(250);
  }
}

void setup() {
  Serial.begin(115200);
  delay(250);

  if (!validateWaveshareHardware()) {
    while (true) delay(1000);
  }

  if (!gfx->begin()) {
    Serial.println("Display init failed");
  }
  bus->writeC8D8(0x36, 0xA0);
  gfx->fillScreen(RGB565_BLACK);
  gfx->setBrightness(90);

  connectWiFi();

  if (WiFi.status() == WL_CONNECTED && fetchCalendar()) {
    lastFetchMillis = millis();
  } else {
    fetchFailed = true;
    meetingTitle = "Calendar unavailable";
    lastFetchMillis = millis();
  }

  drawStaticScreen();
  drawCountdown();
}

void loop() {
  static uint32_t lastSecond = 0;

  if (millis() - lastSecond >= 1000) {
    lastSecond = millis();
    drawCountdown();
  }

  if (lastFetchMillis == 0 || millis() - lastFetchMillis >= FETCH_EVERY_MS) {
    lastFetchMillis = millis();

    if (WiFi.status() != WL_CONNECTED) {
      WiFi.disconnect();
      WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
      uint32_t start = millis();
      while (WiFi.status() != WL_CONNECTED && millis() - start < 10000) delay(250);
    }

    if (fetchCalendar()) {
      drawStaticScreen();
      drawCountdown();
    } else {
      fetchFailed = true;
    }
  }

  delay(10);
}
