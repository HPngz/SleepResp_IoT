#include <Wire.h>
#include "MAX30105.h"
#include "heartRate.h"

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

// 血氧平均 
#define SPO2_AVG_SIZE 4
float spo2Buffer[SPO2_AVG_SIZE];
int spo2Spot = 0;

#define FINGER_THRESHOLD 10000

void setup() {
  Serial.begin(115200);
  Wire.begin(8, 9);

  if (!particleSensor.begin(Wire)) {
    Serial.println("MAX30102 not found");
    while (1);
  }

  particleSensor.setup();
  particleSensor.setPulseAmplitudeRed(0x2A);
  particleSensor.setPulseAmplitudeIR(0x2A);
}

void loop() {
  irValue = particleSensor.getIR();
  long red = particleSensor.getRed();

  if (irValue < FINGER_THRESHOLD) {
    Serial.println("No finger detected");
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

    // 血氧平均
    spo2Buffer[spo2Spot++] = spo2;
    spo2Spot %= SPO2_AVG_SIZE;

    float spo2Avg = 0;
    for (int i = 0; i < SPO2_AVG_SIZE; i++) spo2Avg += spo2Buffer[i];
    spo2Avg /= SPO2_AVG_SIZE;

    // 心率有值才输出
    if (beatAvg > 0) {
      Serial.print("HR: ");
      Serial.print(beatAvg);
      Serial.print(" bpm | SpO2: ");
      Serial.print((int)spo2Avg);
      Serial.println(" %");
    }
  }
}