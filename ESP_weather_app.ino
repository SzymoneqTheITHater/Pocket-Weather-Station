/*
 * COMPLETE THUNDERSTORM DETECTION SYSTEM
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
 * Features:
 * - Real-time atmospheric monitoring
 * - 3-hour pressure history tracking
 * - Multi-level alert system (CLEAR/WATCH/WARNING/SEVERE)
 * - Bluetooth communication to phone
 * - JSON data format for easy parsing
 */

#include <Wire.h>
#include <Adafruit_Sensor.h>
#include <Adafruit_BME280.h>
#include <BluetoothSerial.h>

// Check if Bluetooth is available
#if !defined(CONFIG_BT_ENABLED) || !defined(CONFIG_BLUEDROID_ENABLED)
#error Bluetooth is not enabled! Please run make menuconfig to enable it
#endif

// Bluetooth setup
BluetoothSerial SerialBT;

// BME280 sensor
Adafruit_BME280 bme;

// Storm detection parameters
const int HISTORY_SIZE = 36; // 3 hours of data at 5-minute intervals
float pressureHistory[HISTORY_SIZE];
int historyIndex = 0;
bool historyFilled = false;

// Thresholds for storm detection
const float PRESSURE_DROP_THRESHOLD = 3.0;    // hPa drop in 3 hours
const float HUMIDITY_THRESHOLD = 75.0;        // %
const float RAPID_PRESSURE_DROP = 1.5;        // hPa drop in 30 min (severe)
const float WATCH_PRESSURE_DROP = 1.8;        // hPa drop for watch level

// Timing
unsigned long lastReadTime = 0;
const unsigned long READ_INTERVAL = 300000;   // 5 minutes (300000 ms)
// For testing, you can use shorter interval: 30000 = 30 seconds

// Alert levels
enum AlertLevel {
  CLEAR = 0,
  WATCH = 1,
  WARNING = 2,
  SEVERE = 3
};

AlertLevel currentAlert = CLEAR;

// Device name for Bluetooth
const char* deviceName = "MountainGuide_Weather";

void setup() {
  Serial.begin(115200);
  delay(1000);
  
  Serial.println("\n╔════════════════════════════════════════════╗");
  Serial.println("║  MOUNTAIN GUIDE WEATHER MONITORING SYSTEM  ║");
  Serial.println("║       Thunderstorm Detection v1.0          ║");
  Serial.println("╚════════════════════════════════════════════╝\n");
  
  // Initialize I2C with ESP32 pins
  Wire.begin(21, 22); // SDA=21 (D21), SCL=22 (D22)
  
  // Initialize BME280
  Serial.print("Initializing BME280 sensor... ");
  if (!bme.begin(0x76)) {
    Serial.println("FAILED at 0x76");
    Serial.print("Trying address 0x77... ");
    if (!bme.begin(0x77)) {
      Serial.println("FAILED!");
      Serial.println("\n❌ ERROR: Could not find BME280 sensor!");
      Serial.println("Check wiring and restart.");
      while (1) delay(1000);
    }
  }
  Serial.println("✓ SUCCESS");
  
  // Configure BME280 for weather monitoring
  bme.setSampling(Adafruit_BME280::MODE_FORCED,
                  Adafruit_BME280::SAMPLING_X1,  // temperature
                  Adafruit_BME280::SAMPLING_X1,  // pressure
                  Adafruit_BME280::SAMPLING_X1,  // humidity
                  Adafruit_BME280::FILTER_OFF);
  
  // Initialize Bluetooth
  Serial.print("Initializing Bluetooth... ");
  SerialBT.begin(deviceName);
  Serial.println("✓ SUCCESS");
  Serial.print("Device name: ");
  Serial.println(deviceName);
  Serial.println("Waiting for phone connection...");
  
  // Initialize pressure history
  float initialPressure = bme.readPressure() / 100.0F;
  for (int i = 0; i < HISTORY_SIZE; i++) {
    pressureHistory[i] = initialPressure;
  }
  
  Serial.println("\n✓ System initialized successfully!");
  Serial.println("Starting atmospheric monitoring...\n");
  
  SerialBT.println("SYSTEM:READY");
  SerialBT.print("DEVICE:");
  SerialBT.println(deviceName);
}

void loop() {
  unsigned long currentTime = millis();
  
  // Read sensors at specified interval
  if (currentTime - lastReadTime >= READ_INTERVAL || lastReadTime == 0) {
    lastReadTime = currentTime;
    
    // Force BME280 reading
    bme.takeForcedMeasurement();
    
    // Read sensor data
    float temperature = bme.readTemperature();        // °C
    float pressure = bme.readPressure() / 100.0F;     // hPa
    float humidity = bme.readHumidity();              // %
    
    // Validate readings
    if (isnan(temperature) || isnan(pressure) || isnan(humidity)) {
      Serial.println("❌ ERROR: Invalid sensor readings!");
      SerialBT.println("ERROR:SENSOR:Invalid readings");
      return;
    }
    
    // Update pressure history
    pressureHistory[historyIndex] = pressure;
    historyIndex = (historyIndex + 1) % HISTORY_SIZE;
    if (historyIndex == 0) historyFilled = true;
    
    // Analyze weather data
    AlertLevel newAlert = analyzeWeatherData(pressure, humidity, temperature);
    
    // Send data via Bluetooth
    sendDataViaBluetooth(temperature, pressure, humidity, newAlert);
    
    // Check if alert level changed
    if (newAlert != currentAlert) {
      Serial.print("⚠ ALERT LEVEL CHANGED: ");
      Serial.print(getAlertName(currentAlert));
      Serial.print(" → ");
      Serial.println(getAlertName(newAlert));
      
      currentAlert = newAlert;
      sendAlertViaBluetooth(newAlert);
    }
    
    // Print debug info to Serial
    printDebugInfo(temperature, pressure, humidity, newAlert);
  }
  
  // Check for commands from phone
  if (SerialBT.available()) {
    String command = SerialBT.readStringUntil('\n');
    handleCommand(command);
  }
  
  delay(100);
}

AlertLevel analyzeWeatherData(float pressure, float humidity, float temperature) {
  // Need at least 6 readings (30 minutes) for initial analysis
  if (!historyFilled && historyIndex < 6) {
    return CLEAR;
  }
  
  // Calculate pressure drop over 3 hours (or available data)
  int oldestIndex = historyFilled ? historyIndex : 0;
  float pressureDrop3h = pressureHistory[oldestIndex] - pressure;
  
  // Calculate pressure drop over 30 minutes (last 6 readings)
  int recentStart = historyIndex - 6;
  if (recentStart < 0) recentStart += HISTORY_SIZE;
  if (!historyFilled && historyIndex < 6) recentStart = 0;
  
  float pressureDrop30min = pressureHistory[recentStart] - pressure;
  
  // Determine alert level based on multiple factors
  AlertLevel alert = CLEAR;
  
  // SEVERE: Rapid pressure drop + high humidity (imminent danger)
  if (pressureDrop30min >= RAPID_PRESSURE_DROP && humidity >= HUMIDITY_THRESHOLD) {
    alert = SEVERE;
  }
  // WARNING: Significant 3-hour drop + high humidity (storm likely)
  else if (pressureDrop3h >= PRESSURE_DROP_THRESHOLD && humidity >= HUMIDITY_THRESHOLD) {
    alert = WARNING;
  }
  // WATCH: Moderate changes indicating weather deterioration
  else if (pressureDrop3h >= WATCH_PRESSURE_DROP || 
           (pressureDrop30min >= 1.0 && humidity >= 70.0)) {
    alert = WATCH;
  }
  
  return alert;
}

void sendDataViaBluetooth(float temp, float pressure, float humidity, AlertLevel alert) {
  // Calculate pressure trends
  float pressureDrop3h = 0;
  float pressureDrop30min = 0;
  
  if (historyFilled || historyIndex >= 6) {
    int oldestIndex = historyFilled ? historyIndex : 0;
    pressureDrop3h = pressureHistory[oldestIndex] - pressure;
    
    int recentStart = historyIndex - 6;
    if (recentStart < 0) recentStart += HISTORY_SIZE;
    if (!historyFilled && historyIndex < 6) recentStart = 0;
    pressureDrop30min = pressureHistory[recentStart] - pressure;
  }
  
  // Send data in JSON format for easy parsing
  SerialBT.print("DATA:{");
  SerialBT.print("\"temp\":");
  SerialBT.print(temp, 1);
  SerialBT.print(",\"pressure\":");
  SerialBT.print(pressure, 1);
  SerialBT.print(",\"humidity\":");
  SerialBT.print(humidity, 1);
  SerialBT.print(",\"alert\":");
  SerialBT.print(alert);
  SerialBT.print(",\"p_drop_3h\":");
  SerialBT.print(pressureDrop3h, 2);
  SerialBT.print(",\"p_drop_30m\":");
  SerialBT.print(pressureDrop30min, 2);
  SerialBT.println("}");
}

void sendAlertViaBluetooth(AlertLevel alert) {
  SerialBT.print("ALERT:");
  
  switch (alert) {
    case CLEAR:
      SerialBT.println("CLEAR:Weather conditions stable and safe");
      break;
    case WATCH:
      SerialBT.println("WATCH:Weather changing - monitor conditions closely");
      break;
    case WARNING:
      SerialBT.println("WARNING:Thunderstorm likely within 1-2 hours - prepare to descend");
      break;
    case SEVERE:
      SerialBT.println("SEVERE:Thunderstorm imminent - seek shelter immediately!");
      break;
  }
}

void handleCommand(String command) {
  command.trim();
  
  if (command == "STATUS") {
    // Send immediate status update
    bme.takeForcedMeasurement();
    float temp = bme.readTemperature();
    float pressure = bme.readPressure() / 100.0F;
    float humidity = bme.readHumidity();
    sendDataViaBluetooth(temp, pressure, humidity, currentAlert);
    SerialBT.println("STATUS:OK");
  }
  else if (command == "RESET") {
    // Reset alert level and history
    currentAlert = CLEAR;
    historyIndex = 0;
    historyFilled = false;
    float currentPressure = bme.readPressure() / 100.0F;
    for (int i = 0; i < HISTORY_SIZE; i++) {
      pressureHistory[i] = currentPressure;
    }
    SerialBT.println("SYSTEM:RESET_COMPLETE");
    Serial.println("System reset by phone command");
  }
  else if (command == "PING") {
    SerialBT.println("SYSTEM:PONG");
  }
  else if (command == "INFO") {
    SerialBT.print("SYSTEM:VERSION:1.0");
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

String getAlertName(AlertLevel alert) {
  switch (alert) {
    case CLEAR: return "CLEAR";
    case WATCH: return "WATCH";
    case WARNING: return "WARNING";
    case SEVERE: return "SEVERE";
    default: return "UNKNOWN";
  }
}

void printDebugInfo(float temp, float pressure, float humidity, AlertLevel alert) {
  // Calculate pressure trends
  float pressureDrop3h = 0;
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
  Serial.print("📊 Temperature:    ");
  Serial.print(temp, 1);
  Serial.println(" °C");
  
  Serial.print("📊 Pressure:       ");
  Serial.print(pressure, 1);
  Serial.println(" hPa");
  
  Serial.print("📊 Humidity:       ");
  Serial.print(humidity, 1);
  Serial.println(" %");
  
  Serial.println("────────────────────────────────────────");
  
  Serial.print("📉 3h Drop:        ");
  Serial.print(pressureDrop3h, 2);
  Serial.println(" hPa");
  
  Serial.print("📉 30min Drop:     ");
  Serial.print(pressureDrop30min, 2);
  Serial.println(" hPa");
  
  Serial.print("📝 History:        ");
  Serial.print(historyFilled ? HISTORY_SIZE : historyIndex);
  Serial.println(" samples");
  
  Serial.println("────────────────────────────────────────");
  
  Serial.print("⚠️  Alert Level:    ");
  switch (alert) {
    case CLEAR:
      Serial.println("✓ CLEAR");
      break;
    case WATCH:
      Serial.println("⚠ WATCH");
      break;
    case WARNING:
      Serial.println("⚠⚠ WARNING");
      break;
    case SEVERE:
      Serial.println("🚨 SEVERE");
      break;
  }
  
  Serial.println("════════════════════════════════════════\n");
}
