# Pocket-Weather-Station
With this project I am trying to create a microcontroller device that, based on pressure, humidity, and temperature sensors, predicts a local thunderstorm threat using a programmed algorithm. It sends this information to a phone via Bluetooth communication and presents it in a mobile app. 

Here I present the work schedule for this project:

# Engineering Thesis — Detailed Project Plan
*Microprocessor-based system for monitoring and supporting mountain guides with an early warning function for atmospheric hazards*

**Deadline: June 12, 2026**

---

## Phase 1 — Hardware MVP
**Apr 17 – Apr 30**

> No BLE needed here — your existing Classic BT firmware is fine. The MVP just needs to work standalone: simulation mode, LEDs, and battery.

### Week 1 (Apr 17–20)

**Fri Apr 17 — Add simulation mode to firmware**
Add a `#define SIMULATION_MODE` compile flag. When enabled, replace sensor reads with scripted fake values that slowly drop pressure over time, triggering all four alert levels in sequence. All output goes to Serial monitor.

**Sat Apr 18 — Test and tune simulation mode**
Run through CLEAR → WATCH → WARNING → SEVERE on the Serial monitor. Adjust pressure drop constants if thresholds feel wrong. This is your main testing tool for all future hardware work.

**Sun Apr 19 — Rest**

**Mon Apr 20 — Wire 3 LEDs to ESP32**
Use GPIO 25, 26, 27 with 220Ω resistors. Green = CLEAR, yellow = WATCH, red = WARNING and SEVERE. Update the alert handler in firmware to set the correct LED on every alert change.

### Week 2 (Apr 21–27)

**Tue Apr 21 — Add passive buzzer**
Wire to GPIO 32. Short single beep on WATCH, two beeps on WARNING, repeating pattern on SEVERE. Use `tone()` or manual `digitalWrite` with delay.

**Wed Apr 22 — Integration test — standalone device**
Run simulation mode with no phone connected. Confirm LEDs and buzzer respond correctly to all four alert levels. The device must be fully usable without a phone.

**Thu Apr 23 — Research LiPo battery + TP4056 charger module**
Any 3.7V LiPo (1000–2000 mAh). TP4056 module handles USB charging. Both widely available. Order or buy locally today so they arrive before the weekend.

**Fri Apr 24 — Wire battery circuit**
LiPo → TP4056 OUT → ESP32 VIN. Add an on/off switch in the positive line. Charge battery separately before connecting ESP32.

**Sat Apr 25 — Test battery runtime**
Fully charge, run device in simulation mode with 30-second read intervals. Note how long it lasts. Add battery voltage reading via voltage divider on ADC pin GPIO 34.

**Sun Apr 26 — Rest**

**Mon Apr 27 — Add battery level to BT output**
Add a `bat` field to the JSON payload. Formula: map voltage 3.3V–4.2V to 0–100%. Display percentage in Serial debug output.

### Week 3 start (Apr 28–30)

**Tue Apr 28 — Clean up firmware and push to GitHub**
Remove debug prints, add clear comments to key functions, document the simulation mode flag at the top of the file. Commit and push.

**Wed Apr 29 — Hardware MVP final test**
Full run: battery powered, simulation mode cycling through all alert levels, correct LEDs and buzzer, JSON arriving on phone via Serial BT Monitor app. Hardware MVP complete.

**Thu Apr 30 — Buffer day**
Fix anything that broke. Write brief notes on what you built — these go directly into the thesis hardware chapter later.

**Deliverable:** Battery-powered ESP32 with BME280, simulation mode, LED + buzzer alert system, Classic BT streaming JSON.

---

## Phase 2 — Basic Mobile App
**May 1 – May 21**

> This phase starts with switching the firmware from Classic BT to BLE — one focused day using the BLE firmware already written. Then Flutter app development begins.

### Week 3 cont. — BLE firmware switch (May 1–4)

**Fri May 1 — Flash BLE firmware, verify with nRF Connect app**
Use the BLE firmware already prepared. Install nRF Connect on your phone, scan for "MountainGuide_Weather", subscribe to the DATA characteristic and confirm JSON arrives. Install NimBLE-Arduino library in Arduino IDE first.

**Sat May 2 — Install Flutter and Android Studio**
Follow flutter.dev/docs/get-started/install. Run `flutter doctor` and fix any issues. This can take 1–2 hours. Create a test project and run hello world on your phone to confirm setup works.

**Sun May 3 — Rest**

**Mon May 4 — Create Flutter project, add flutter_blue_plus package**
`flutter create weather_app`. Add `flutter_blue_plus` to pubspec.yaml. Run the package example on your phone to confirm BLE scanning works.

### Week 4 — BLE connection + data (May 5–11)

**Tue May 5 — Build BLE scan screen**
List nearby BLE devices. Filter for "MountainGuide_Weather" by name. Show connect button.

**Wed May 6 — Implement connect + subscribe to DATA notifications**
On tap, connect to device and discover services. Find DATA characteristic by UUID and subscribe. Print raw values to console to confirm data is arriving.

**Thu May 7 — Parse JSON into a data model**
Create a `WeatherData` class: temp, pressure, humidity, alert, p_drop_3h, p_drop_30m. Strip the `DATA:` prefix, decode JSON, populate the model.

**Fri May 8 — Handle ALERT and SYSTEM message prefixes**
Route incoming strings by prefix. DATA goes to JSON parser, ALERT goes to notification handler, SYSTEM to a log. Keeps code clean as you add features.

**Sat May 9 — Build main screen — live sensor values**
Large readable numbers for temp, pressure, humidity. Update in real time. Show timestamp of last reading.

**Sun May 10 — Rest**

**Mon May 11 — Add color-coded alert banner**
Full-width strip at the top. Green = CLEAR, yellow = WATCH, orange = WARNING, red = SEVERE. Show alert name and short description text.

### Week 5 — Safety features + testing (May 12–19)

**Tue May 12 — Send STATUS command on app open**
Write `STATUS` to CMD characteristic immediately after connecting. Forces device to send a reading right away so user doesn't wait 5 minutes.

**Wed May 13 — Show pressure trend values**
Display p_drop_3h and p_drop_30m from JSON. Use arrows: ↓↓ fast drop, ↓ slow drop, → stable.

**Thu May 14 — Background notifications on alert change**
Use `flutter_local_notifications`. When ALERT message arrives with a higher level than last known, fire a local push notification. Critical for mountain safety use.

**Fri May 15 — BLE reconnect logic**
Auto-scan and reconnect to "MountainGuide_Weather" every 5 seconds after disconnect. Show "Reconnecting..." in UI.

**Sat May 16 — End-to-end testing**
Full flow: open app, connect, trigger all 4 alert levels via simulation mode, confirm notifications in background. Test on 2 phones if possible.

**Sun May 17 — Rest**

**Mon May 18 — Bug fixes (day 1)**
Fix anything broken from testing. Prioritise: crashes on disconnect, missing notifications, incorrect JSON parsing.

**Tue May 19 — Bug fixes (day 2) + additional device testing**
Continue fixing issues. Test on a second phone if possible. Verify background notifications work reliably.

**Wed May 20 — Final verification pass**
Full end-to-end flow on a clean app install. Confirm all four alert levels, reconnect logic, and notifications behave correctly.

**Thu May 21 — App MVP done — push code to GitHub**
Clean up code, add comments, push. Take screenshots of every screen in a clean state — you will need them for the thesis.

**Deliverable:** Flutter app connects via BLE, shows live data with color-coded alert, sends background notifications on alert change.

---

## Phase 3 — OLED Screen
**May 22 – May 29**

> Adding the OLED display to the device so it works fully standalone without any phone. Wired to the same I²C bus as the BME280.

**Fri May 22 — Wire SSD1306 OLED display (128×64, I²C)**
Same I²C bus as BME280 — connect to D21/D22. OLED uses address 0x3C. Install Adafruit SSD1306 and Adafruit GFX libraries in Arduino IDE.

**Sat May 23 — Display basic readings on screen**
Show temperature, pressure, humidity on one screen. Confirm values match Serial output. BME280 is at 0x76 and OLED at 0x3C — different addresses, no conflict.

**Sun May 24 — Rest**

**Mon May 25 — Add alert level display page**
Second screen showing current alert level in large text (CLEAR / WATCH / WARNING / SEVERE) and pressure trend arrows. Auto-cycle between screen 1 and screen 2 every 3 seconds.

**Tue May 26 — Polish OLED layout**
Add battery percentage to the display. Make sure text fits cleanly at all alert levels. Test all four states using simulation mode.

**Wed May 27 — Full integration test with OLED**
Device runs standalone: OLED shows data, LEDs and buzzer signal danger, BLE streams JSON to phone, all powered by battery. Test for 30+ minutes.

**Thu May 28 — Clean up firmware, push to GitHub**
Commit the OLED version. Take photos of the complete device — front, side, showing screen — for the thesis hardware chapter.

**Fri May 29 — Buffer day**
Fix any remaining hardware issues. After this point the device is feature-complete.

**Deliverable:** Complete standalone device: OLED shows live readings and alert level, LEDs and buzzer signal danger, BLE streams to phone, runs on battery.

---

## Phase 4 — Optional Improvements (skip if behind schedule)
**May 30 – May 31**

> Strictly optional. If Phase 3 ran over or thesis writing (Phase 5) is behind, skip this phase entirely. Only proceed if you are ahead of schedule. Enclosure, data logging, and UI polish are deferred indefinitely.

**Fri May 30 — Improve prediction algorithm (v2)**
Add temperature drop rate as a third factor. Document updated thresholds — needed for thesis anyway.

**Sat May 31 — Deep sleep between readings**
ESP32 light sleep with timer wakeup. Target 24h+ battery life. Measure actual current draw.

**Deliverable (if completed):** Improved algorithm, lower power use.

---

## Phase 5 — Thesis: Hardware Chapter
**May 25 – Jun 1**

> Start writing alongside the tail end of Phase 3. Use evenings May 25–29 for thesis work while OLED hardware tasks wrap up during the day.

**Mon May 25 — Component selection rationale**
Why ESP32, why BME280, alternatives considered. Comparison table of microcontroller options.

**Tue May 26 — Circuit schematic and system block diagram**
Draw schematic in EasyEDA or KiCad. Block diagram: sensor → MCU → OLED / LEDs / BLE / power.

**Wed May 27 — Algorithm description with flowchart**
Document the decision logic: rolling buffer, pressure drop calculation, threshold table, all four alert levels. Draw a flowchart.

**Thu May 28 — Power system section**
LiPo specs, TP4056 circuit, measured current draw, estimated and actual battery life.

**Fri May 29 — Test results and measurement accuracy**
Table comparing device readings vs phone weather app. Note error margins and conditions.

**Sat May 30 — Expand any hardware chapter section** *(skip if doing Phase 4 optional work)*

**Sun Jun 1 — Rest / review hardware chapter**

**Deliverable:** Complete hardware chapter draft with schematics, algorithm flowchart, and test data.

---

## Phase 6 — Thesis: Software Chapter
**Jun 2 – Jun 8**

**Mon Jun 2 — Firmware architecture**
Main loop structure, simulation mode design, sensor → algorithm → output data flow. Include a simple diagram.

**Tue Jun 3 — BLE communication protocol documentation**
Service UUID, characteristic UUIDs, every message format: DATA / ALERT / SYSTEM / ERROR. Command set: STATUS / RESET / PING / INFO.

**Wed Jun 4 — App architecture overview**
Layer diagram: BLE layer, data parsing, UI layer. Screen flow diagram. State management approach.

**Thu Jun 5 — Screen-by-screen UI documentation**
Use the screenshots taken after Phase 2 and Phase 4. Annotate each screenshot with callouts explaining the elements.

**Fri Jun 6 — Safety and reliability section**
Behavior when BLE disconnects, sensor fails, battery dies. Relevant for safety-critical mountain guide use case.

**Sat Jun 7 — Review and tidy software chapter**

**Sun Jun 8 — Rest**

**Deliverable:** Complete software chapter with architecture diagrams, protocol docs, and annotated screenshots.

---

## Phase 7 — Final Thesis Document
**Jun 7 – Jun 12**

**Sat Jun 7 — Abstract and introduction draft** *(parallel with Phase 6 software chapter review)*
Introduction: frame the safety context (lightning fatalities in mountains). Draft abstract once both hardware and software chapters are complete.

**Sun Jun 8 — Literature review and conclusions**
Literature review: existing weather monitoring systems, BLE sensor nodes, barometric prediction methods. Conclusions: results summary + future work (AS3935 lightning sensor, GPS, mesh networking).

**Mon Jun 9 — Full document pass + send draft to supervisor**
Formatting, figure numbering, citations, table of contents, list of figures, abbreviations list. Send complete draft to supervisor today — not Jun 11.

**Tue Jun 10 — Supervisor review window / start corrections**
Begin implementing any corrections received. Continue if feedback arrives late.

**Wed Jun 11 — Implement remaining corrections**
Address all supervisor feedback. Final consistency pass.

**Thu Jun 12 — Final proofread and submit**
Deadline.

**Deliverable:** Complete, proofread thesis submitted by June 12.
