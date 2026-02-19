import Foundation
import CoreBluetooth
import Combine

// MARK: - 数据模型 Data Model
/// 蓝牙设备信息 Bluetooth device information
struct BLEDevice: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int          // 信号强度signal intensity
    let peripheral: CBPeripheral  // CoreBluetooth 的设备对象 device object
    
    /// 设备名称 Device name
    var displayName: String {
        name.isEmpty ? "Unknown Device (\(id.uuidString.prefix(8)))" : name
    }
}

/// 蓝牙连接状态 Bluetooth Status
enum BLEConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

// MARK: - 蓝牙管理器主类 Bluetooth manager
/// 蓝牙管理器：负责扫描、连接、收发数据
/// ObservableObject 让 SwiftUI 能自动更新界面
/// NSObject 是 CoreBluetooth 代理的基类要求
final class BLEManager: NSObject, ObservableObject {
    
    // MARK: - 发布的状态变量 Status variable
    /// 是否正在扫描设备 Is scanning Device
    @Published private(set) var isScanning = false
    
    /// 扫描到的设备列表 Device list
    @Published private(set) var discoveredDevices: [BLEDevice] = []
    
    /// 当前连接状态 Current connecting status
    @Published private(set) var connectionState: BLEConnectionState = .disconnected
    
    /// 已连接的设备 Connected devices
    @Published private(set) var connectedPeripheral: CBPeripheral?
    
    /// 是否正在连接中 Is connecting?
    var isConnecting: Bool {
        if case .connecting = connectionState { return true }
        return false
    }
    
    /// 已发现的服务列表 Discovered Service List
    @Published private(set) var services: [CBService] = []
    
    /// 已发现的特征列表 Discovered Feature
    @Published private(set) var characteristics: [CBCharacteristic] = []
    
    /// 接收到的文本缓冲区 Received text buffer
    @Published var receivedText: String = ""
    
    /// 最近一次收到的值 Last received value
    @Published private(set) var lastReceivedValue: String = ""
    
    /// 最后的错误信息 Last Error
    @Published var lastError: String?
    
    // MARK: - 调试相关 Debugging
    @Published var debugLog: String = ""
    
    // MARK: - 可选配置 Optional configuration
    /// 过滤器：只扫描包含指定 Service UUID 的设备
    /// 如果为 nil，则扫描所有蓝牙设备
    //var filterServiceUUIDs: [CBUUID]? = nil
    var filterServiceUUIDs: [CBUUID]? = [CBUUID(string: "4fafc201-1fb5-459e-8fcc-c5c9c331914b")]
    
    // MARK: - 私有变量（内部使用）
    /// 中心管理器（负责扫描和连接设备）Scanning and Connecting
    private var centralManager: CBCentralManager!
    
    /// 当前连接的外设 Current device
    private var peripheralManager: CBPeripheral?
    
    /// 用于写入数据的特征（发送数据到 ESP32）Sending data
    private var writeCharacteristic: CBCharacteristic?
    
    /// 用于接收通知的特征（从 ESP32 接收数据） Receiving data
    private var notifyCharacteristic: CBCharacteristic?
    
    /// 待订阅的通知特征（临时存储）Notification features for subscription (temporary storage)
    private var pendingNotifyCharacteristic: CBCharacteristic?
    
    // MARK: - 初始化 Initialization
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }
    
    // MARK: - 调试日志方法 Debugging log
    private func log(_ message: String) {
        // 获取当前时间 Get current time
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logMessage = "[\(timestamp)] \(message)"
        print(logMessage)
        debugLog += logMessage + "\n"
    }
    
    // MARK: - 扫描设备 Scanning Device
    func startScanning() {
        guard centralManager.state == .poweredOn else {
            lastError = "Please turn on Bluetooth"
            log("❌ Scan failed: Bluetooth is not turned on")
            return
        }
        
        // 清空之前扫描到的设备 Remove previous devices
        discoveredDevices.removeAll()
        isScanning = true
        lastError = nil
        log("🔍 Start scanning the BLE device...")
        
        // 开始扫描 Start scanning
        // withServices: filterServiceUUIDs - 可选的服务过滤器
        // allowDuplicates: false - 同一设备只报告一次
        centralManager.scanForPeripherals(
            withServices: filterServiceUUIDs,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }
    
    /// 停止扫描 Stop scanning
    func stopScanning() {
        centralManager.stopScan()
        isScanning = false
        log("⏸️ Stop Scannning")
    }
    
    // MARK: - 连接和断开 Connect and Disconnect
    func connect(to device: BLEDevice) {
        stopScanning()
        connectionState = .connecting
        connectedPeripheral = nil
        peripheralManager = device.peripheral
        peripheralManager?.delegate = self
        log("🔗 Connecting to: \(device.displayName)")
        
        // 等扫描完全停止再连接
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.centralManager.connect(device.peripheral, options: nil)
        }
    }
    
    /// 连接到外设（另一种方式） Connect to peripheral devices (in another way)
    func connect(peripheral: CBPeripheral) {
        stopScanning()
        connectionState = .connecting
        connectedPeripheral = nil
        peripheralManager = peripheral
        peripheralManager?.delegate = self
        log("🔗 Connecting to: \(peripheral.name ?? "Unknown device")")
        centralManager.connect(peripheral, options: nil)
    }
    
    /// 断开当前连接 Disconnect
    func disconnect() {
        guard let p = peripheralManager else { return }
        log("🔌 Disconnect")
        centralManager.cancelPeripheralConnection(p)
        cleanup()
    }
    
    /// 清理所有连接相关的资源 Cleanup
    private func cleanup() {
        writeCharacteristic = nil
        notifyCharacteristic = nil
        services = []
        characteristics = []
        peripheralManager = nil
        connectedPeripheral = nil
        connectionState = .disconnected
        receivedText = ""
        lastReceivedValue = ""
    }
    
    // MARK: - 发现服务和特征 Discover services and features
    /// 手动触发发现服务
    /// 注意：连接成功后会自动调用，一般不需要手动调用
    /// After a successful connection, it will be automatically invoked and generally does not require manual invocation
    func discoverServices() {
        log("🔎 Manual discovery service")
        peripheralManager?.discoverServices(nil)  // nil 表示发现所有服务 discovery of all services
    }
    
    /// 发现某个服务的所有特征 Discover all the features of a certain service
    func discoverCharacteristics(for service: CBService) {
        log("🔎 Discover service characteristics: \(service.uuid)")
        peripheralManager?.discoverCharacteristics(nil, for: service)
    }
    
    // MARK: - 数据收发 Data collect and send
    func subscribeToNotifications(for characteristic: CBCharacteristic) {
        guard let p = peripheralManager else { return }
        lastError = nil
        pendingNotifyCharacteristic = characteristic
        log("📬 Prepare to subscribe notification: \(characteristic.uuid)")
        
        // 直接订阅，不等描述符 Subscribe directly without waiting for descriptors
        // 大部分 ESP32 设备不需要先发现描述符就能工作
        notifyCharacteristic = characteristic
        p.setNotifyValue(true, for: characteristic)
        p.discoverDescriptors(for: characteristic)
    }
    
    /// 设置用于发送数据的特征 Set the features used for sending data
    func setWriteCharacteristic(_ characteristic: CBCharacteristic) {
        writeCharacteristic = characteristic
        log("✍️ Set write characteristics: \(characteristic.uuid)")
    }
    
    /// 发送文本到 ESP32   Sending to esp32
    func send(_ text: String) {
        // 将文本转为 UTF-8 数据 Convert the text to UTF-8 data
        guard let data = text.data(using: .utf8),
              let char = writeCharacteristic else {
            lastError = "No writable features were selected or encoding was impossible"
            log("❌ Sending Failed：\(lastError ?? "")")
            return
        }
        log("📤 Sending Data: \(text)")
        peripheralManager?.writeValue(data, for: char, type: .withResponse)
    }
    
    /// 发送原始数据到 ESP32 Sending original data to esp32
    func send(data: Data) {
        guard let char = writeCharacteristic else {
            lastError = "No writable features were selected"
            log("❌ Failed to send: No writable feature was selected")
            return
        }
        log("📤 Sending Data: \(data.count) byte")
        peripheralManager?.writeValue(data, for: char, type: .withResponse)
    }
    
    /// 清空接收区的显示内容 Clear Received
    func clearReceived() {
        receivedText = ""
        lastReceivedValue = ""
        log("🗑️ Clear the receiving buffer")
    }
    
    /// 自动绑定 ESP32 的常用特征
    /// 会自动找到"可写"和"可通知"的特征并绑定
    /// Automatically find the "writable" and "notificable" features and bind them
    func tryBindCommonESP32Characteristics() {
        log("🔧 Try to automatically bind features...")
        var foundWrite = false
        var foundNotify = false
        
        // 遍历所有服务 Traverse all services
        for service in services {
            guard let chars = service.characteristics else { continue }
            
            // 遍历服务中的所有特征 Traverse all characteristics
            for c in chars {
                let props = c.properties
                log("  特征 \(c.uuid): \(describeProperties(props))")
                
                // 查找可写特征 Search for writable features
                if (props.contains(.write) || props.contains(.writeWithoutResponse)) && !foundWrite {
                    writeCharacteristic = c
                    foundWrite = true
                    log("  ✅ Set it as a write feature")
                }
                
                // 查找可通知特征 Search for notified features
                if (props.contains(.notify) || props.contains(.indicate)) && !foundNotify {
                    subscribeToNotifications(for: c)
                    foundNotify = true
                    log("  ✅ Subscribe to Notifications")
                }
            }
        }
        
        // 检查是否找到了必要的特征 Check whether the necessary features have been found
        if !foundWrite {
            log("⚠️ No writable features were found")
        }
        if !foundNotify {
            log("⚠️ No notificable features were found")
        }
    }
    
    /// 将特征属性转为可读文本 Convert the feature attributes into readable text
    private func describeProperties(_ props: CBCharacteristicProperties) -> String {
        var desc: [String] = []
        if props.contains(.read) { desc.append("Read") }
        if props.contains(.write) { desc.append("Write") }
        if props.contains(.writeWithoutResponse) { desc.append("WriteNoResp") }
        if props.contains(.notify) { desc.append("Notify") }
        if props.contains(.indicate) { desc.append("Indicate") }
        return desc.joined(separator: ", ")
    }
}

// MARK: - 中心管理器代理（处理扫描和连接事件） Scan and Connecting
extension BLEManager: CBCentralManagerDelegate {
    
    /// 蓝牙状态变化时调用 It is called when the Bluetooth status changes
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            lastError = nil
            log("✅ Bluetooth turns on")
        case .poweredOff:
            lastError = "Bluetooth turns off"
            log("🔴 Buetooth turns off")
        case .unauthorized:
            lastError = "Bluetooth not authorized"
            log("⚠️ Bluetooth not authorized")
        case .unsupported:
            lastError = "The device does not support Bluetooth"
            log("⚠️ The device does not support Bluetooth")
        case .resetting:
            lastError = "The Bluetooth is resetting"
            log("🔄 The Bluetooth is resetting")
        case .unknown:
            lastError = "The Bluetooth status is unknown"
            log("❓ The Bluetooth status is unknown")
        @unknown default:
            lastError = "The Bluetooth status is unknown"
            log("❓ Unknown status")
        }
    }
    
    /// 发现设备时调用 It is called when the device is discovered
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // 获取设备名称（优先用设备名，其次用广播名） Get device name
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        let rssi = RSSI.intValue
        let device = BLEDevice(id: peripheral.identifier, name: name, rssi: rssi, peripheral: peripheral)
        
        // 如果设备不在列表中，添加进去 If the device is not on the list, add it in
        if !discoveredDevices.contains(where: { $0.id == device.id }) {
            discoveredDevices.append(device)
            log("📱Find Device: \(device.displayName) (RSSI: \(rssi))")
        }
    }
    
    /// 连接成功时调用 Called when the connection is successful
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        connectionState = .connected
        services = []
        characteristics = []
        log("✅ Connecting to: \(peripheral.name ?? "Unknown Device")")
        log("🔎 Start DiscoverServices...")
        peripheral.discoverServices(nil)
    }
    
    /// 连接失败时调用 Called when the connection fails
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionState = .failed(error?.localizedDescription ?? "Connection Failed")
        log("❌ Connection Failed: \(error?.localizedDescription ?? "Unknown Error")")
        cleanup()
    }
    
    /// 断开连接时调用 Called when disconnected
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("🔌 Disconnected")
        cleanup()
    }
}

// MARK: - 外设代理（处理服务、特征、数据）Peripheral proxy (processing services, features, data)
extension BLEManager: CBPeripheralDelegate {
    
    /// 发现服务时调用 It is called when a service is discovered
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let e = error {
            lastError = e.localizedDescription
            log("❌ Discover service failure: \(e.localizedDescription)")
            return
        }
        
        services = peripheral.services ?? []
        log("✅ Find \(services.count) Services")
        
        // 对每个服务发现其特征 Discover the characteristics of each service
        for service in services {
            log("  Service: \(service.uuid)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    /// It is called when features are discovered
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let e = error {
            lastError = e.localizedDescription
            log("❌ Feature discovery failed: \(e.localizedDescription)")
            return
        }
        
        // 更新服务和特征列表 Update the list of services and features
        services = peripheral.services ?? []
        characteristics = services.flatMap { $0.characteristics ?? [] }
        
        log("✅ Service \(service.uuid) finds \(service.characteristics?.count ?? 0) characteristics")
        
        tryBindCommonESP32Characteristics()
    }
    
    /// 收到数据时调用 It is called when data is received
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error {
            lastError = e.localizedDescription
            log("❌ Failed to read data: \(e.localizedDescription)")
            return
        }
        
        // 获取数据
        guard let data = characteristic.value, !data.isEmpty else {
            log("⚠️ Received empty data")
            return
        }
        
        // ========== 第一步：显示原始数据（调试用）Step 1: Display the original data (for debugging purposes)==========
        // 转为十六进制字符串（如 "01 02 03"）Convert to a hexadecimal string
        let hexString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        // 转为十进制字符串（如 "1 2 3"） Convert to decimal string
        let decString = data.map { String(format: "%d", $0) }.joined(separator: " ")
        
        log("📥 Original Data [HEX]: \(hexString)")  // 如 "01 02 03"
        log("📥 Original Data [DEC]: \(decString)")  // 如 "1 2 3"
        log("📥 Length of Data: \(data.count) byte")
        
        // ========== 第二步：智能解析数据 Step 2: Intelligent data analysis==========
        
        var str = ""  // 最终显示的字符串 Final string
        
        // 情况1：检查是否为原始数字字节（0-9）
        //Situation 1: Check if it is a raw numeric byte (0-9)
        // 例如：ESP32 发送 0x01, 0x02, 0x03
        let isRawNumbers = data.allSatisfy { $0 >= 0 && $0 <= 9 }
        
        // 情况2：检查是否为 ASCII 数字字符（'0'-'9' = 48-57）
        //Situation 2: Check if it is an ASCII numeric character ('0'-'9' = 48-57)
        // 例如：ESP32 发送 "123" 的 UTF-8 编码
        let isASCIINumbers = data.allSatisfy { $0 >= 48 && $0 <= 57 }
        
        if isRawNumbers {
            // ESP32 发送的是原始数字 0x01, 0x02, 0x03
            // 将每个字节转为数字字符串，用空格分隔
            //Convert each byte to a numeric string, separated by Spaces
            str = data.map { String($0) }.joined(separator: " ")
            log("📥 ✅ Original number analysis: \(str)")
        }
        else if isASCIINumbers {
            // ESP32 发送的是 ASCII 字符 '1', '2', '3'
            // 直接转为 UTF-8 字符串
            //ASCII->UTF-8
            if let utf8 = String(data: data, encoding: .utf8) {
                str = utf8
                log("📥 ✅ ASCII number analysis: \(str)")
            }
        }
        else if let utf8 = String(data: data, encoding: .utf8) {
            // 普通的 UTF-8 字符串（文本、中文等）
            // 转换不可见字符为可见形式（方便调试）
            //Convert invisible characters to visible forms
            let visible = utf8.map { char -> String in
                let scalar = char.unicodeScalars.first!
                let value = scalar.value
                switch value {
                case 0: return "\\0"
                case 9: return "\\t"
                case 10: return "\\n"
                case 13: return "\\r"
                case 32: return "␣"
                case 33...126: return String(char)
                default: return String(format: "\\x%02X", value)
                }
            }.joined()
            
            str = utf8
            log("📥 UTF-8 analysis: \"\(visible)\"")
        }
        else {
            // 其他情况：显示为十六进制 Other cases: Displayed in hexadecimal
            str = data.map { String(format: "[%02X]", $0) }.joined()
            log("📥 HEX analysis: \(str)")
        }
        
        // ========== 第三步：更新显示 Step 3: Update the display ==========
        
        // 去掉首尾空白 Remove the blank Spaces at the beginning and end
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !trimmed.isEmpty {
            if trimmed.count == 1, !receivedText.isEmpty,
               !receivedText.hasSuffix(" "), !receivedText.hasSuffix("\n") {
                receivedText += " "
            }
            receivedText += str
            lastReceivedValue = trimmed
        } else {
            receivedText += "·"
            log("⚠️ Receive empty character")
        }
        
        log("📊 Receive buffer updates: \(receivedText.suffix(50))...")
    }
    
    /// It is called when a descriptor is found
    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error {
            log("⚠️ The descriptor was found to have failed: \(e.localizedDescription)")
            return
        }
        
        if let descriptors = characteristic.descriptors {
            log("✅ Characteristic \(characteristic.uuid) has \(descriptors.count) descriptor")
            for desc in descriptors {
                log("  Descriptor: \(desc.uuid)")
            }
        }
    }
    
    /// 通知状态变化时调用 It is called when the notification status changes
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error {
            lastError = "Subscription notification failed: \(e.localizedDescription)"
            log("❌ Subscription notification failed: \(e.localizedDescription)")
        } else {
            lastError = nil
            let state = characteristic.isNotifying ? "Opened" : "Closed"
            log("✅ Notify Status: \(state) - \(characteristic.uuid)")
        }
    }
    
    /// 写入数据完成时调用 It is called when the data writing is completed
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error {
            log("❌ Failed to write: \(e.localizedDescription)")
        } else {
            log("✅ Write successfully")
        }
    }
}
