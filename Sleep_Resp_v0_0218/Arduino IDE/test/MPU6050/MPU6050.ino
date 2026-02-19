#include <Wire.h>

#define MPU_ADDR 0x68

void setup() {
  Serial.begin(115200);
  Wire.begin(8, 9);
  delay(1000);

  // 唤醒MPU6050（默认是睡眠模式）
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x6B);  // PWR_MGMT_1 寄存器
  Wire.write(0);     // 写0唤醒
  Wire.endTransmission(true);

  Serial.println("✅ MPU6050 已唤醒");
}

void loop() {
  Wire.beginTransmission(MPU_ADDR);
  Wire.write(0x3B);  // 从加速度寄存器开始读
  Wire.endTransmission(false);
  Wire.requestFrom(MPU_ADDR, 6, true);

  int16_t ax = Wire.read() << 8 | Wire.read();
  int16_t ay = Wire.read() << 8 | Wire.read();
  int16_t az = Wire.read() << 8 | Wire.read();

  float axG = ax / 16384.0;
  float ayG = ay / 16384.0;
  float azG = az / 16384.0;
  float total = sqrt(axG*axG + ayG*ayG + azG*azG);

  Serial.print("AX: "); Serial.print(axG, 2);
  Serial.print("  AY: "); Serial.print(ayG, 2);
  Serial.print("  AZ: "); Serial.print(azG, 2);
  Serial.print("  Total: "); Serial.println(total, 2);

  delay(200);
}