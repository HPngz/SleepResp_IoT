import SwiftUI
import CoreBluetooth

struct ContentView: View {
    @StateObject private var ble = BLEManager()
    
    var body: some View {
        NavigationStack {
            Page1View(ble: ble)
        }
    }
}

// 第一页：连接蓝牙
struct Page1View: View {
    @ObservedObject var ble: BLEManager
    
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 60))
                .foregroundStyle(.blue)
            
            Text("ESP32 BLE")
                .font(.largeTitle.bold())
            
            Text(ble.connectionStateText)
                .foregroundStyle(ble.connectionStateColor)
            
            if let err = ble.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            
            // 设备列表
            if !ble.discoveredDevices.isEmpty {
                List(ble.discoveredDevices) { device in
                    Button {
                        ble.stopScanning()
                        ble.connect(to: device)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.displayName).font(.headline)
                                Text("Signal: \(device.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if ble.connectedPeripheral?.identifier == device.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else if case .connecting = ble.connectionState {
                                ProgressView().scaleEffect(0.8)  // 连接中转圈
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(ble.isConnecting)  // 连接中禁止重复点击
                }
                .frame(maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            
            Spacer()
            
            // 底部按钮
            if case .connected = ble.connectionState {
                NavigationLink(destination: Page2View(ble: ble)) {
                    Text("Enter")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal)
            } else {
                Button {
                    ble.isScanning ? ble.stopScanning() : ble.startScanning()
                } label: {
                    HStack {
                        if ble.isScanning { ProgressView().scaleEffect(0.8).tint(.white) }
                        Text(ble.isScanning ? "Scanning..." : "Start Scanning")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal)
            }
        }
        .padding()
        .navigationBarHidden(true)
        
    }
}

// 第二页：Hello + 查看健康数据
struct Page2View: View {
    @ObservedObject var ble: BLEManager
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部 Hello
            Text("Hello 👋")
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 20)
            
            Spacer()
            
            // 查看健康数据按钮
            NavigationLink(destination: Page3View(ble: ble)) {
                HStack {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
                    Text("View Health Data")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal)
            .padding(.bottom, 40)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Disconnect", role: .destructive) {
                    ble.disconnect()
                }
            }
        }
    }
}

// 第三页：健康数据
struct Page3View: View {
    @ObservedObject var ble: BLEManager
    
    var heartRate: String {
        guard let range = ble.lastReceivedValue.range(of: "HR:") else { return "--" }
        let after = ble.lastReceivedValue[range.upperBound...]
        return String(after.prefix(while: { $0.isNumber }))
    }
    
    var spo2: String {
        guard let range = ble.lastReceivedValue.range(of: "SpO2:") else { return "--" }
        let after = ble.lastReceivedValue[range.upperBound...]
        return String(after.prefix(while: { $0.isNumber }))
    }
    
    var breathRR: String {
        guard let range = ble.lastReceivedValue.range(of: "RR:") else { return "--" }
        let after = ble.lastReceivedValue[range.upperBound...]
        return String(after.prefix(while: { $0.isNumber || $0 == "." }))
    }

    var breathAmp: String {
        guard let range = ble.lastReceivedValue.range(of: "Amp:") else { return "--" }
        let after = ble.lastReceivedValue[range.upperBound...]
        return String(after.prefix(while: { $0.isNumber || $0 == "." }))
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                DataCard(title: "Heart Rate", value: heartRate, unit: "BPM", icon: "heart.fill", color: .red)
                DataCard(title: "Blood Oxygen", value: spo2, unit: "%", icon: "lungs.fill", color: .blue)
                DataCard(title: "Breath Rate", value: breathRR, unit: "RPM", icon: "wind", color: .green)
                DataCard(title: "Breath Depth", value: breathAmp, unit: "°", icon: "arrow.up.and.down", color: .orange)
            }
            .padding()
        }
        .navigationTitle("Health Data")
        .navigationBarTitleDisplayMode(.large)
    }
}

// 数据卡片
struct DataCard: View {
    let title: String
    let value: String
    let unit: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: icon).foregroundStyle(color).font(.title2)
                Text(title).font(.headline).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(value)
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                Text(unit).font(.title2).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(24)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(color.opacity(0.3), lineWidth: 1))
    }
}

extension BLEManager {
    var connectionStateText: String {
        switch connectionState {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected ✅"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }
    
    var connectionStateColor: Color {
        switch connectionState {
        case .disconnected: return .secondary
        case .connecting: return .orange
        case .connected: return .green
        case .failed: return .red
        }
    }
}

extension CBCharacteristic: @retroactive Identifiable {
    public var id: CBUUID { uuid }
}

#Preview {
    ContentView()
}
