#include <Wire.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <BLEClient.h>
#include <BLEScan.h>
#include <BLEAdvertisedDevice.h>

#define MPU_SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define MPU_CHARACTERISTIC_UUID "12345678-1234-1234-1234-123456789abd"
#define MAX_SERVICE_UUID        "aa11bb22-1234-1234-1234-aa11bb22cc33"
#define MAX_CHARACTERISTIC_UUID "bb22cc33-1234-1234-1234-bb22cc33dd44"

#define MPU_ADDR 0x68

BLEServer* pServer = NULL;
BLECharacteristic* pCharacteristic = NULL;
bool phoneConnected = false;

BLEClient* pClient = NULL;
BLERemoteCharacteristic* pRemoteCharacteristic = NULL;
bool maxConnected = false;
bool doScan = true;
bool doConnect = false;
BLEAdvertisedDevice* targetDevice = nullptr;

int remoteHR = 0;
int remoteSpo2 = 0;

// ========== 卡尔曼滤波 ==========
class KalmanFilter {
public:
  float Q = 0.01;  // 调大让呼吸信号通过
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

// 幅度滑动平均
#define AMP_AVG_SIZE 5
float ampHistory[AMP_AVG_SIZE] = {0};
int ampHistIndex = 0;
float smoothAmplitude = 0;

// ========== 过零点检测 ==========
float lastPitchAC = 0;
bool wasRising = false;

// ========== 滑动均值 ==========
float pitchHistory[100] = {0};
float pitchSum = 0;
int histIndex = 0;

// ========== BLE发送计时 ==========
unsigned long lastBLESendTime = 0;
#define BLE_SEND_INTERVAL 5000

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

// ========== MAX通知回调 ==========
void notifyCallback(BLERemoteCharacteristic* pChar, uint8_t* pData, size_t length, bool isNotify) {
  String value = String((char*)pData).substring(0, length);
  Serial.print("📥 从MAX收到: "); Serial.println(value);

  if (value.indexOf("HR:") >= 0) {
    int hrIdx = value.indexOf("HR:") + 3;
    remoteHR = value.substring(hrIdx).toInt();
  }
  if (value.indexOf("SpO2:") >= 0) {
    int spo2Idx = value.indexOf("SpO2:") + 5;
    remoteSpo2 = value.substring(spo2Idx).toInt();
  }
}

// ========== 扫描回调 ==========
class MyAdvertisedDeviceCallbacks: public BLEAdvertisedDeviceCallbacks {
  void onResult(BLEAdvertisedDevice advertisedDevice) {
    if (advertisedDevice.getName() == "ESP32-MAX") {
      Serial.println("✅ 找到ESP32-MAX");
      BLEDevice::getScan()->stop();
      targetDevice = new BLEAdvertisedDevice(advertisedDevice);
      doConnect = true;
    }
  }
};

// ========== 连接MAX ==========
void connectToMAX() {
  Serial.println("🔗 开始连接ESP32-MAX...");
  pClient = BLEDevice::createClient();
  pClient->connect(targetDevice);
  delay(1000);
  Serial.println("✅ 已连接ESP32-MAX");

  BLERemoteService* pService = pClient->getService(MAX_SERVICE_UUID);
  if (pService == nullptr) {
    Serial.println("❌ 找不到MAX的服务");
    pClient->disconnect();
    maxConnected = false;
    doConnect = false;
    doScan = true;
    return;
  }

  pRemoteCharacteristic = pService->getCharacteristic(MAX_CHARACTERISTIC_UUID);
  if (pRemoteCharacteristic == nullptr) {
    Serial.println("❌ 找不到MAX的特征");
    pClient->disconnect();
    maxConnected = false;
    doConnect = false;
    doScan = true;
    return;
  }

  if (pRemoteCharacteristic->canNotify()) {
    pRemoteCharacteristic->registerForNotify(notifyCallback);
    Serial.println("✅ 订阅MAX通知成功");
  }

  maxConnected = true;
  doConnect = false;
  doScan = false;
}

// ========== 手机连接回调 ==========
class MyServerCallbacks: public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    phoneConnected = true;
    Serial.println("✅ 手机已连接");
  }
  void onDisconnect(BLEServer* pServer) {
    phoneConnected = false;
    Serial.println("❌ 手机已断开");
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

  BLEService *pService = pServer->createService(MPU_SERVICE_UUID);
  pCharacteristic = pService->createCharacteristic(
    MPU_CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_READ |
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pCharacteristic->addDescriptor(new BLE2902());
  pService->start();

  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(MPU_SERVICE_UUID);
  BLEDevice::startAdvertising();
  Serial.println("🔍 手机可以连接了");

  BLEScan* pScan = BLEDevice::getScan();
  pScan->setAdvertisedDeviceCallbacks(new MyAdvertisedDeviceCallbacks());
  pScan->setActiveScan(true);
  pScan->start(10, false);
  Serial.println("🔍 扫描ESP32-MAX...");
}

void loop() {
  if (doConnect) {
    connectToMAX();
    return;
  }

  if (!maxConnected && doScan) {
    Serial.println("🔍 重新扫描ESP32-MAX...");
    BLEDevice::getScan()->start(5, false);
    doScan = false;
    delay(5000);
    doScan = true;
  }

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

  // ========== 滑动窗口FFT ==========
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

  // ========== 呼吸幅度 + 滑动平均 ==========
  pitchACMax = max(pitchACMax, pitchAC);
  pitchACMin = min(pitchACMin, pitchAC);

  bool isRising = pitchAC > lastPitchAC;
  if (isRising && !wasRising && pitchAC > 0.1) {
    breathAmplitude = pitchACMax - pitchACMin;
    pitchACMax = 0;
    pitchACMin = 0;

    // 存入历史取平均
    ampHistory[ampHistIndex] = breathAmplitude;
    ampHistIndex = (ampHistIndex + 1) % AMP_AVG_SIZE;

    float sum = 0;
    for (int i = 0; i < AMP_AVG_SIZE; i++) sum += ampHistory[i];
    smoothAmplitude = sum / AMP_AVG_SIZE;
  }
  wasRising = isRising;
  lastPitchAC = pitchAC;

  // ========== 串口调试 ==========
  Serial.print("RR:"); Serial.print(breathRPM, 1);
  Serial.print(" Amp:"); Serial.print(smoothAmplitude, 2);
  Serial.print(" HR:"); Serial.print(remoteHR);
  Serial.print(" SpO2:"); Serial.println(remoteSpo2);

  // ========== BLE发送给手机（每5秒）==========
  if (millis() - lastBLESendTime >= BLE_SEND_INTERVAL && phoneConnected) {
    lastBLESendTime = millis();
    String payload = "HR:" + String(remoteHR) +
                     " SpO2:" + String(remoteSpo2) +
                     " RR:" + String(breathRPM, 1) +
                     " Amp:" + String(smoothAmplitude, 2);
    pCharacteristic->setValue(payload.c_str());
    pCharacteristic->notify();
    Serial.print("📤 发给手机: "); Serial.println(payload);
  }
}