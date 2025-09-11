/*
  ESP32-S3 BLE Controller Firmware
  
  This sketch merges hardware control logic (pumps, switches) with a
  BLE interface for remote monitoring and control. It saves onTime and
  offTime settings to Non-Volatile Storage (NVS) to persist them
  across reboots.

  Specifications Implemented:
  - Service UUID: 4fafc201-1fb5-459e-8fcc-c5c9c331914b
  - Characteristics:
    - Value A (onTime): c8a3cadd-536c-4819-9154-10a110a19a4e
    - Value B (offTime): d8a3cadd-536c-4819-9154-10a110a19a4f
    - General Data: beb5483e-36e1-4688-b7f5-ea07361b26a8
    - Debug (NOTIFY, JSON): f4a1f353-8576-4993-81b4-10a1b0596348
    - Uptime (NOTIFY, uint32_t): a8f5f247-3665-448d-8a0c-6b3a2a3e592b
    - Reboot (WRITE, 1-byte): b2d49a43-6c84-474c-a496-02d997e54f8e

  Libraries needed:
  - ArduinoBLE for ESP32
  - ArduinoJson (https://arduinojson.org/) - Install from Library Manager.
*/

// Import necessary libraries
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <ArduinoJson.h>
#include <Preferences.h> // For Non-Volatile Storage

// BLE Service and Characteristic UUIDs
#define SERVICE_UUID                  "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define VALUE_A_CHARACTERISTIC_UUID   "c8a3cadd-536c-4819-9154-10a110a19a4e" // onTime
#define VALUE_B_CHARACTERISTIC_UUID   "d8a3cadd-536c-4819-9154-10a110a19a4f" // offTime
#define DATA_CHARACTERISTIC_UUID      "beb5483e-36e1-4688-b7f5-ea07361b26a8"
#define DEBUG_CHARACTERISTIC_UUID     "f4a1f353-8576-4993-81b4-1101b0596348"
#define UPTIME_CHARACTERISTIC_UUID    "a8f5f247-3665-448d-8a0c-6b3a2a3e592b"
#define REBOOT_CHARACTERISTIC_UUID    "b2d49a43-6c84-474c-a496-02d997e54f8e"

// --- Hardware Pin Definitions ---
// Input pins
#define SW1R 5
#define SW2R 4
#define SW3R 6
#define SW4R 7
#define mesVpomp 9
#define BOOT 0

// Output pins
#define a1Switch 2
#define a2Switch 1
#define comLed 48
#define pwmPomp 10

// --- Global Variables ---
// For Hardware Logic
unsigned long myTime;
uint32_t onTime;    // Changed to uint32_t to match BLE spec
uint32_t offTime;   // Changed to uint32_t to match BLE spec
long timer;
bool lastState; // Tracks the pump timer cycle
int floater;    // Holds the state of the floater switch
int evStatus;   // Derived status from the floater switch

// For BLE
BLECharacteristic *pValueACharacteristic;
BLECharacteristic *pValueBCharacteristic;
BLECharacteristic *pDataCharacteristic;
BLECharacteristic *pDebugCharacteristic;
BLECharacteristic *pUptimeCharacteristic;
BLECharacteristic *pRebootCharacteristic;
bool deviceConnected = false;
String dataCharacteristicValue = "Hello from ESP32!";
unsigned long lastUptimeNotifyTime = 0;
unsigned long lastDebugNotifyTime = 0;
const long uptimeNotifyInterval = 1000; // 1 second
const long debugNotifyInterval = 2000;  // 2 seconds

// For NVS
Preferences preferences;


// --- BLE Server Callbacks ---
class MyServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    deviceConnected = true;
    digitalWrite(comLed, HIGH); // Turn on communication LED
    Serial.println("Client Connected");
  }

  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;
    digitalWrite(comLed, LOW); // Turn off communication LED
    Serial.println("Client Disconnected");
    pServer->getAdvertising()->start();
  }
};

// --- Characteristic Callbacks ---
class DataCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *pCharacteristic) {
    String value = pCharacteristic->getValue();
    if (value.length() > 0) {
      Serial.print("Received value on Data Characteristic: ");
      Serial.println(value);
      dataCharacteristicValue = value;
    }
  }
};

class RebootCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *pCharacteristic) {
    Serial.println("Reboot command received. Restarting...");
    delay(500);
    ESP.restart();
  }
};

// Callback for handling writes to Value A and Value B
class ValueCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *pCharacteristic) {
    uint8_t* data = pCharacteristic->getData();
    size_t len = pCharacteristic->getLength();

    if (data != nullptr && len == 4) {
      // Data is a 4-byte little-endian integer.
      // On a little-endian MCU like ESP32, we can just cast the pointer.
      uint32_t value = *(uint32_t*)data;
      
      String uuid = pCharacteristic->getUUID().toString();
      const String value_a_uuid = BLEUUID(VALUE_A_CHARACTERISTIC_UUID).toString();
      const String value_b_uuid = BLEUUID(VALUE_B_CHARACTERISTIC_UUID).toString();

      if (uuid == value_a_uuid) {
        onTime = value;
        Serial.print("Set onTime (Value A) to: ");
        Serial.println(onTime);
        // Save to NVS
        preferences.begin("ble-settings", false);
        preferences.putUInt("onTime", onTime);
        preferences.end();
        Serial.println("Saved onTime to NVS.");
      } else if (uuid == value_b_uuid) {
        offTime = value;
        Serial.print("Set offTime (Value B) to: ");
        Serial.println(offTime);
        // Save to NVS
        preferences.begin("ble-settings", false);
        preferences.putUInt("offTime", offTime);
        preferences.end();
        Serial.println("Saved offTime to NVS.");
      }
    }
  }
};


void setup() {
  Serial.begin(115200);
  Serial.println("Starting Integrated Controller...");

  // --- Initialize Hardware Logic Variables from NVS ---
  preferences.begin("ble-settings", true); // Namespace, read-only mode
  onTime = preferences.getUInt("onTime", 720000);   // Load onTime, default to 12 minutes
  offTime = preferences.getUInt("offTime", 2880000); // Load offTime, default to 48 minutes
  preferences.end();

  Serial.print("Loaded onTime from NVS: ");
  Serial.println(onTime);
  Serial.print("Loaded offTime from NVS: ");
  Serial.println(offTime);

  // --- Sending values over serial in a structured format for parsing ---
  Serial.print("ONTIME:");
  Serial.println(onTime);
  Serial.print("OFFTIME:");
  Serial.println(offTime);

  timer = 1;
  lastState = false;
  evStatus = 0; 

  // --- Initialize Pin Modes ---
  pinMode(SW1R, INPUT);
  pinMode(SW2R, INPUT);
  pinMode(SW3R, INPUT);
  pinMode(SW4R, INPUT);
  pinMode(mesVpomp, INPUT);
  pinMode(BOOT, INPUT_PULLUP);

  pinMode(a1Switch, OUTPUT);
  pinMode(a2Switch, OUTPUT);
  pinMode(comLed, OUTPUT);
  pinMode(pwmPomp, OUTPUT);
  
  digitalWrite(a1Switch, LOW);
  digitalWrite(comLed, LOW); // Start with communication LED off

  // --- Initialize BLE ---
  BLEDevice::init("ESP32-S3 Controller");
  BLEServer *pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());
  BLEService *pService = pServer->createService(SERVICE_UUID);

  // Value A Characteristic (onTime)
  pValueACharacteristic = pService->createCharacteristic(VALUE_A_CHARACTERISTIC_UUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE);
  pValueACharacteristic->setValue(onTime);
  pValueACharacteristic->setCallbacks(new ValueCallbacks());

  // Value B Characteristic (offTime)
  pValueBCharacteristic = pService->createCharacteristic(VALUE_B_CHARACTERISTIC_UUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE);
  pValueBCharacteristic->setValue(offTime);
  pValueBCharacteristic->setCallbacks(new ValueCallbacks());

  // Data Characteristic
  pDataCharacteristic = pService->createCharacteristic(DATA_CHARACTERISTIC_UUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE);
  pDataCharacteristic->setValue(dataCharacteristicValue);
  pDataCharacteristic->setCallbacks(new DataCallbacks());

  // Debug Characteristic
  pDebugCharacteristic = pService->createCharacteristic(DEBUG_CHARACTERISTIC_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  pDebugCharacteristic->addDescriptor(new BLE2902());

  // Uptime Characteristic
  pUptimeCharacteristic = pService->createCharacteristic(UPTIME_CHARACTERISTIC_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  pUptimeCharacteristic->addDescriptor(new BLE2902());

  // Reboot Characteristic
  pRebootCharacteristic = pService->createCharacteristic(REBOOT_CHARACTERISTIC_UUID, BLECharacteristic::PROPERTY_WRITE);
  pRebootCharacteristic->setCallbacks(new RebootCallbacks());

  pService->start();
  BLEAdvertising *pAdvertising = pServer->getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->start();

  Serial.println("BLE Server started. Waiting for a client connection...");
}

void loop() {
  // --- Core Hardware Logic (runs continuously) ---
  myTime = millis();
  floater = digitalRead(SW1R);

  // Pump timer logic
  if ((myTime > timer) && (lastState == false)) { 
    digitalWrite(pwmPomp, LOW); // Pump OFF
    lastState = true;
    timer = millis() + onTime;
  }
  if ((myTime > timer) && (lastState == true)) {
    digitalWrite(pwmPomp, HIGH); // Pump ON
    lastState = false;
    timer = millis() + offTime;
  }

  // Floater switch logic
  if (floater == HIGH) {
    evStatus = 0;
  } else if (floater == LOW) {
    evStatus = 1;
  }

  // Control a1Switch based on floater status
  if (evStatus == 1) {
    digitalWrite(a1Switch, HIGH);
  } else if (evStatus == 0) {
    digitalWrite(a1Switch, LOW);
  }

  // --- BLE Notifications (runs only when connected) ---
  if (deviceConnected) {
    unsigned long currentMillis = millis();

    // Uptime Notifications
    if (currentMillis - lastUptimeNotifyTime >= uptimeNotifyInterval) {
      lastUptimeNotifyTime = currentMillis;
      uint32_t uptimeSeconds = currentMillis / 1000;
      pUptimeCharacteristic->setValue(uptimeSeconds);
      pUptimeCharacteristic->notify();
    }

    // Debug Notifications - NOW WITH REAL DATA!
    if (currentMillis - lastDebugNotifyTime >= debugNotifyInterval) {
      lastDebugNotifyTime = currentMillis;

      StaticJsonDocument<256> doc;
      
      // Populate JSON with live data from your hardware
      doc["floater_pin"] = floater;
      doc["evStatus"] = evStatus;
      doc["a1Switch_state"] = digitalRead(a1Switch);
      doc["pump_pin_state"] = digitalRead(pwmPomp);
      doc["pump_cycle"] = (lastState == true) ? "OFF_PERIOD" : "ON_PERIOD";
      doc["next_pump_event_ms"] = timer;
      doc["onTime_ms"] = onTime;   // Report current onTime
      doc["offTime_ms"] = offTime; // Report current offTime
      
      char jsonBuffer[256];
      serializeJson(doc, jsonBuffer);

      pDebugCharacteristic->setValue(jsonBuffer);
      pDebugCharacteristic->notify();

      Serial.print("Debug JSON sent: ");
      Serial.println(jsonBuffer);
    }
  }

  delay(10);
}


