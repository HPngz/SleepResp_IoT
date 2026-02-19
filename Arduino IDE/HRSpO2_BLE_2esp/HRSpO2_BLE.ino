#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <Wire.h>
#include "MAX30105.h"
#include "heartRate.h"

#define SERVICE_UUID        "aa11bb22-1234-1234-1234-aa11bb22cc33"  // 改成新的
#define CHARACTERISTIC_UUID "bb22cc33-1234-1234-1234-bb22cc33dd44"  // 改成新的
#define WRITE_UUID          "beb5483e-36e1-4688-b7f5-ea07361b26a9"

BLEServer* pServer = NULL;
BLECharacteristic* pCharacteristic = NULL;
BLECharacteristic* pWriteCharacteristic = NULL;
bool deviceConnected = false;

MAX30105 particleSensor;

// ---------- 心率 ----------
long irValue;
int beatAvg;
const byte RATE_SIZE = 4;
byte rates[RATE_SIZE];
byte rateSpot = 0;
long lastBeat = 0;

// ---------- 血氧 ----------
#define WINDOW 100
long irBuffer[WINDOW];
long redBuffer[WINDOW];
int bufferIndex = 0;

#define SPO2_AVG_SIZE 4
float spo2Buffer[SPO2_AVG_SIZE];
int spo2Spot = 0;

#define FINGER_THRESHOLD 10000

class MyWriteCallbacks: public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pCharacteristic) {
    String value = String(pCharacteristic->getValue().c_str());
    if (value.length() > 0) {
      Serial.print("📥 Received: ");
      Serial.println(value);
    }
  }
};

class MyServerCallbacks: public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    deviceConnected = true;
    Serial.println("✅ APP connected");
  };
  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;
    Serial.println("❌ APP disconnected");
    pServer->startAdvertising();
  }
};

void setup() {
  Serial.begin(115200);
  delay(1000);

  Wire.begin(8, 9);
  if (!particleSensor.begin(Wire)) {
    Serial.println("MAX30102 not found");
    while (1);
  }
  particleSensor.setup();
  particleSensor.setPulseAmplitudeRed(0x2A);
  particleSensor.setPulseAmplitudeIR(0x2A);

  BLEDevice::init("ESP32-MAX");
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  BLEService *pService = pServer->createService(SERVICE_UUID);

  pCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_READ |
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pCharacteristic->addDescriptor(new BLE2902());

  pWriteCharacteristic = pService->createCharacteristic(
    WRITE_UUID,
    BLECharacteristic::PROPERTY_WRITE |
    BLECharacteristic::PROPERTY_WRITE_NR
  );
  pWriteCharacteristic->setCallbacks(new MyWriteCallbacks());

  pService->start();
  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  BLEDevice::startAdvertising();

  Serial.println("🔍 ESP32 BLE started. Waiting for connection...");
}

void loop() {
  irValue = particleSensor.getIR();
  long red = particleSensor.getRed();

  if (irValue < FINGER_THRESHOLD) {
    beatAvg = 0;
    bufferIndex = 0;
    rateSpot = 0;
    spo2Spot = 0;
    memset(rates, 0, sizeof(rates));
    memset(spo2Buffer, 0, sizeof(spo2Buffer));
    delay(500);
    return;
  }

  // ---------- 心率 ----------
  if (checkForBeat(irValue)) {
    long delta = millis() - lastBeat;
    lastBeat = millis();
    int bpm = 60 / (delta / 1000.0);
    if (bpm > 40 && bpm < 180) {
      rates[rateSpot++] = bpm;
      rateSpot %= RATE_SIZE;
      beatAvg = 0;
      for (byte i = 0; i < RATE_SIZE; i++) beatAvg += rates[i];
      beatAvg /= RATE_SIZE;
    }
  }

  // ---------- 血氧 ----------
  irBuffer[bufferIndex]  = irValue;
  redBuffer[bufferIndex] = red;
  bufferIndex++;

  if (bufferIndex >= WINDOW) {
    bufferIndex = 0;

    float irDC = 0, redDC = 0;
    long irMax = irBuffer[0], irMin = irBuffer[0];
    long redMax = redBuffer[0], redMin = redBuffer[0];

    for (int i = 0; i < WINDOW; i++) {
      irDC  += irBuffer[i];
      redDC += redBuffer[i];
      irMax  = max(irMax, irBuffer[i]);
      irMin  = min(irMin, irBuffer[i]);
      redMax = max(redMax, redBuffer[i]);
      redMin = min(redMin, redBuffer[i]);
    }

    irDC  /= WINDOW;
    redDC /= WINDOW;

    float irAC  = irMax - irMin;
    float redAC = redMax - redMin;

    float R = (redAC / redDC) / (irAC / irDC);
    float spo2 = 110.0 - 25.0 * R;
    spo2 = constrain(spo2, 70, 100);

    spo2Buffer[spo2Spot++] = spo2;
    spo2Spot %= SPO2_AVG_SIZE;

    float spo2Avg = 0;
    for (int i = 0; i < SPO2_AVG_SIZE; i++) spo2Avg += spo2Buffer[i];
    spo2Avg /= SPO2_AVG_SIZE;

    if (beatAvg > 0) {
      String payload = "HR:" + String(beatAvg) + " SpO2:" + String((int)spo2Avg);
      Serial.println(payload);

      if (deviceConnected) {
        pCharacteristic->setValue(payload.c_str());
        pCharacteristic->notify();
      }
    }
  }
}