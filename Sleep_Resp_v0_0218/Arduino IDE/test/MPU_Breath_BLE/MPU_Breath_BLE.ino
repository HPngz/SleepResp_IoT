#include <Wire.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHARACTERISTIC_UUID "12345678-1234-1234-1234-123456789abd"
#define MPU_ADDR 0x68

BLEServer* pServer = NULL;
BLECharacteristic* pCharacteristic = NULL;
bool deviceConnected = false;

// ========== 卡尔曼滤波 ==========
class KalmanFilter {
public:
  float Q = 0.001;
  float R = 0.1;
  float P = 1.0;
  float x = 0.0;

  float update(float m) {
    P += Q;
    float K = P / (P + R);
    x += K * (m - x);
    P *= (1 - K);
    return x;
  }
};

KalmanFilter kfPitch;

// ========== FFT参数 ==========
#define SAMPLE_RATE     10
#define FFT_SIZE        256
#define SLIDE_INTERVAL  50
float pitchSamples[FFT_SIZE];
int sampleIndex = 0;
int newSamples = 0;
float breathRPM = 0;
unsigned long lastSampleTime = 0;

// ========== 翻身检测 ==========
#define TURN_THRESHOLD  30.0
#define TURN_IGNORE_MS  4000
float lastPitch = 0;
bool isTurning = false;
unsigned long turnTime = 0;

// ========== 呼吸幅度 ==========
float pitchACMax = 0;
float pitchACMin = 0;
float breathAmplitude = 0;

// ========== 过零点检测 ==========
float lastPitchAC = 0;
bool wasRising = false;

// ========== 滑动均值 ==========
float pitchHistory[100] = {0};
float pitchSum = 0;
int histIndex = 0;

// ========== BLE发送计时 ==========
unsigned long lastBLESendTime = 0;
#define BLE_SEND_INTERVAL 5000  // 5秒发一次

// ========== FFT计算 ==========
float computeRR() {
  float mean = 0;
  for (int i = 0; i < FFT_SIZE; i++) mean += pitchSamples[i];
  mean /= FFT_SIZE;

  float maxPower = 0;
  float bestFreq = 0;

  int binMin = (int)(0.1 * FFT_SIZE / SAMPLE_RATE);
  int binMax = (int)(0.5 * FFT_SIZE / SAMPLE_RATE);

  for (int k = binMin; k <= binMax; k++) {
    float real = 0, imag = 0;
    for (int n = 0; n < FFT_SIZE; n++) {
      float angle = 2.0 * PI * k * n / FFT_SIZE;
      real += (pitchSamples[n] - mean) * cos(angle);
      imag += (pitchSamples[n] - mean) * sin(angle);
    }
    float power = real * real + imag * imag;
    if (power > maxPower) {
      maxPower = power;
      bestFreq = (float)k * SAMPLE_RATE / FFT_SIZE;
    }
  }

  return bestFreq * 60.0;
}

class MyServerCallbacks: public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    deviceConnected = true;
    Serial.println("✅ Connected");
  }
  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;
    Serial.println("❌ Disconnected");
    pServer->startAdvertising();
  }
};

void setup() {
  Serial.begin(115200);
  Wire.begin(8, 9);
  delay(1000);

  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x6B);
  Wire.write(0);
  Wire.endTransmission(true);
  Serial.println("✅ MPU6050 ready");

  BLEDevice::init("ESP32-MPU");
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  BLEService *pService = pServer->createService(SERVICE_UUID);
  pCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_READ |
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pCharacteristic->addDescriptor(new BLE2902());
  pService->start();

  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  BLEDevice::startAdvertising();
  Serial.println("🔍 BLE advertising...");
}

void loop() {
  if (millis() - lastSampleTime < (1000 / SAMPLE_RATE)) return;
  lastSampleTime = millis();

  // ========== 读MPU6050 ==========
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x3B);
  Wire.endTransmission(false);
  Wire.requestFrom(MPU_ADDR, 6, true);

  int16_t ax = Wire.read() << 8 | Wire.read();
  int16_t ay = Wire.read() << 8 | Wire.read();
  int16_t az = Wire.read() << 8 | Wire.read();

  float axG = ax / 16384.0;
  float ayG = ay / 16384.0;
  float azG = az / 16384.0;

  float rawPitch = atan2(ayG, sqrt(axG*axG + azG*azG)) * 180.0 / PI;
  float pitch = kfPitch.update(rawPitch);

  // ========== 翻身检测 ==========
  float pitchDelta = abs(pitch - lastPitch);
  if (pitchDelta > TURN_THRESHOLD) {
    isTurning = true;
    turnTime = millis();
    Serial.println("🔄 翻身，暂停采集");
  }
  lastPitch = pitch;

  if (isTurning) {
    if (millis() - turnTime > TURN_IGNORE_MS) {
      isTurning = false;
      Serial.println("✅ 恢复采集");
    } else {
      return;
    }
  }

  // ========== 滑动窗口FFT（一直在计算）==========
  pitchSamples[sampleIndex % FFT_SIZE] = pitch;
  sampleIndex++;
  newSamples++;

  if (sampleIndex >= FFT_SIZE && newSamples >= SLIDE_INTERVAL) {
    newSamples = 0;
    breathRPM = computeRR();
  }

  // ========== 去直流 ==========
  pitchSum -= pitchHistory[histIndex];
  pitchHistory[histIndex] = pitch;
  pitchSum += pitch;
  histIndex = (histIndex + 1) % 100;
  float pitchMean = pitchSum / 100.0;
  float pitchAC = pitch - pitchMean;

  // ========== 呼吸幅度（一直在计算）==========
  pitchACMax = max(pitchACMax, pitchAC);
  pitchACMin = min(pitchACMin, pitchAC);

  bool isRising = pitchAC > lastPitchAC;
  if (isRising && !wasRising && pitchAC > 0.1) {
    breathAmplitude = pitchACMax - pitchACMin;
    pitchACMax = 0;
    pitchACMin = 0;
  }
  wasRising = isRising;
  lastPitchAC = pitchAC;

  // ========== 串口调试（一直打印）==========
  Serial.print("RR:"); Serial.print(breathRPM, 1);
  Serial.print(" Amp:"); Serial.println(breathAmplitude, 2);

  // ========== BLE发送（每5秒发一次）==========
  if (millis() - lastBLESendTime >= BLE_SEND_INTERVAL && deviceConnected) {
    lastBLESendTime = millis();
    String payload = "RR:" + String(breathRPM, 1) +
                     " Amp:" + String(breathAmplitude, 2);
    pCharacteristic->setValue(payload.c_str());
    pCharacteristic->notify();
    Serial.print("📤 BLE发送: "); Serial.println(payload);
  }
}