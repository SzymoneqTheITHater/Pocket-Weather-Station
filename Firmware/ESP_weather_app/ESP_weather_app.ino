/*
 * STORM DETECTION SYSTEM
 * For Mountain Guide Safety - Engineering Thesis
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
 * Buzzer (active) -> ESP32 GPIO32
 *
 * ─── CONNECTIVITY (BLE / NimBLE-Arduino) ─────────────────────────────────────
 * The device is a BLE GATT peripheral advertising as "MountainGuide_Weather".
 * It exposes ONE custom service containing ONE DATA characteristic with the
 * READ + NOTIFY properties. The characteristic value is the current-reading
 * JSON (same fields as before). Each measurement cycle the firmware updates
 * the value and fires a notify; subscribed phones receive it instantly.
 * The phone can also READ the characteristic on connect for an immediate value
 * without waiting for the next cycle.
 *
 * Requires the "NimBLE-Arduino" library (v2.x) installed via Library Manager.
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
 *                          every 15 seconds. Good for testing LEDs, buzzer,
 *                          and the BLE notify stream.
 * ────────────────────────────────────────────────────────────────────────────
 */

// ─── SIMULATION FLAGS — edit these to switch modes ───────────────────────────
#define SIMULATION_MODE  0   // 0 = real sensors,  1 = simulated data
#define SIMULATION_FAST  0   // 0 = slow/realistic, 1 = fast/testing
// ─────────────────────────────────────────────────────────────────────────────

#include <Wire.h>
#include <Adafruit_Sensor.h>
#include <Adafruit_BME280.h>
#include <NimBLEDevice.h>
#include <TinyGPSPlus.h>
#include "esp_timer.h"

// ─── BLE (NimBLE) ────────────────────────────────────────────────────────────
// Custom 128-bit UUIDs for this project's service + characteristic.
// (Any unique 128-bit UUIDs would work; these are fixed for this device.)
// The app will use DATA_CHAR_UUID to read/subscribe to live readings.
static const char* SERVICE_UUID   = "5b3e1f00-1c2d-4e3a-9b6f-0a1b2c3d4e5f";
static const char* DATA_CHAR_UUID = "5b3e1f01-1c2d-4e3a-9b6f-0a1b2c3d4e5f";
// Reserved for a future history feature (NOT implemented yet). Adding it later
// is purely additive — clients discover characteristics dynamically, so the
// MVP app keeps working unchanged when this is introduced.
// static const char* HISTORY_CHAR_UUID = "5b3e1f02-1c2d-4e3a-9b6f-0a1b2c3d4e5f";

NimBLECharacteristic* pDataChar = nullptr;

// ─── GPS (LC76G) — standalone test, NOT used in storm algorithm ─────────────
TinyGPSPlus gps;
const unsigned long GPS_PRINT_INTERVAL = 100000;   // print once per 100 s
unsigned long lastGpsPrint = 0;

TinyGPSCustom vdop(gps, "GNGSA", 17);
TinyGPSCustom fixType(gps, "GNGSA", 2);   // 1=no fix, 2=2D, 3=3D

// BME280 is always declared so it can remain physically connected in all modes.
// In simulation mode it is declared but never initialised or read from.
Adafruit_BME280 bme;

// ─── Storm detection parameters ───────────────────────────────────────────────
const int   HISTORY_SIZE             = 91;
float       pressureHistory[HISTORY_SIZE];
int         historyIndex             = 0;
bool        historyFilled            = false;
const int   SAMPLES_30MIN            = 15;

const float WARNING_PRESSURE_THRESHOLD  = 3.0;
const float RAPID_PRESSURE_DROP      = 1.5;
const float WATCH_PRESSURE_THRESHOLD     = 1.8;
const float WATCH_RECENT_DROP        = 1.0;
const float WARNING_RECENT_DROP      = 1.25;

// ── Gust-front (convective arrival) detection ────────────────────────────────
// Both signals are evaluated over ONE shared window so they describe the same
// air-mass event. 5 samples × 2 min = 10 minutes.
//
// Pressure rise: a thunderstorm downdraft builds a surface mesohigh; documented
// gust-front pressure jumps are ~0.5–2 hPa over 2–5 min (Bedard & Meade 1977,
// J. Appl. Meteor.), mesohigh magnitude ~1–6 hPa (Stull, Practical Meteorology).
// At 2-min sampling a 2–5 min jump is smeared across the window, so 1.0 hPa
// over 10 min is a deliberately conservative catch-all.
//
// Temperature drop: outflow air is evaporatively cooled; gust-front passage
// brings a sharp temperature fall ahead of precipitation. 3.0 °C in 10 min
// keeps margin over the ~1–1.5 °C ambient-lapse cooling of a hard 10 min climb
// (~100–150 m), so hiking uphill cannot fake it. Note the two conditions also
// self-protect: descent raises pressure but WARMS the air; ascent cools the
// air but DROPS pressure — elevation change can never satisfy both at once.
const int   SAMPLES_10MIN            = 5;      // shared window (10 min @ 2-min cadence)
const float GUST_PRESSURE_RISE_10MIN = 1.0;    // hPa, altitude-CORRECTED rise
const float GUST_TEMP_DROP_10MIN     = 3.0;    // °C fall over the same window

// ── Moisture via dew point (replaces the RH gate) ────────────────────────────
// Surface dew point is a standard pre-convective moisture discriminator
// (e.g. Ćurić & Janc 2016, Atmos. Res. — Belgrade stability-index study).
// ~15 °C is a common warm-season convective guide near sea level; ambient dew
// point falls ~2 °C per km of altitude, so the threshold is height-adjusted
// to stay meaningful on a ridge.
const float DEWPOINT_CONVECTIVE_SL   = 15.0;   // °C threshold at sea level
const float DEWPOINT_LAPSE_PER_KM    = 2.0;    // °C reduction per km altitude

// ─── Altitude-pressure correction (Stage 4, option B) ────────────────────────
// GPS altitude lets us subtract the pressure change caused by the guide moving
// up/down, leaving only the weather-driven component. The per-metre coefficient
// is (P*g)/(R*T) — NOT a constant: it shrinks with altitude as P falls
//   ~0.120 hPa/m at sea level, ~0.104 at 1500 m, ~0.089 at 3000 m.
// P and T here are the LIVE BME280 readings, so the coefficient is automatically
// "at this specific altitude" without any lookup table.
const float GRAVITY        = 9.80665;   // m/s^2
const float R_DRY_AIR      = 287.05;    // J/(kg·K), specific gas constant, dry air

float  altitudeHistory[HISTORY_SIZE];   // parallel to pressureHistory; NAN = no fix
float  temperatureHistory[HISTORY_SIZE]; // parallel to pressureHistory; NAN until real samples exist
float  lastValidAltitude = NAN;         // metres MSL, NAN until first valid fix
double lastValidLat      = 0.0;
double lastValidLng      = 0.0;
bool   gpsHasFix         = false;
const unsigned long GPS_FIX_MAX_AGE_MS = 10000;   // tune to your GPS output rate (a few s of slack)

// ─── Battery global variable (updated every reading) ─────────────────────────────────
int batteryPct = 100;
// ─── Timing ───────────────────────────────────────────────────────────────────
unsigned long       lastReadTime  = 0;

// Monitoring clock: esp_timer micros captured at the FIRST real measurement. This
// is distinct from uptime (esp_timer from boot): in real mode the device blocks in
// setup() waiting for a GPS fix, so monitoring starts well after power-on. The app
// derives "drop trend ready in X min" from this, not uptime, so the countdown can't
// be skewed by however long the GPS fix took.
int64_t monitorStartUs    = 0;
bool    monitoringStarted = false;

#if SIMULATION_FAST == 1
const unsigned long READ_INTERVAL = 15000;   // 15 seconds — fast testing (long enough to see 10 s SEVERE buzzer window expire)
#else
const unsigned long READ_INTERVAL = 120000;  // 2 minutes — normal / slow sim
#endif

// ─── Alert levels ─────────────────────────────────────────────────────────────
// UNKNOWN (code 4) is emitted while the device is still warming up: a real CLEAR
// verdict cannot be trusted until the 30-min pressure window has enough samples,
// so until then the level is genuinely undetermined and no alert LED lights.
enum AlertLevel { CLEAR = 0, WATCH = 1, WARNING = 2, SEVERE = 3, UNKNOWN = 4 };
AlertLevel currentAlert = UNKNOWN;
// Alert LEDs start OFF at boot, so the first measurement must light them even if
// its level equals the initial state (the change-only update below would skip it).
bool firstMeasurementDone = false;
// Real measurement cycles since boot. Drives the warmup gate that holds the level
// at UNKNOWN until the 30-min window is valid. Counts true elapsed cycles, so it
// is NOT bypassed by fast-sim forcing historyFilled every cycle.
int measurementCount = 0;

// ─── De-escalation hold (anti-flapping) ───────────────────────────────────────
// Once an alert level is entered, a drop to an EASIER level is suppressed until
// this many readings have elapsed; escalation to a more dangerous level is always
// immediate. Counting readings (not millis) ties the hold to the 2-min sample
// cadence: 5 readings × 2 min = 10 minutes. Stops the level flapping on a threshold.
#if SIMULATION_FAST == 1
const int ALERT_DEESCALATE_HOLD_READINGS = 2;   // fast sim: holds a drop for exactly one 15 s cycle
#else
const int ALERT_DEESCALATE_HOLD_READINGS = 5;   // 5 × 2 min = 10 minutes (real / slow sim)
#endif
int currentAlertEnteredCount = 0;   // measurementCount when currentAlert was last (re)entered

const char* deviceName = "MountainGuide_Weather";

// ─── LED pins ─────────────────────────────────────────────────────────────────
const int PIN_LED_GREEN  = 25;
const int PIN_LED_YELLOW = 26;
const int PIN_LED_RED    = 27;
const int PIN_BUZZER     = 32;

const int BAT_PIN        = 34;
const int BAT_LED_GREEN  = 18;
const int BAT_LED_YELLOW = 19;
const int BAT_LED_RED    = 23;
const float BAT_FULL  = 4.2;
const float BAT_EMPTY = 3.3;

unsigned long lastBlinkTime = 0;
bool          blinkState    = false;

// SEVERE buzzer: beeps in sync with red LED for 10 s on each entry into SEVERE,
// then stays silent until the level leaves SEVERE and returns later.
const unsigned long SEVERE_BUZZER_DURATION_MS = 10000;
unsigned long severeBuzzerStartTime = 0;
bool          buzzerArmed           = false;

// Confirmation beeps on level change to CLEAR/WATCH/WARNING: 1/2/3 beeps.
// Symmetric 0.5 s on / 0.5 s off, toggled non-blockingly from the main loop.
const unsigned long CONFIRM_BEEP_PHASE_MS = 500;
int           confirmPhasesLeft      = 0;      // on/off phases remaining (0 = idle)
bool          confirmBeepOn          = false;  // buzzer state within the pattern
unsigned long confirmBeepPhaseStart  = 0;

// ─── Simulation state ─────────────────────────────────────────────────────────
#if SIMULATION_MODE == 1

#if SIMULATION_FAST == 1
// Fast mode: manual control — steps through alert levels one by one
int   simStep          = 0;
const int SIM_STEPS    = 4;
#else
// Slow mode: pressure starts high and drops gradually
float simPressure      = 1013.0;
float simHumidity      = 65.0;
float simTemperature   = 20.0;
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
    case 3:  // SEVERE — rapid 30-min drop + warm moist air (dew point ≈ 18 °C ≥ 15)
      pressure    = 1008.0;
      humidity    = 90.0;
      temperature = 20.0;
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
     // WARNING: big 3h drop, but recent 30-min window nearly flat (so SEVERE doesn't fire)
    for (int i = 0; i < HISTORY_SIZE; i++) pressureHistory[i] = 1012.6;
    int cur   = (historyIndex - 1 + HISTORY_SIZE) % HISTORY_SIZE;
    int idx30 = (cur - SAMPLES_30MIN + HISTORY_SIZE) % HISTORY_SIZE;
    pressureHistory[idx30] = 1010.0;   // 30-min drop ~0.5 hPa vs current 1009.5
    historyFilled = true;
  } else if (simStep % SIM_STEPS == 3) {
      // SEVERE: rapid 30-min drop
    for (int i = 0; i < HISTORY_SIZE; i++) pressureHistory[i] = 1012.6;
    int cur   = (historyIndex - 1 + HISTORY_SIZE) % HISTORY_SIZE;
    int idx30 = (cur - SAMPLES_30MIN + HISTORY_SIZE) % HISTORY_SIZE;
    pressureHistory[idx30] = 1009.6;   // 30-min drop ~1.6 hPa vs current 1008
    historyFilled = true;
  }
  simStep++;

#else
  // Slow mode: pressure drops naturally over time (v3 tuning).
  // The 3 h window only fills after tick 91, so before that the level rides
  // entirely on the 30-min branches, which need the dew-point moisture gate
  // (>= 15 °C, altitude unknown in sim). Warm-sector setup: warm moist air
  // ahead of the storm makes 'moist' true from phase 3 on, and the growing
  // 30-min drop then walks the tiers: 1.0 → 1.25 → 1.5 hPa.
  // Phase 1 (ticks 0–5):   stable, warm — CLEAR (UNKNOWN during 32-min warmup)
  // Phase 2 (ticks 6–15):  gentle fall, humidity rising — CLEAR (dew point < 15)
  // Phase 3 (ticks 16–30): steady fall, moist — WATCH ~tick 20, WARNING ~tick 27
  // Phase 4 (ticks 31+):   rapid fall, very moist — SEVERE
  if (simTickCount < 6) {
    simPressure   = 1013.0;
    simHumidity   = 65.0 + simTickCount * 1.0;
    simTemperature = 20.0;
  } else if (simTickCount < 16) {
    simPressure   = 1013.0 - (simTickCount - 5) * 0.06;
    simHumidity   = min(70.0 + (simTickCount - 6) * 0.6, 75.0);
    simTemperature = 20.0;
  } else if (simTickCount < 31) {
    simPressure   = 1012.4 - (simTickCount - 15) * 0.09;
    simHumidity   = min(simHumidity + 1.0, 90.0);
    simTemperature = 19.5;
  } else {
    simPressure   = max(simPressure - 0.5, 990.0);
    simHumidity   = min(simHumidity + 0.5, 95.0);
    simTemperature = max(simTemperature - 0.2, 17.0);
  }
  simTickCount++;
  pressure    = simPressure;
  humidity    = simHumidity;
  temperature = simTemperature;
#endif

}
#endif  // SIMULATION_MODE

// ─── LED control ─────────────────────────────────────────────────────────────
void updateLEDs(AlertLevel alert) {
  digitalWrite(PIN_LED_GREEN,  alert == CLEAR   ? HIGH : LOW);
  digitalWrite(PIN_LED_YELLOW, alert == WATCH   ? HIGH : LOW);
  digitalWrite(PIN_LED_RED,    (alert == WARNING || alert == SEVERE) ? HIGH : LOW);
}

// ─── Buzzer confirmation beeps ────────────────────────────────────────────────
// Arm `count` beeps (0.5 s on / 0.5 s off). The pattern is then advanced
// non-blockingly by handleConfirmBeep() in the main loop, so it does not stall
// the SEVERE buzzer/LED loop or BLE. Used for CLEAR (1), WATCH (2), WARNING (3).
// A pattern of N beeps is 2*N-1 phases: on, gap, on, gap, ..., on.
void startConfirmBeep(int count) {
  if (count <= 0) {
    confirmPhasesLeft = 0;
    digitalWrite(PIN_BUZZER, LOW);
    return;
  }
  confirmPhasesLeft     = 2 * count - 1;
  confirmBeepOn         = true;
  confirmBeepPhaseStart = millis();
  digitalWrite(PIN_BUZZER, HIGH);
}

// Advance the confirmation-beep pattern; call once per loop iteration.
void handleConfirmBeep() {
  if (confirmPhasesLeft == 0) return;
  unsigned long now = millis();
  if (now - confirmBeepPhaseStart < CONFIRM_BEEP_PHASE_MS) return;

  confirmBeepPhaseStart = now;
  confirmPhasesLeft--;
  if (confirmPhasesLeft == 0) {
    digitalWrite(PIN_BUZZER, LOW);   // pattern finished
  } else {
    confirmBeepOn = !confirmBeepOn;  // toggle between beep and gap
    digitalWrite(PIN_BUZZER, confirmBeepOn ? HIGH : LOW);
  }
}

// ─── Forward declarations ─────────────────────────────────────────────────────
AlertLevel analyzeWeatherData(float pressure, float humidity, float temperature);
void       computeDrops(float pressure, float &drop3h, float &drop30min);
float      pressurePerMeter(float pressure_hPa, float temp_C);
void       computeCorrectedDrops(float pressure, float temperature,
                                 float &rawDrop3h, float &rawDrop30min,
                                 float &corrDrop3h, float &corrDrop30min,
                                 bool &applied3h, bool &applied30m);
float      dewPointC(float tempC, float relHumidity);
bool       isConvectivelyMoist(float tempC, float relHumidity);
void       computeGustFrontSignals(float pressure, float temperature,
                                   float &rawRise10min, float &pressureRise10min,
                                   float &tempDrop10min, bool &valid);
void       sendDataViaBluetooth(float temp, float pressure, float humidity, AlertLevel alert, int batteryPct);
String     getAlertName(AlertLevel alert);
void       printDebugInfo(float temp, float pressure, float humidity, AlertLevel alert, int batteryPct);
int        readBatteryPercent();
void       updateBatteryLEDs(int pct);
void       setupGPS();
void       updateGPS();

// ─────────────────────────────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  delay(1000);


  Serial.println("\n╔════════════════════════════════════════════╗");
  Serial.println("║  MOUNTAIN GUIDE WEATHER MONITORING SYSTEM  ║");
  Serial.println("║     Thunderstorm Detection v3.0 (BLE)      ║");
  Serial.println("╚════════════════════════════════════════════╝\n");

  setupGPS();

#if SIMULATION_MODE == 1
  Serial.println("*** SIMULATION MODE ACTIVE ***");
  #if SIMULATION_FAST == 1
  Serial.println("*** FAST: cycling alert levels every 15 seconds ***\n");
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

  pinMode(PIN_LED_GREEN,  OUTPUT);
  pinMode(PIN_LED_YELLOW, OUTPUT);
  pinMode(PIN_LED_RED,    OUTPUT);
  pinMode(PIN_BUZZER,     OUTPUT);
  digitalWrite(PIN_BUZZER, LOW);
  // Alert LEDs start OFF — nothing should imply a measured alert level until the
  // first weather reading is computed.
  digitalWrite(PIN_LED_GREEN,  LOW);
  digitalWrite(PIN_LED_YELLOW, LOW);
  digitalWrite(PIN_LED_RED,    LOW);

  pinMode(BAT_LED_GREEN,  OUTPUT);
  pinMode(BAT_LED_YELLOW, OUTPUT);
  pinMode(BAT_LED_RED,    OUTPUT);
  analogReadResolution(12);

  // Battery sensing is independent of the weather/GPS subsystem — light a battery
  // LED immediately at boot, then keep refreshing it once per measurement cycle.
  batteryPct = readBatteryPercent();
  updateBatteryLEDs(batteryPct);

  // ─── BLE init (NimBLE GATT peripheral) ──────────────────────────────────────
  Serial.print("Initializing BLE... ");
  NimBLEDevice::init(deviceName);
  NimBLEDevice::setMTU(512);   // allow notifications big enough for the JSON payload (app requests 512)

  NimBLEServer* pServer = NimBLEDevice::createServer();
  pServer->advertiseOnDisconnect(true);   // auto re-advertise after a phone disconnects

  NimBLEService* pService = pServer->createService(SERVICE_UUID);
  pDataChar = pService->createCharacteristic(
      DATA_CHAR_UUID,
      NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
  );
  pDataChar->setValue("{}");   // placeholder until the first reading populates it
  NimBLEDescriptor* pDesc = pDataChar->createDescriptor("2901", NIMBLE_PROPERTY::READ, 32);
  pDesc->setValue("Pocket_Weather_Station_Data(JSON)");
  pService->start();

  NimBLEAdvertising* pAdvertising = NimBLEDevice::getAdvertising();
  pAdvertising->setName(deviceName);   // NimBLE 2.x: the name must be set explicitly to be advertised
  pAdvertising->start();

  Serial.println("✓ SUCCESS");
  Serial.print("Advertising as: ");
  Serial.println(deviceName);

#if SIMULATION_MODE == 0
  // Wait for the first viable altitude fix before sampling begins, for as long
  // as it takes. Every stored sample is therefore born with a real altitude, so
  // no backfill is needed. NOTE: if a fix is never acquired (e.g. no sky view or
  // a wiring/antenna fault) the device waits here indefinitely and never starts
  // monitoring — a deliberate choice to guarantee altitude-paired data, at the
  // cost of the standalone pressure-only fallback.
  Serial.println("Waiting for first GPS fix (will wait as long as needed)...");
  unsigned long gpsWaitStart = millis();
  unsigned long lastWaitPrint = 0;

  // "Waiting for GPS" indicator: sweep the alert LEDs green → yellow → red, one
  // lit at a time for 0.5 s each, so the user knows the device is powered and
  // searching (not yet monitoring). Non-blocking, driven by millis().
  const unsigned long GPS_WAIT_LED_INTERVAL = 500;   // 0.5 s per LED
  unsigned long lastWaitLed = 0;
  int           waitLedStep = 0;                     // 0=green, 1=yellow, 2=red

  while (!gpsHasFix) {
    updateGPS();                                   // keeps parsing NMEA; sets gpsHasFix

    if (millis() - lastWaitLed >= GPS_WAIT_LED_INTERVAL) {
      lastWaitLed = millis();
      digitalWrite(PIN_LED_GREEN,  waitLedStep == 0 ? HIGH : LOW);
      digitalWrite(PIN_LED_YELLOW, waitLedStep == 1 ? HIGH : LOW);
      digitalWrite(PIN_LED_RED,    waitLedStep == 2 ? HIGH : LOW);
      waitLedStep = (waitLedStep + 1) % 3;
    }

    if (millis() - lastWaitPrint >= 5000) {        // heartbeat so the monitor shows life
      lastWaitPrint = millis();
      Serial.print("  ...still waiting for GPS fix (");
      Serial.print((millis() - gpsWaitStart) / 1000);
      Serial.println(" s)");
    }
    delay(50);                                     // yields to BLE + idle/WDT task
  }

  // Fix acquired — clear the sweep so no alert LED is lit until the first
  // measurement sets a real level.
  digitalWrite(PIN_LED_GREEN,  LOW);
  digitalWrite(PIN_LED_YELLOW, LOW);
  digitalWrite(PIN_LED_RED,    LOW);

  Serial.print("✓ GPS fix acquired after ");
  Serial.print((millis() - gpsWaitStart) / 1000);
  Serial.println(" s — starting measurements.");
#endif

#if SIMULATION_MODE == 0
  bme.takeForcedMeasurement();
  float initialPressure = bme.readPressure() / 100.0F;
#else
  float initialPressure = 1013.0;
#endif

  for (int i = 0; i < HISTORY_SIZE; i++) pressureHistory[i] = initialPressure;
  for (int i = 0; i < HISTORY_SIZE; i++) altitudeHistory[i] = NAN;  // filled once GPS has a fix
  // NAN (not backfill): the gust-front check must simply stay inert until
  // 10 min of REAL temperatures exist, mirroring the altitude-correction
  // NAN convention.
  for (int i = 0; i < HISTORY_SIZE; i++) temperatureHistory[i] = NAN;

  Serial.println("\n✓ System initialized successfully!");
  Serial.println("Starting atmospheric monitoring...\n");
}

// ─────────────────────────────────────────────────────────────────────────────
void loop() {
updateGPS();

  unsigned long currentTime = millis();

  if (currentTime - lastReadTime >= READ_INTERVAL || lastReadTime == 0) {
    lastReadTime = currentTime;
    measurementCount++;

    // Anchor the monitoring clock on the first real sample (post-GPS-fix in real
    // mode; at boot in SIMULATION_MODE since the GPS wait is skipped there).
    if (measurementCount == 1) {
      monitorStartUs    = esp_timer_get_time();
      monitoringStarted = true;
    }

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
      return;
    }
#endif

    // In fast sim mode, history is managed inside getSimulatedReadings()
    // In all other modes, update history normally
#if !(SIMULATION_MODE == 1 && SIMULATION_FAST == 1)
    pressureHistory[historyIndex]    = pressure;
    altitudeHistory[historyIndex]    = lastValidAltitude;  // NAN if no fix → correction skips this window
    temperatureHistory[historyIndex] = temperature;
    historyIndex = (historyIndex + 1) % HISTORY_SIZE;
    if (historyIndex == 0) historyFilled = true;
#endif

    batteryPct = readBatteryPercent();
    updateBatteryLEDs(batteryPct);

    AlertLevel measuredAlert = analyzeWeatherData(pressure, humidity, temperature);
    // Warmup gate: hold the level at UNKNOWN until the 30-min window is valid
    // (needs SAMPLES_30MIN + 1 real samples). analyzeWeatherData() still runs and
    // computes the underlying level — we just don't trust/emit it yet.
    bool warmupComplete = (measurementCount > SAMPLES_30MIN);
    if (!warmupComplete) measuredAlert = UNKNOWN;

    // De-escalation hold: escalation to a more dangerous level applies immediately,
    // but a drop to an easier level is suppressed until currentAlert has been held
    // for ALERT_DEESCALATE_HOLD_READINGS readings. UNKNOWN (warmup) is exempt so the
    // first real level appears promptly. Relies on CLEAR<WATCH<WARNING<SEVERE (0<1<2<3).
    AlertLevel newAlert = measuredAlert;
    if (currentAlert != UNKNOWN && measuredAlert != UNKNOWN &&
        (int)measuredAlert < (int)currentAlert &&
        (measurementCount - currentAlertEnteredCount) < ALERT_DEESCALATE_HOLD_READINGS) {
      newAlert = currentAlert;   // hold the more dangerous level for now
      Serial.print("⏳ De-escalation held: keeping ");
      Serial.print(getAlertName(currentAlert));
      Serial.print(" over ");
      Serial.print(getAlertName(measuredAlert));
      Serial.print(" (");
      Serial.print(measurementCount - currentAlertEnteredCount);
      Serial.print("/");
      Serial.print(ALERT_DEESCALATE_HOLD_READINGS);
      Serial.println(" readings)");
    }

    sendDataViaBluetooth(temperature, pressure, humidity, newAlert, batteryPct);

    // First measurement: alert LEDs were OFF since boot, so light them to reflect
    // the real level even if it matches the initial CLEAR (change-only logic below).
    if (!firstMeasurementDone) {
      firstMeasurementDone = true;
      updateLEDs(newAlert);
    }

    if (newAlert != currentAlert) {
      Serial.print("⚠ ALERT LEVEL CHANGED: ");
      Serial.print(getAlertName(currentAlert));
      Serial.print(" → ");
      Serial.println(getAlertName(newAlert));
      currentAlert = newAlert;
      currentAlertEnteredCount = measurementCount;   // restart the de-escalation hold window
      updateLEDs(currentAlert);

      // Buzzer feedback on every level change (except UNKNOWN):
      //   SEVERE  → intermittent beeps synced with the red LED for 10 s
      //   WARNING → three 0.5 s beeps
      //   WATCH   → two 0.5 s beeps
      //   CLEAR   → one 0.5 s beep
      if (newAlert == SEVERE) {
        confirmPhasesLeft = 0;   // cancel any in-flight confirmation beeps
        severeBuzzerStartTime = millis();
        buzzerArmed = true;
      } else {
        buzzerArmed = false;
        digitalWrite(PIN_BUZZER, LOW);
        switch (newAlert) {
          case WARNING: startConfirmBeep(3); break;
          case WATCH:   startConfirmBeep(2); break;
          case CLEAR:   startConfirmBeep(1); break;
          default:      break;  // UNKNOWN: stay silent
        }
      }
    }

    printDebugInfo(temperature, pressure, humidity, newAlert, batteryPct);
  }

  // SEVERE: blink red LED at 4 Hz (toggle every 125 ms), non-blocking.
  // Buzzer toggles off the same blinkState while armed (first 10 s of episode).
  if (currentAlert == SEVERE) {
    unsigned long now = millis();
    if (now - lastBlinkTime >= 125) {
      lastBlinkTime = now;
      blinkState = !blinkState;
      digitalWrite(PIN_LED_RED, blinkState ? HIGH : LOW);

      if (buzzerArmed) {
        if (now - severeBuzzerStartTime < SEVERE_BUZZER_DURATION_MS) {
          digitalWrite(PIN_BUZZER, blinkState ? HIGH : LOW);
        } else {
          buzzerArmed = false;
          digitalWrite(PIN_BUZZER, LOW);
        }
      }
    }
  }

  // Non-blocking confirmation beeps for CLEAR/WATCH/WARNING transitions.
  handleConfirmBeep();

  delay(100);
}

// ─── Algorithm v3 (altitude-aware, dew-point moisture, gust-front SEVERE) ────
// Tier structure vs v2:
//  * Moisture is dew-point based and STRENGTHENS the short-window branches
//    instead of vetoing everything: a >=3 hPa/3h synoptic fall reaches WARNING
//    on its own (fixes the v2 inconsistency where a large dry fall could never
//    leave WATCH, while WATCH's own 3h branch had no moisture condition).
//  * New independent SEVERE path: gust-front signature (pressure RISE + temp
//    fall over the shared 10-min window) — covers the convective arrival case
//    the falling-barometer logic is blind to. Short lead time by nature
//    (minutes, not hours): a "get off the ridge NOW" signal, not a forecast.
AlertLevel analyzeWeatherData(float pressure, float humidity, float temperature) {

  float rawDrop3h, rawDrop30min, pressureDrop3h, pressureDrop30min;
  bool  applied3h, applied30m;
  computeCorrectedDrops(pressure, temperature,
                        rawDrop3h, rawDrop30min,
                        pressureDrop3h, pressureDrop30min,
                        applied3h, applied30m);

  // Moisture: dew-point based, altitude-adjusted (replaces RH >= 75 / >= 70).
  bool moist = isConvectivelyMoist(temperature, humidity);

  // Gust-front signature — both signals over the SAME 10-min window.
  float rawRise10, rise10, tDrop10;
  bool  gustValid;
  computeGustFrontSignals(pressure, temperature, rawRise10, rise10, tDrop10, gustValid);
  bool gustFront = gustValid &&
                   rise10  >= GUST_PRESSURE_RISE_10MIN &&
                   tDrop10 >= GUST_TEMP_DROP_10MIN;

  AlertLevel alert = CLEAR;

  if (gustFront ||
      (pressureDrop30min >= RAPID_PRESSURE_DROP && moist)) {
    alert = SEVERE;
  } else if (pressureDrop3h >= WARNING_PRESSURE_THRESHOLD ||
             (pressureDrop30min >= WARNING_RECENT_DROP && moist)) {
    alert = WARNING;
  } else if (pressureDrop3h >= WATCH_PRESSURE_THRESHOLD ||
             (pressureDrop30min >= WATCH_RECENT_DROP && moist)) {
    alert = WATCH;
  }

  return alert;
}

void computeDrops(float pressure, float &drop3h, float &drop30min) {
  drop3h    = 0.0;
  drop30min = 0.0;

  // Most recent sample: historyIndex was already advanced past it in loop().
  int cur = (historyIndex - 1 + HISTORY_SIZE) % HISTORY_SIZE;

  // 30-minute drop: valid once SAMPLES_30MIN intervals exist (= SAMPLES_30MIN + 1 samples).
  if (historyFilled || historyIndex >= SAMPLES_30MIN + 1) {
    int idx30 = (cur - SAMPLES_30MIN + HISTORY_SIZE) % HISTORY_SIZE;
    drop30min = pressureHistory[idx30] - pressure;
  }

  // 3-hour drop: only meaningful once the buffer holds a full window.
  // With 90 intervals and 2-min samples this span is 180 min; HISTORY_SIZE = 91 for a true 180.
  if (historyFilled) {
    drop3h = pressureHistory[historyIndex] - pressure;  // historyIndex now points at the oldest sample
  }
}

// ─── Altitude correction helpers (Stage 4, option B) ─────────────────────────
// Local pressure lapse with height, in hPa per metre, AT THE CURRENT STATE.
// Because pressure_hPa is the live BME280 reading, this value is automatically
// correct for whatever altitude the device is at — it falls from ~0.120 near
// sea level toward ~0.089 at 3000 m without any tables.
float pressurePerMeter(float pressure_hPa, float temp_C) {
  float T_kelvin = temp_C + 273.15;
  return (pressure_hPa * GRAVITY) / (R_DRY_AIR * T_kelvin);
}

// ─── Dew point helpers (v3) ───────────────────────────────────────────────────
// Magnus formula (Sonntag coefficients; Alduchov & Eskridge 1996). Valid to
// well below 0 °C, more than adequate for BME280 accuracy.
float dewPointC(float tempC, float relHumidity) {
  if (relHumidity <= 0.0f) return -273.15f;          // degenerate input guard
  const float a = 17.62f, b = 243.12f;
  float gamma = logf(relHumidity / 100.0f) + (a * tempC) / (b + tempC);
  return (b * gamma) / (a - gamma);
}

// Altitude-adjusted convective moisture check.
// Falls back to the sea-level threshold if altitude is unknown (simulation).
bool isConvectivelyMoist(float tempC, float relHumidity) {
  float threshold = DEWPOINT_CONVECTIVE_SL;
  if (!isnan(lastValidAltitude)) {
    threshold -= DEWPOINT_LAPSE_PER_KM * (lastValidAltitude / 1000.0f);
  }
  return dewPointC(tempC, relHumidity) >= threshold;
}

// ─── Gust-front signals (v3) — one shared 10-minute window for BOTH conditions ─
// Computes, over the SAME lookback sample:
//   rawRise10min      : raw pressure CHANGE, positive = rise (debug/thesis
//                       comparison; needs only pressure history, so it is
//                       filled even when the corrected signal is invalid)
//   pressureRise10min : altitude-corrected pressure CHANGE, sign flipped so
//                       positive = rise (mesohigh building)
//   tempDrop10min     : temperature FALL, positive = cooling (outflow air)
// valid == false until the window has real data (incl. a real old temperature
// and — for the corrected rise — a real old altitude).
//
// Altitude correction is mandatory here: descending ~9 m already produces a
// ~1 hPa raw rise, which would fake the mesohigh signature. Temperature is
// left uncorrected; see threshold margin note at the constants.
void computeGustFrontSignals(float pressure, float temperature,
                             float &rawRise10min, float &pressureRise10min,
                             float &tempDrop10min, bool  &valid) {
  rawRise10min      = 0.0f;
  pressureRise10min = 0.0f;
  tempDrop10min     = 0.0f;
  valid             = false;

  // Window must exist (same guard style as computeDrops's 30-min branch).
  if (!(historyFilled || historyIndex >= SAMPLES_10MIN + 1)) return;

  int cur   = (historyIndex - 1 + HISTORY_SIZE) % HISTORY_SIZE;
  int idx10 = (cur - SAMPLES_10MIN + HISTORY_SIZE) % HISTORY_SIZE;

  // Raw pressure change over the window, positive = RISE.
  rawRise10min = pressure - pressureHistory[idx10];

  float tempOld = temperatureHistory[idx10];
  float altOld  = altitudeHistory[idx10];
  if (isnan(tempOld) || isnan(altOld) || isnan(lastValidAltitude)) return;

  // Remove the elevation component (same physics as computeCorrectedDrops):
  // climbing dH metres lowers pressure by perMeter*dH, so the weather-only
  // rise is rawRise + perMeter*dH.
  float perMeter = pressurePerMeter(pressure, temperature);
  float dH       = lastValidAltitude - altOld;         // +climb, −descent
  pressureRise10min = rawRise10min + perMeter * dH;

  tempDrop10min = tempOld - temperature;               // positive = cooling
  valid = true;
}

// Computes both the raw drops and the elevation-corrected drops over the same
// 30-min and 3-h windows. Correction is applied whenever (a) we have a current
// altitude fix and (b) the window's old sample also had a valid altitude.
// Otherwise the corrected value falls back to the raw value — so the device
// still works exactly as before whenever GPS is unavailable (the standalone case).
// NOTE: the full GPS altitude change is subtracted, with no deadband/filtering,
// so stationary GPS vertical noise passes straight into the corrected drops.
void computeCorrectedDrops(float pressure, float temperature,
                           float &rawDrop3h, float &rawDrop30min,
                           float &corrDrop3h, float &corrDrop30min,
                           bool &applied3h, bool &applied30m) {

  computeDrops(pressure, rawDrop3h, rawDrop30min);
  corrDrop3h    = rawDrop3h;     // default: no correction
  corrDrop30min = rawDrop30min;
  applied3h  = false;
  applied30m = false;

  if (isnan(lastValidAltitude)) return;   // no current fix → leave drops raw (Condition left only because of Sim_modes)

  float perMeter = pressurePerMeter(pressure, temperature);  // hPa/m at this altitude
  int   cur      = (historyIndex - 1 + HISTORY_SIZE) % HISTORY_SIZE;

  // 30-minute window — same index logic as computeDrops()
  if (historyFilled || historyIndex >= SAMPLES_30MIN + 1) {
    int   idx30  = (cur - SAMPLES_30MIN + HISTORY_SIZE) % HISTORY_SIZE;
    float altOld = altitudeHistory[idx30];
    if (!isnan(altOld)) {
      float dH      = lastValidAltitude - altOld;     // +climb, −descent
      float dP_alt  = perMeter * dH;                  // pressure change due to moving
      corrDrop30min = rawDrop30min - dP_alt;          // remove the full elevation component
      applied30m    = true;
    }
  }

  // 3-hour window — oldest sample sits at historyIndex (matches computeDrops)
  if (historyFilled) {
    float altOld = altitudeHistory[historyIndex];
    if (!isnan(altOld)) {
      float dH     = lastValidAltitude - altOld;
      float dP_alt = perMeter * dH;
      corrDrop3h   = rawDrop3h - dP_alt;
      applied3h    = true;
    }
  }
}

// ─── BLE output ──────────────────────────────────────────────────────────────
// Builds the current-reading JSON (same fields as the old DATA: line) and
// publishes it: sets the DATA characteristic value (so a fresh READ returns it)
// and fires a notify to any subscribed phone.
void sendDataViaBluetooth(float temp, float pressure, float humidity, AlertLevel alert, int batteryPct) {

  float rawDrop3h, rawDrop30min, corrDrop3h, corrDrop30min;
  bool  applied3h, applied30m;
  computeCorrectedDrops(pressure, temp, rawDrop3h, rawDrop30min,
                        corrDrop3h, corrDrop30min, applied3h, applied30m);

  // 10-min gust-front window. Mirrors the cp_drop_* fallback semantics: when the
  // corrected rise can't be computed (no temp/altitude history yet), send the
  // raw value as the corrected one.
  float rawRise10, corrRise10, tDrop10;
  bool  gustValid;
  computeGustFrontSignals(pressure, temp, rawRise10, corrRise10, tDrop10, gustValid);
  if (!gustValid) corrRise10 = rawRise10;

  // Device uptime in seconds (rollover-proof: esp_timer is 64-bit microseconds).
  uint32_t uptimeSec = (uint32_t)(esp_timer_get_time() / 1000000ULL);
  // Monitoring time in seconds: elapsed since the first real measurement (0 until then).
  // The app bases the drop-trend "ready in X min" countdown on this, not uptime.
  uint32_t monSec = monitoringStarted
      ? (uint32_t)((esp_timer_get_time() - monitorStartUs) / 1000000LL) : 0;

  int   fix    = gpsHasFix ? 1 : 0;
  float altOut = isnan(lastValidAltitude) ? 0.0f : lastValidAltitude;

  // p_drop_*  = raw drops (kept for the app + thesis comparison)
  // cp_drop_* = altitude-corrected drops actually used by the alert logic
  // p_rise_10m / cp_rise_10m = raw / altitude-corrected 10-min pressure rise
  //   (gust-front window; cp falls back to raw until temp+alt history exists)
  // up_s = uptime since boot; mon_s = time since first measurement (drives app countdown)
  // fix/lat/lon/alt = GPS context (Stage 4 app addition)
  char json[336];
  snprintf(json, sizeof(json),
    "{\"temp\":%.1f,\"pressure\":%.2f,\"humidity\":%.1f,\"alert\":%d,"
    "\"p_drop_3h\":%.2f,\"p_drop_30m\":%.2f,"
    "\"cp_drop_3h\":%.2f,\"cp_drop_30m\":%.2f,"
    "\"p_rise_10m\":%.2f,\"cp_rise_10m\":%.2f,"
    "\"bat\":%d,\"up_s\":%lu,\"mon_s\":%lu,"
    "\"fix\":%d,\"lat\":%.5f,\"lon\":%.5f,\"alt\":%.1f}",
    temp, pressure, humidity, (int)alert,
    rawDrop3h, rawDrop30min, corrDrop3h, corrDrop30min,
    rawRise10, corrRise10,
    batteryPct, (unsigned long)uptimeSec, (unsigned long)monSec,
    fix, lastValidLat, lastValidLng, altOut);

  if (pDataChar != nullptr) {
    pDataChar->setValue((uint8_t*)json, strlen(json));
    pDataChar->notify();
  }

  Serial.print("BLE DATA: ");
  Serial.println(json);
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

void printDebugInfo(float temp, float pressure, float humidity, AlertLevel alert, int batteryPct) {
  float rawDrop3h, rawDrop30min, corrDrop3h, corrDrop30min;
  bool  applied3h, applied30m;
  computeCorrectedDrops(pressure, temp, rawDrop3h, rawDrop30min,
                        corrDrop3h, corrDrop30min, applied3h, applied30m);

  Serial.println("════════════════════════════════════════");
#if SIMULATION_MODE == 1
  #if SIMULATION_FAST == 1
  Serial.println("[SIM — FAST MODE]");
  #else
  Serial.println("[SIM — SLOW MODE]");
  #endif
#endif
  Serial.print("📊 Temperature:    "); Serial.print(temp, 1);              Serial.println(" °C");
  Serial.print("📊 Pressure:       "); Serial.print(pressure, 2);          Serial.println(" hPa");
  Serial.print("📊 Humidity:       "); Serial.print(humidity, 1);          Serial.println(" %");
  Serial.print("🔋 Battery:        "); Serial.print(batteryPct);            Serial.println(" %");
  Serial.println("────────────────────────────────────────");
  if (gpsHasFix) {
    Serial.print("🛰  Altitude:       "); Serial.print(lastValidAltitude, 1); Serial.println(" m MSL");
    Serial.print("🛰  Lapse @ alt:    "); Serial.print(pressurePerMeter(pressure, temp), 4);
    Serial.println(" hPa/m");
  } else {
    Serial.println("🛰  GPS:            no current fix — using last-known altitude");
  }
  Serial.println("────────────────────────────────────────");
  Serial.print("📉 3h Drop  raw:   "); Serial.print(rawDrop3h, 2);    Serial.println(" hPa");
  Serial.print("📉 3h Drop  corr:  "); Serial.print(corrDrop3h, 2);
  Serial.println(applied3h ? " hPa  (alt-corrected)" : " hPa  (no correction)");
  Serial.print("📉 30m Drop raw:   "); Serial.print(rawDrop30min, 2); Serial.println(" hPa");
  Serial.print("📉 30m Drop corr:  "); Serial.print(corrDrop30min, 2);
  Serial.println(applied30m ? " hPa  (alt-corrected)" : " hPa  (no correction)");

  // v3 signals: dew-point moisture gate + gust-front window
  float dpThreshold = DEWPOINT_CONVECTIVE_SL;
  if (!isnan(lastValidAltitude)) dpThreshold -= DEWPOINT_LAPSE_PER_KM * (lastValidAltitude / 1000.0f);
  Serial.print("💧 Dew point:      "); Serial.print(dewPointC(temp, humidity), 1);
  Serial.print(" °C  ("); Serial.print(isConvectivelyMoist(temp, humidity) ? "MOIST" : "dry");
  Serial.print(", threshold "); Serial.print(dpThreshold, 1); Serial.println(" °C)");

  float rawRise10, rise10, tDrop10;
  bool  gustValid;
  computeGustFrontSignals(pressure, temp, rawRise10, rise10, tDrop10, gustValid);
  Serial.print("🌬  10m P rise raw: "); Serial.print(rawRise10, 2); Serial.println(" hPa");
  if (gustValid) {
    Serial.print("🌬  10m P rise corr:"); Serial.print(rise10, 2);  Serial.println(" hPa  (alt-corrected)");
    Serial.print("🌬  10m Temp drop:  "); Serial.print(tDrop10, 2); Serial.println(" °C");
  } else {
    Serial.println("🌬  Gust front:     inactive (needs 10 min of temp + altitude history)");
  }
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
    case UNKNOWN: Serial.println("❔ UNKNOWN (warming up)"); break;
  }
  Serial.println("════════════════════════════════════════\n");
}

// ─── Battery monitoring ──────────────────────────────────────────────────────
int readBatteryPercent() {
  long raw = 0;
  for (int i = 0; i < 8; i++) {
    raw += analogRead(BAT_PIN);
    delay(10);
  }
  raw /= 8;
  float vADC = (raw / 4095.0) * 3.3;
  float vBat = vADC * 2.0;
  int pct = (int)((vBat - BAT_EMPTY) / (BAT_FULL - BAT_EMPTY) * 100.0);
  return constrain(pct, 0, 100);
}

void updateBatteryLEDs(int pct) {
  digitalWrite(BAT_LED_GREEN,  LOW);
  digitalWrite(BAT_LED_YELLOW, LOW);
  digitalWrite(BAT_LED_RED,    LOW);
  if (pct >= 50) {
    digitalWrite(BAT_LED_GREEN, HIGH);
  } else if (pct >= 15) {
    digitalWrite(BAT_LED_YELLOW, HIGH);
  } else {
    digitalWrite(BAT_LED_RED, HIGH);
  }
}

void setupGPS() {
  Serial2.setRxBufferSize(1024);                 // headroom for NMEA bursts
  Serial2.begin(115200, SERIAL_8N1, 16, 17);       // RX=16, TX=17, LC76G default baud
  Serial.println("GPS (LC76G) initialised on UART2 @ 115200 baud");
}

void updateGPS() {
  // Feed every available byte to the parser, continuously
  while (Serial2.available() > 0) {
    gps.encode(Serial2.read());
  }

  // Cache the latest valid fix so the storm algorithm and BLE payload can use it
  // between the (slower) print cycles below.
  if (gps.location.isUpdated() && gps.location.isValid()) {
    lastValidLat = gps.location.lat();
    lastValidLng = gps.location.lng();
  }
  if (gps.altitude.isUpdated() && gps.altitude.isValid()) {
    lastValidAltitude = gps.altitude.meters();
  }
  gpsHasFix = gps.location.isValid() 
              && !isnan(lastValidAltitude) 
              && gps.location.age() < GPS_FIX_MAX_AGE_MS;

  // Print a summary once per interval
  if (millis() - lastGpsPrint >= GPS_PRINT_INTERVAL) {
    lastGpsPrint = millis();

    Serial.println("──────── GPS READING ────────");

    if (gps.location.isValid()) {
      Serial.print("Latitude:   "); Serial.println(gps.location.lat(), 6);
      Serial.print("Longitude:  "); Serial.println(gps.location.lng(), 6);
    } else {
      Serial.println("Location:   --- (no fix yet)");
    }

    if (gps.altitude.isValid()) {
      Serial.print("Altitude:   "); Serial.print(gps.altitude.meters(), 1);
      Serial.println(" m (above sea level)");
    } else {
      Serial.println("Altitude:   --- (no fix yet)");
    }

    if (gps.satellites.isValid()) {
      Serial.print("Satellites: "); Serial.println(gps.satellites.value());
    }
    if (gps.hdop.isValid()) {
      Serial.print("HDOP:       "); Serial.println(gps.hdop.hdop(), 2);
    }

    if (vdop.isValid()) {
      Serial.print("VDOP:       "); Serial.println(vdop.value());
    }

    if (fixType.isValid()) {
      Serial.print("Fix type:   "); Serial.print(fixType.value());
      Serial.println("  (1=none, 2=2D, 3=3D)");
    }

    // Sanity check: warn if nothing is arriving after 100 s
    if (millis() > 100000 && gps.charsProcessed() < 10) {
      Serial.println("WARNING: no GPS data — check TX/RX wiring and baud rate.");
    }

    Serial.println();
  }
}
