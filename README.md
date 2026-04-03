# Pocket-Weather-Station
With this project I am trying to create a microcontroller device that, based on pressure, humidity, and temperature sensors, predicts a local thunderstorm threat using a programmed algorithm. It sends this information to a phone via Bluetooth communication and presents it in a mobile app. 

Here I present the work schedule for this project:

Here's the plan as plain text you can copy:

---

**ENGINEERING THESIS — DETAILED PROJECT PLAN**
*Microprocessor-based atmospheric hazard early warning system*

---

**PHASE 0 — Tech stack & environment setup | COMPLETE**

All done:
- ESP32-WROOM-32 DevKit chosen and working
- BME280 wired and reading over I²C
- Arduino IDE set up and firmware uploading
- Classic Bluetooth serial tested with Serial BT Monitor app

---

**PHASE 1 — Hardware MVP | Apr 3 – Apr 7**

Already done:
- Sensor reading loop with error handling
- 4-level alert system (CLEAR / WATCH / WARNING / SEVERE)
- 3-hour pressure history buffer with 30-min and 3-hour drop analysis
- Classic BT serial sending JSON data to phone
- Command handler (STATUS, RESET, PING, INFO)

Still to do:

Apr 3–4 — Wire SSD1306 OLED display (128×64, I²C)
Same I²C bus as BME280, just add it to D21/D22 at address 0x3C. Use Adafruit SSD1306 library.

Apr 4–5 — Show live readings and alert level on OLED
Page 1: temp/humidity/pressure. Page 2: alert level and pressure trend arrows. Auto-cycle every 3 seconds.

Apr 5–6 — Wire LED (3-color or 3 separate) and passive buzzer
Green = CLEAR, yellow = WATCH, red = WARNING/SEVERE. Buzzer beep pattern on alert change.

Apr 6–7 — Integration test, full loop without phone
Device must be fully usable standalone: readings on screen, alert on LED. Bluetooth is a bonus, not a dependency.

Deliverable: Device works fully standalone — OLED shows data, LED and buzzer signal danger, BT streams JSON.

---

**PHASE 2 — Basic mobile app | Apr 7 – Apr 20**

Note: The firmware uses Classic Bluetooth SPP (not BLE), which means Android only. iOS blocks classic BT in third-party apps. Worth clarifying with your supervisor early.

Week 1 — BT connection and live data (Apr 7–13):

Apr 7–8 — Choose framework and set up project
Recommendation: Flutter with the flutter_bluetooth_serial package. Android-only is fine for SPP. MIT App Inventor is an option for a very fast MVP if needed.

Apr 8–9 — Implement Classic BT scan, pair, and connect
Filter by device name "MountainGuide_Weather". Handle connect/disconnect gracefully.

Apr 9–11 — Subscribe to incoming data stream and parse JSON
Split on newline, detect DATA:{...} vs ALERT:... vs SYSTEM:... prefixes. Map to a data model.

Apr 11–13 — Build main screen with live readings and color-coded alert banner
Large readable numbers. Green/yellow/orange/red background strip based on alert level. Timestamp of last reading.

Week 2 — Safety features and polish (Apr 13–20):

Apr 13–15 — Send STATUS command on app open to get an immediate reading
Don't make the user wait 5 minutes for first data. Add a manual refresh button too.

Apr 15–17 — Alert change notifications when app is backgrounded
Local notifications triggered when an ALERT: message is received. This is critical for mountain use.

Apr 17–18 — Show pressure trend values (p_drop_3h and p_drop_30m)
Already present in the JSON — just display them. Down arrows for fast/slow drop, right arrow for stable.

Apr 18–20 — End-to-end testing and reconnect logic
Test BT drop and auto-reconnect. Test notifications in background. Test on at least 2 Android devices if possible.

Deliverable: Android app connects to device, shows live data with color-coded danger level, sends background notifications on alert change.

---

**PHASE 3 — Hardware improvement | Apr 20 – May 7**

Apr 20–22 — Improve storm algorithm (v2)
Add temperature drop rate as a third factor — rapid cooling combined with pressure drop and high humidity is the most reliable thunderstorm signature. Also add altitude compensation for the pressure baseline.

Apr 22–24 — Add power supply: LiPo 3.7V + TP4056 charger + voltage divider for battery level
Expose battery percentage in the BT JSON payload (add a "bat" field). Show on OLED.

Apr 24–25 — Implement deep sleep between readings
ESP32 light sleep with timer wakeup every 5 minutes. Target 24h+ battery life. Measure actual current draw.

Apr 25–28 — Field test 1 — take device outdoors for 2+ hours
Log data and compare with a reference (phone weather app or nearby station). Tune thresholds if false positives occur.

Apr 28 – May 1 — Permanent build: solder onto perfboard or simple PCB
Use EasyEDA to draw the schematic (you'll need it for the thesis anyway). Solder components and verify robustness.

May 1–4 — Design and build enclosure
3D print or modify a project box. Ensure the sensor is vented, OLED is visible, USB-C for charging is accessible, and LED is visible.

May 4–6 — Field test 2 — full device in enclosure
Confirm readings aren't affected by enclosure heat. Test BT range through the enclosure.

May 6–7 — Final hardware fixes and cleanup
Cable management, strain relief, label connectors for thesis photos.

Deliverable: Battery-powered enclosed device with improved algorithm, verified by at least two field tests.

---

**PHASE 4 — App improvement | May 7 – May 18**

May 7–9 — Local data logging: store last 24 hours of readings
SQLite via sqflite (Flutter) or SharedPreferences for a simple JSON log. Persist across restarts.

May 9–11 — History charts for pressure, temperature, and humidity
Line chart using fl_chart (Flutter). Mark warning events on the pressure chart — this will look strong in the thesis.

May 11–12 — Altitude estimation from pressure
Hypsometric formula. Useful, easy to add, and professionally relevant for mountain guides.

May 12–14 — Storm risk trend indicator
Show whether danger is rising or falling based on the last 3 readings. Arrow plus text description.

May 14–16 — UI polish: typography, spacing, dark mode
Make it look presentable for the thesis defense and documentation screenshots.

May 16–18 — Final testing and clean screenshots for thesis
Screenshot every screen in a clean state. These go directly into your documentation.

Deliverable: Polished app with history charts, altitude estimation, storm trend indicator, and dark mode.

---

**PHASE 5 — Thesis: hardware chapter | May 18 – May 25**

May 18–19 — Component selection rationale
Why ESP32, why BME280, alternatives considered, comparison table.

May 19–20 — Circuit schematic and system block diagram
Use KiCad or EasyEDA (you'll have the schematic from Phase 3 already). Block diagram: sensor → MCU → display / BT / LED / power.

May 20–21 — Algorithm description with flowchart
Document the v2 algorithm: rolling buffer, drop calculation, decision logic, all thresholds. Include a flowchart as a figure.

May 21–22 — Power system and battery life measurements
LiPo specs, TP4056 circuit, measured current in active vs sleep modes, calculated battery life.

May 22–24 — Test results and measurement accuracy
Comparison table: device vs reference station. Error margins. Field test conditions and findings.

May 24–25 — Review and tidy hardware chapter

Deliverable: Complete hardware chapter with schematics, algorithm flowchart, and field test data.

---

**PHASE 6 — Thesis: software chapter | May 25 – Jun 1**

May 25–26 — Firmware architecture on ESP32
Main loop structure, sensor → algorithm → BT data flow.

May 26–27 — Communication protocol documentation
Document the text protocol: DATA:{...} format, ALERT: format, command set (STATUS / RESET / PING / INFO). Already well-defined in the code.

May 27–28 — App architecture overview
BT layer, data parsing layer, UI layer, state management approach.

May 28–29 — Screen-by-screen UI documentation with annotated screenshots
Use the screenshots from Phase 4. Annotate with callouts in a drawing tool.

May 29–31 — Safety and reliability section
Behavior on BT disconnect, sensor failure, low battery. Relevant for the safety-critical mountain guide use case.

May 31 – Jun 1 — Review and tidy software chapter

Deliverable: Complete software chapter with architecture diagrams, protocol documentation, and annotated UI screenshots.

---

**PHASE 7 — Promotional corrections and final document | Jun 1 – Jun 8**

Jun 1–2 — Abstract, introduction, problem statement
Frame the safety context: lightning is the leading cause of weather-related outdoor fatalities in the mountains.

Jun 2–3 — Literature review
Existing weather monitoring systems, BT/BLE sensor nodes, barometric storm prediction research, mountain guide safety standards.

Jun 3–4 — Conclusions and future work
Future work ideas: AS3935 lightning sensor integration, GPS, mesh networking between multiple guides.

Jun 4–6 — Full document pass: formatting, figures, references, table of contents
Check figure numbering, citation style, list of figures, abbreviations list.

Jun 6–8 — Supervisor review, address feedback, final proofread

Deliverable: Complete, proofread thesis document ready for submission.

---

**BUFFER WEEK | Jun 8 – Jun 15**

Reserve for: hardware debugging, catching up on any slipped phase, supervisor correction round, thesis printing and binding.

Final submission deadline: June 15.
