/*
 * THUNDERSTORM DETECTION SYSTEM
 * For Mountain Guide Safety - Engineering Thesis Part 1
 *
 * Hardware:
 * - ESP32-WROOM-32 DevKit
 * - BME280 sensor (Temperature, Pressure, Humidity)
 *
 * Wiring:
 * BME280 VCC -> ESP32 3V3
 * BME280 GND -> ESP32 GND
 * BME280 SCL -> ESP32 D22
 * BME280 SDA -> ESP32 D21
 *
 * ─── SIMULATION MODE ────────────────────────────────────────────────────────
 * Set SIMULATION_MODE to 1 to use fake sensor data instead of real BME280.
 * The BME280 can remain physically connected in simulation mode — it is simply
 * ignored. This means you can run simulation mode even on a finished, cased
 * device without removing or rewiring anything.
 *
 * Two simulation speeds:
 *   SIMULATION_FAST 0  →  Slow mode: pressure drops gradually over ~30 minutes,
 *                          realistic cycle through all alert levels.
 *   SIMULATION_FAST 1  →  Fast mode: cycles CLEAR → WATCH → WARNING → SEVERE
 *                          every few seconds. Good for testing LEDs and buzzer.
 * ────────────────────────────────────────────────────────────────────────────
 */

// ─── SIMULATION FLAGS — edit these to switch modes ───────────────────────────
#define SIMULATION_MODE  0   // 0 = real sensors,  1 = simulated data
#define SIMULATION_FAST  0   // 0 = slow/realistic, 1 = fast/testing
// ─────────────────────────────────────────────────────────────────────────────

#include <Wire.h>
#include <Adafruit_Sensor.h>
#include <Adafruit_BME280.h> 
#include <BluetoothSerial.h>

#if !defined(CONFIG_BT_ENABLED) || !defined(CONFIG_BLUEDROID_ENABLED)
#error Bluetooth is not enabled! Please run make menuconfig to enable it
#endif

BluetoothSerial SerialBT;

// BME280 is always declared so it can remain physically connected in all modes.
// In simulation mode it is declared but never initialised or read from.
Adafruit_BME280 bme;

// ─── Storm detection parameters ───────────────────────────────────────────────
const int   HISTORY_SIZE             = 36;
float       pressureHistory[HISTORY_SIZE];
int         historyIndex             = 0;
bool        historyFilled            = false;

const float PRESSURE_DROP_THRESHOLD  = 3.0;
const float HUMIDITY_THRESHOLD       = 75.0;
const float RAPID_PRESSURE_DROP      = 1.5;
const float WATCH_PRESSURE_DROP      = 1.8;

// ─── Timing ───────────────────────────────────────────────────────────────────
unsigned long       lastReadTime  = 0;

#if SIMULATION_FAST == 1
const unsigned long READ_INTERVAL = 3000;    // 3 seconds — fast testing
#else
const unsigned long READ_INTERVAL = 300000;  // 5 minutes — normal / slow sim
#endif

// ─── Alert levels ─────────────────────────────────────────────────────────────
enum AlertLevel { CLEAR = 0, WATCH = 1, WARNING = 2, SEVERE = 3 };
AlertLevel currentAlert = CLEAR;

const char* deviceName = "MountainGuide_Weather";

// ─── Simulation state ─────────────────────────────────────────────────────────
#if SIMULATION_MODE == 1

#if SIMULATION_FAST == 1
// Fast mode: manual control — steps through alert levels one by one
int   simStep          = 0;
const int SIM_STEPS    = 4;
#else
// Slow mode: pressure starts high and drops gradually
float simPressure      = 1013.0;
float simHumidity      = 60.0;
float simTemperature   = 18.0;
int   simTickCount     = 0;
#endif

void getSimulatedReadings(float &temperature, float &pressure, float &humidity) {

#if SIMULATION_FAST == 1
  // Fast mode: each call returns values that produce the next alert level
  switch (simStep % SIM_STEPS) {
    case 0:  // CLEAR — stable pressure, low humidity
      pressure    = 1013.0;
      humidity    = 50.0;
      temperature = 18.0;
      break;
    case 1:  // WATCH — moderate drop starting
      pressure    = 1011.0;
      humidity    = 72.0;
      temperature = 17.0;
      break;
    case 2:  // WARNING — significant 3h drop + high humidity
      pressure    = 1009.5;
      humidity    = 78.0;
      temperature = 15.0;
      break;
    case 3:  // SEVERE — rapid 30-min drop + high humidity
      pressure    = 1008.0;
      humidity    = 85.0;
      temperature = 13.0;
      break;
  }
  // Manually override pressure history to force the correct alert level
  // This bypasses the rolling window so transitions happen instantly
  if (simStep % SIM_STEPS == 0) {
    // Reset history to stable for CLEAR
    for (int i = 0; i < HISTORY_SIZE; i++) pressureHistory[i] = 1013.0;
    historyIndex  = 0;
    historyFilled = false;
  } else if (simStep % SIM_STEPS == 1) {
    // WATCH: simulate a 1.9 hPa drop over 3h
    for (int i = 0; i < HISTORY_SIZE; i++) pressureHistory[i] = 1013.0;
    historyFilled = true;
  } else if (simStep % SIM_STEPS == 2) {
    // WARNING: simulate a 3.1 hPa drop over 3h
    for (int i = 0; i < HISTORY_SIZE; i++) pressureHistory[i] = 1012.6;
    historyFilled = true;
  } else if (simStep % SIM_STEPS == 3) {
    // SEVERE: simulate a 1.6 hPa drop over last 30 min
    for (int i = 0; i < HISTORY_SIZE; i++) pressureHistory[i] = 1012.6;
    // Set recent 6 readings (last 30 min) to a higher value
    for (int i = 0; i < 6; i++) {
      int idx = (historyIndex - 6 + i + HISTORY_SIZE) % HISTORY_SIZE;
      pressureHistory[idx] = 1009.6;
    }
    historyFilled = true;
  }
  simStep++;

#else
  // Slow mode: pressure drops naturally over time
  // Phase 1 (ticks 0–5):   stable, CLEAR
  // Phase 2 (ticks 6–15):  humidity rises, WATCH triggered
  // Phase 3 (ticks 16–30): pressure drops steadily, WARNING triggered
  // Phase 4 (ticks 31+):   rapid pressure drop, SEVERE triggered
  if (simTickCount < 6) {
    simPressure   = 1013.0;
    simHumidity   = 55.0 + simTickCount * 1.0;
    simTemperature = 18.0;
  } else if (simTickCount < 16) {
    simPressure   = 1013.0 - (simTickCount - 6) * 0.18;
    simHumidity   = 61.0 + (simTickCount - 6) * 1.5;
    simTemperature = 18.0 - (simTickCount - 6) * 0.1;
  } else if (simTickCount < 31) {
    simPressure   = 1011.2 - (simTickCount - 16) * 0.22;
    simHumidity   = min(simHumidity + 1.0, 92.0);
    simTemperature = 16.5 - (simTickCount - 16) * 0.15;
  } else {
    simPressure   = max(simPressure - 0.5, 990.0);
    simHumidity   = min(simHumidity + 0.5, 95.0);
    simTemperature = max(simTemperature - 0.2, 5.0);
  }
  simTickCount++;
  pressure    = simPressure;
  humidity    = simHumidity;
  temperature = simTemperature;
#endif

}
#endif  // SIMULATION_MODE

// ─── Forward declarations ─────────────────────────────────────────────────────
AlertLevel analyzeWeatherData(float pressure, float humidity, float temperature);
void       sendDataViaBluetooth(float temp, float pressure, float humidity, AlertLevel alert);
void       sendAlertViaBluetooth(AlertLevel alert);
void       handleCommand(String command);
String     getAlertName(AlertLevel alert);
void       printDebugInfo(float temp, float pressure, float humidity, AlertLevel alert);

// ─────────────────────────────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  delay(1000);

  Serial.println("\n╔════════════════════════════════════════════╗");
  Serial.println("║  MOUNTAIN GUIDE WEATHER MONITORING SYSTEM  ║");
  Serial.println("║       Thunderstorm Detection v1.1          ║");
  Serial.println("╚════════════════════════════════════════════╝\n");

#if SIMULATION_MODE == 1
  Serial.println("*** SIMULATION MODE ACTIVE ***");
  #if SIMULATION_FAST == 1
  Serial.println("*** FAST: cycling alert levels every 3 seconds ***\n");
  #else
  Serial.println("*** SLOW: realistic pressure drop over ~30 minutes ***\n");
  #endif
#endif

#if SIMULATION_MODE == 0
  Wire.begin(21, 22);
  Serial.print("Initializing BME280 sensor... ");
  if (!bme.begin(0x76)) {
    Serial.println("FAILED at 0x76, trying 0x77...");
    if (!bme.begin(0x77)) {
      Serial.println("FAILED! Check wiring and restart.");
      while (1) delay(1000);
    }
  }
  Serial.println("✓ SUCCESS");

  bme.setSampling(Adafruit_BME280::MODE_FORCED,
                  Adafruit_BME280::SAMPLING_X1,
                  Adafruit_BME280::SAMPLING_X1,
                  Adafruit_BME280::SAMPLING_X1,
                  Adafruit_BME280::FILTER_OFF);
#endif

  Serial.print("Initializing Bluetooth... ");
  SerialBT.begin(deviceName);
  Serial.println("✓ SUCCESS");
  Serial.print("Device name: ");
  Serial.println(deviceName);
  Serial.println("Waiting for phone connection...");

#if SIMULATION_MODE == 0
  bme.takeForcedMeasurement();
  float initialPressure = bme.readPressure() / 100.0F;
#else
  float initialPressure = 1013.0;
#endif

  for (int i = 0; i < HISTORY_SIZE; i++) pressureHistory[i] = initialPressure;

  Serial.println("\n✓ System initialized successfully!");
  Serial.println("Starting atmospheric monitoring...\n");

  SerialBT.println("SYSTEM:READY");
  SerialBT.print("DEVICE:");
  SerialBT.println(deviceName);
}

// ─────────────────────────────────────────────────────────────────────────────
void loop() {
  unsigned long currentTime = millis();

  if (currentTime - lastReadTime >= READ_INTERVAL || lastReadTime == 0) {
    lastReadTime = currentTime;

    float temperature, pressure, humidity;

#if SIMULATION_MODE == 1
    getSimulatedReadings(temperature, pressure, humidity);
#else
    bme.takeForcedMeasurement();
    temperature = bme.readTemperature();
    pressure    = bme.readPressure() / 100.0F;
    humidity    = bme.readHumidity();

    if (isnan(temperature) || isnan(pressure) || isnan(humidity)) {
      Serial.println("❌ ERROR: Invalid sensor readings!");
      SerialBT.println("ERROR:SENSOR:Invalid readings");
      return;
    }
#endif

    // In fast sim mode, history is managed inside getSimulatedReadings()
    // In all other modes, update history normally
#if !(SIMULATION_MODE == 1 && SIMULATION_FAST == 1)
    pressureHistory[historyIndex] = pressure;
    historyIndex = (historyIndex + 1) % HISTORY_SIZE;
    if (historyIndex == 0) historyFilled = true;
#endif

    AlertLevel newAlert = analyzeWeatherData(pressure, humidity, temperature);
    sendDataViaBluetooth(temperature, pressure, humidity, newAlert);

    if (newAlert != currentAlert) {
      Serial.print("⚠ ALERT LEVEL CHANGED: ");
      Serial.print(getAlertName(currentAlert));
      Serial.print(" → ");
      Serial.println(getAlertName(newAlert));
      currentAlert = newAlert;
      sendAlertViaBluetooth(newAlert);
    }

    printDebugInfo(temperature, pressure, humidity, newAlert);
  }

  if (SerialBT.available()) {
    String command = SerialBT.readStringUntil('\n');
    handleCommand(command);
  }

  delay(100);
}

// ─── Algorithm (unchanged) ────────────────────────────────────────────────────
AlertLevel analyzeWeatherData(float pressure, float humidity, float temperature) {
  if (!historyFilled && historyIndex < 6) return CLEAR;

  int oldestIndex = historyFilled ? historyIndex : 0;
  float pressureDrop3h = pressureHistory[oldestIndex] - pressure;

  int recentStart = historyIndex - 6;
  if (recentStart < 0) recentStart += HISTORY_SIZE;
  if (!historyFilled && historyIndex < 6) recentStart = 0;
  float pressureDrop30min = pressureHistory[recentStart] - pressure;

  AlertLevel alert = CLEAR;

  if (pressureDrop30min >= RAPID_PRESSURE_DROP && humidity >= HUMIDITY_THRESHOLD) {
    alert = SEVERE;
  } else if (pressureDrop3h >= PRESSURE_DROP_THRESHOLD && humidity >= HUMIDITY_THRESHOLD) {
    alert = WARNING;
  } else if (pressureDrop3h >= WATCH_PRESSURE_DROP ||
             (pressureDrop30min >= 1.0 && humidity >= 70.0)) {
    alert = WATCH;
  }

  return alert;
}

// ─── Bluetooth output (unchanged) ────────────────────────────────────────────
void sendDataViaBluetooth(float temp, float pressure, float humidity, AlertLevel alert) {
  float pressureDrop3h    = 0;
  float pressureDrop30min = 0;

  if (historyFilled || historyIndex >= 6) {
    int oldestIndex = historyFilled ? historyIndex : 0;
    pressureDrop3h = pressureHistory[oldestIndex] - pressure;

    int recentStart = historyIndex - 6;
    if (recentStart < 0) recentStart += HISTORY_SIZE;
    if (!historyFilled && historyIndex < 6) recentStart = 0;
    pressureDrop30min = pressureHistory[recentStart] - pressure;
  }

  SerialBT.print("DATA:{");
  SerialBT.print("\"temp\":");        SerialBT.print(temp, 1);
  SerialBT.print(",\"pressure\":");   SerialBT.print(pressure, 1);
  SerialBT.print(",\"humidity\":");   SerialBT.print(humidity, 1);
  SerialBT.print(",\"alert\":");      SerialBT.print(alert);
  SerialBT.print(",\"p_drop_3h\":"); SerialBT.print(pressureDrop3h, 2);
  SerialBT.print(",\"p_drop_30m\":"); SerialBT.print(pressureDrop30min, 2);
  SerialBT.println("}");
}

void sendAlertViaBluetooth(AlertLevel alert) {
  SerialBT.print("ALERT:");
  switch (alert) {
    case CLEAR:   SerialBT.println("CLEAR:Weather conditions stable and safe"); break;
    case WATCH:   SerialBT.println("WATCH:Weather changing - monitor conditions closely"); break;
    case WARNING: SerialBT.println("WARNING:Thunderstorm likely within 1-2 hours - prepare to descend"); break;
    case SEVERE:  SerialBT.println("SEVERE:Thunderstorm imminent - seek shelter immediately!"); break;
  }
}

// ─── Command handler (unchanged) ─────────────────────────────────────────────
void handleCommand(String command) {
  command.trim();

  if (command == "STATUS") {
    float temp, pressure, humidity;
#if SIMULATION_MODE == 1
    getSimulatedReadings(temp, pressure, humidity);
#else
    bme.takeForcedMeasurement();
    temp     = bme.readTemperature();
    pressure = bme.readPressure() / 100.0F;
    humidity = bme.readHumidity();
#endif
    sendDataViaBluetooth(temp, pressure, humidity, currentAlert);
    SerialBT.println("STATUS:OK");
  }
  else if (command == "RESET") {
    currentAlert  = CLEAR;
    historyIndex  = 0;
    historyFilled = false;
#if SIMULATION_MODE == 1
    #if SIMULATION_FAST == 1
    simStep = 0;
    #else
    simPressure     = 1013.0;
    simHumidity     = 60.0;
    simTemperature  = 18.0;
    simTickCount    = 0;
    #endif
    for (int i = 0; i < HISTORY_SIZE; i++) pressureHistory[i] = 1013.0;
#else
    bme.takeForcedMeasurement();
    float currentPressure = bme.readPressure() / 100.0F;
    for (int i = 0; i < HISTORY_SIZE; i++) pressureHistory[i] = currentPressure;
#endif
    SerialBT.println("SYSTEM:RESET_COMPLETE");
    Serial.println("System reset by phone command");
  }
  else if (command == "PING") {
    SerialBT.println("SYSTEM:PONG");
  }
  else if (command == "INFO") {
    SerialBT.print("SYSTEM:VERSION:1.1");
#if SIMULATION_MODE == 1
    SerialBT.print(",MODE:SIMULATION");
    #if SIMULATION_FAST == 1
    SerialBT.print("_FAST");
    #else
    SerialBT.print("_SLOW");
    #endif
#else
    SerialBT.print(",MODE:LIVE");
#endif
    SerialBT.print(",INTERVAL:");
    SerialBT.print(READ_INTERVAL / 1000);
    SerialBT.print("s,HISTORY:");
    SerialBT.print(historyFilled ? HISTORY_SIZE : historyIndex);
    SerialBT.println(" samples");
  }
  else {
    SerialBT.print("ERROR:UNKNOWN_COMMAND:");
    SerialBT.println(command);
  }
}

// ─── Helpers (unchanged) ─────────────────────────────────────────────────────
String getAlertName(AlertLevel alert) {
  switch (alert) {
    case CLEAR:   return "CLEAR";
    case WATCH:   return "WATCH";
    case WARNING: return "WARNING";
    case SEVERE:  return "SEVERE";
    default:      return "UNKNOWN";
  }
}

void printDebugInfo(float temp, float pressure, float humidity, AlertLevel alert) {
  float pressureDrop3h    = 0;
  float pressureDrop30min = 0;

  if (historyFilled || historyIndex >= 6) {
    int oldestIndex = historyFilled ? historyIndex : 0;
    pressureDrop3h = pressureHistory[oldestIndex] - pressure;

    int recentStart = historyIndex - 6;
    if (recentStart < 0) recentStart += HISTORY_SIZE;
    if (!historyFilled && historyIndex < 6) recentStart = 0;
    pressureDrop30min = pressureHistory[recentStart] - pressure;
  }

  Serial.println("════════════════════════════════════════");
#if SIMULATION_MODE == 1
  #if SIMULATION_FAST == 1
  Serial.println("[SIM — FAST MODE]");
  #else
  Serial.println("[SIM — SLOW MODE]");
  #endif
#endif
  Serial.print("📊 Temperature:    "); Serial.print(temp, 1);              Serial.println(" °C");
  Serial.print("📊 Pressure:       "); Serial.print(pressure, 1);          Serial.println(" hPa");
  Serial.print("📊 Humidity:       "); Serial.print(humidity, 1);          Serial.println(" %");
  Serial.println("────────────────────────────────────────");
  Serial.print("📉 3h Drop:        "); Serial.print(pressureDrop3h, 2);    Serial.println(" hPa");
  Serial.print("📉 30min Drop:     "); Serial.print(pressureDrop30min, 2); Serial.println(" hPa");
  Serial.print("📝 History:        ");
  Serial.print(historyFilled ? HISTORY_SIZE : historyIndex);
  Serial.println(" samples");
  Serial.println("────────────────────────────────────────");
  Serial.print("⚠️  Alert Level:    ");
  switch (alert) {
    case CLEAR:   Serial.println("✓ CLEAR");    break;
    case WATCH:   Serial.println("⚠ WATCH");    break;
    case WARNING: Serial.println("⚠⚠ WARNING"); break;
    case SEVERE:  Serial.println("🚨 SEVERE");  break;
  }
  Serial.println("════════════════════════════════════════\n");
}
