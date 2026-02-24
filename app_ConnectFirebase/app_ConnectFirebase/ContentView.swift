import SwiftUI
import FirebaseFirestore
import Charts

// MARK: - 数据模型
struct SensorRecord: Identifiable {
    let id: String
    let heartRate: Double
    let timestamp: Date
    let isAbnormal: Bool
}

struct Session: Identifiable {
    let id: String
    let startTime: Date
    let endTime: Date?
}

// MARK: - ViewModel
class SessionViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var currentSessionId: String? = nil
    @Published var records: [SensorRecord] = []
    @Published var abnormalRecords: [SensorRecord] = []
    @Published var statusMessage = ""
    @Published var sessions: [Session] = []
    @Published var selectedSessionId: String? = nil
    @Published var testSessionId: String? = UserDefaults.standard.string(forKey: "testSessionId") {
        didSet { UserDefaults.standard.set(testSessionId, forKey: "testSessionId") }
    }
    @Published var testRecords: [SensorRecord] = []
    @Published var testAbnormalRecords: [SensorRecord] = []
    @Published var uploadStatus = ""
    
    @Published var latestHeartRate: Double = 0
    @Published var latestSpo2: Double = 0
    @Published var latestBreathRate: Double = 0
    @Published var latestBreathDepth: Double = 0
    @Published var latestTemperature: Double = 0
    
    private let db = Firestore.firestore()
    private var timer: Timer? = nil
    
    // MARK: - 开始录制
    func startRecording() {
        let ref = db.collection("sessions").document()
        let sessionId = ref.documentID
        ref.setData([
            "startTime": Timestamp(date: Date()),
            "endTime": NSNull()
        ]) { error in
            if let error = error {
                self.statusMessage = "开始失败: \(error.localizedDescription)"
                return
            }
            self.currentSessionId = sessionId
            self.isRecording = true
            self.records = []
            self.abnormalRecords = []
            self.statusMessage = "录制中..."
            self.fetchSessions()
        }
    }
    
    // MARK: - 停止录制
    func stopRecording() {
        guard let sessionId = currentSessionId else { return }
        db.collection("sessions").document(sessionId).updateData([
            "endTime": Timestamp(date: Date())
        ]) { error in
            if let error = error {
                self.statusMessage = "停止失败: \(error.localizedDescription)"
                return
            }
            self.isRecording = false
            self.statusMessage = "录制完成 ✅"
            self.fetchSessions { latestId in
                if let id = latestId { self.fetchRecords(for: id) }
            }
        }
        timer?.invalidate()
        timer = nil
    }
    
    // MARK: - 写入数据
    func sendData(heartRate: Double, spo2: Double, breathRate: Double, breathDepth: Double, temperature: Double) {
        guard let sessionId = currentSessionId, isRecording else {
            statusMessage = "请先开始录制"
            return
        }
        latestHeartRate = heartRate
        latestSpo2 = spo2
        latestBreathRate = breathRate
        latestBreathDepth = breathDepth
        latestTemperature = temperature
        let isAbnormal = heartRate > 100 || heartRate < 50
        db.collection("sessions").document(sessionId)
            .collection("data").addDocument(data: [
                "heartRate": heartRate,
                "spo2": spo2,
                "breathRate": breathRate,
                "breathDepth": breathDepth,
                "temperature": temperature,
                "isAbnormal": isAbnormal,
                "timestamp": Timestamp(date: Date())
            ]) { error in
                if let error = error {
                    self.statusMessage = "写入失败: \(error.localizedDescription)"
                } else {
                    self.statusMessage = isAbnormal ? "⚠️ 异常数据已记录" : "写入成功 ✅"
                }
            }
    }
    
    // MARK: - 取某次 Session 的数据
    func fetchRecords(for sessionId: String) {
        selectedSessionId = sessionId
        db.collection("sessions").document(sessionId)
            .collection("data")
            .order(by: "timestamp", descending: false)
            .getDocuments { snapshot, error in
                guard let docs = snapshot?.documents else { return }
                let allRecords: [SensorRecord] = docs.compactMap { doc in
                    let data = doc.data()
                    guard let hr = data["heartRate"] as? Double,
                          let ts = data["timestamp"] as? Timestamp,
                          hr > 0 else { return nil }
                    let isAbnormal = data["isAbnormal"] as? Bool ?? (hr > 100 || hr < 50)
                    return SensorRecord(id: doc.documentID, heartRate: hr, timestamp: ts.dateValue(), isAbnormal: isAbnormal)
                }
                self.records = self.downsample(allRecords)
                self.abnormalRecords = self.records.filter { $0.isAbnormal }
                self.statusMessage = "加载 \(allRecords.count) 条 → 显示 \(self.records.count) 点，异常 \(self.abnormalRecords.count) 个"
            }
    }
    
    // MARK: - 取测试数据
    func fetchTestRecords() {
        guard let sessionId = testSessionId else { return }
        db.collection("sessions").document(sessionId)
            .collection("data")
            .order(by: "timestamp", descending: false)
            .getDocuments { snapshot, error in
                guard let docs = snapshot?.documents else { return }
                let allRecords: [SensorRecord] = docs.compactMap { doc in
                    let data = doc.data()
                    guard let hr = data["heartRate"] as? Double,
                          let ts = data["timestamp"] as? Timestamp,
                          hr > 0 else { return nil }
                    let isAbnormal = data["isAbnormal"] as? Bool ?? (hr > 100 || hr < 50)
                    return SensorRecord(id: doc.documentID, heartRate: hr, timestamp: ts.dateValue(), isAbnormal: isAbnormal)
                }
                let downsampled = self.downsample(allRecords)
                self.testRecords = downsampled
                self.testAbnormalRecords = downsampled.filter { $0.isAbnormal }
                self.uploadStatus = "已加载 \(allRecords.count) 条数据，显示 \(downsampled.count) 点"
            }
    }
    
    // MARK: - 上传CSV
    func uploadBundleCSV() {
        uploadStatus = "解析中..."
        
        guard let url = Bundle.main.url(forResource: "sleep_data", withExtension: "csv") else {
            uploadStatus = "❌ 找不到 sleep_data.csv"
            return
        }
        
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            uploadStatus = "❌ 文件读取失败"
            return
        }
        
        var lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard lines.count > 1 else {
            uploadStatus = "❌ 文件格式错误"
            return
        }
        lines.removeFirst()
        
        var allData: [[String: Any]] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        
        for line in lines {
            let cols = line.components(separatedBy: ",")
            guard cols.count >= 2,
                  let hr = Double(cols[1].trimmingCharacters(in: .whitespaces)) else { continue }
            let tsStr = cols[0].trimmingCharacters(in: .whitespaces)
            let date = formatter.date(from: tsStr) ?? Date()
            let spo2 = Double(cols.count > 2 ? cols[2].trimmingCharacters(in: .whitespaces) : "") ?? 98.0
            let breathRate = Double(cols.count > 3 ? cols[3].trimmingCharacters(in: .whitespaces) : "") ?? 16.0
            let breathDepth = Double(cols.count > 4 ? cols[4].trimmingCharacters(in: .whitespaces) : "") ?? 3.0
            let temperature = Double(cols.count > 5 ? cols[5].trimmingCharacters(in: .whitespaces) : "") ?? 36.5
            let isAbnormal = hr > 100 || hr < 50
            
            allData.append([
                "heartRate": hr,
                "spo2": spo2,
                "breathRate": breathRate,
                "breathDepth": breathDepth,
                "temperature": temperature,
                "isAbnormal": isAbnormal,
                "timestamp": Timestamp(date: date)
            ])
        }
        
        guard !allData.isEmpty else {
            uploadStatus = "❌ 没有有效数据"
            return
        }
        
        uploadStatus = "上传中... 共 \(allData.count) 条"
        
        deleteOldTestSession {
            let ref = self.db.collection("sessions").document()
            let sessionId = ref.documentID
            let dates = allData.compactMap { ($0["timestamp"] as? Timestamp)?.dateValue() }
            let startTime = dates.min() ?? Date()
            let endTime = dates.max() ?? Date()
            
            ref.setData([
                "startTime": Timestamp(date: startTime),
                "endTime": Timestamp(date: endTime),
                "isTest": true
            ])
            
            let batches = stride(from: 0, to: allData.count, by: 499).map {
                Array(allData[$0..<min($0 + 499, allData.count)])
            }
            let group = DispatchGroup()
            for batchData in batches {
                group.enter()
                let batch = self.db.batch()
                for data in batchData {
                    let dataRef = self.db.collection("sessions").document(sessionId)
                        .collection("data").document()
                    batch.setData(data, forDocument: dataRef)
                }
                batch.commit { _ in group.leave() }
            }
            group.notify(queue: .main) {
                self.testSessionId = sessionId
                self.uploadStatus = "✅ 上传完成，共 \(allData.count) 条"
                self.fetchTestRecords()
                self.fetchSessions { _ in }
            }
        }
    }
    
    // MARK: - 删除旧测试数据
    private func deleteOldTestSession(completion: @escaping () -> Void) {
        guard let oldId = testSessionId else {
            completion()
            return
        }
        // 删除子集合数据
        db.collection("sessions").document(oldId)
            .collection("data")
            .getDocuments { snapshot, _ in
                let batch = self.db.batch()
                snapshot?.documents.forEach { batch.deleteDocument($0.reference) }
                batch.commit { _ in
                    self.db.collection("sessions").document(oldId).delete { _ in
                        completion()
                    }
                }
            }
    }
    
    // MARK: - 取所有 Session 列表
    func fetchSessions(completion: ((String?) -> Void)? = nil) {
        db.collection("sessions")
            .order(by: "startTime", descending: true)
            .getDocuments { snapshot, error in
                guard let docs = snapshot?.documents else { return }
                self.sessions = docs.compactMap { doc in
                    let data = doc.data()
                    guard let start = data["startTime"] as? Timestamp else { return nil }
                    let end = (data["endTime"] as? Timestamp)?.dateValue()
                    return Session(id: doc.documentID, startTime: start.dateValue(), endTime: end)
                }
                completion?(self.sessions.first?.id)
            }
    }
    
    // MARK: - 自动降采样
    func downsample(_ input: [SensorRecord]) -> [SensorRecord] {
        guard input.count > 1,
              let first = input.first?.timestamp,
              let last = input.last?.timestamp else { return input }
        let duration = last.timeIntervalSince(first)
        let groupSeconds: Double
        switch duration {
        case ..<600:       groupSeconds = 10
        case 600..<3600:   groupSeconds = 60
        case 3600..<21600: groupSeconds = 300
        default:           groupSeconds = 600
        }
        var result: [SensorRecord] = []
        var groupStart = first
        var groupRecords: [SensorRecord] = []
        for record in input {
            if record.timestamp < groupStart + groupSeconds {
                groupRecords.append(record)
            } else {
                if !groupRecords.isEmpty {
                    let avgHR = groupRecords.map { $0.heartRate }.reduce(0, +) / Double(groupRecords.count)
                    let midTime = groupStart + groupSeconds / 2
                    let hasAbnormal = groupRecords.contains { $0.isAbnormal }
                    result.append(SensorRecord(id: UUID().uuidString, heartRate: avgHR, timestamp: midTime, isAbnormal: hasAbnormal))
                }
                groupStart += groupSeconds
                groupRecords = [record]
            }
        }
        if !groupRecords.isEmpty {
            let avgHR = groupRecords.map { $0.heartRate }.reduce(0, +) / Double(groupRecords.count)
            let hasAbnormal = groupRecords.contains { $0.isAbnormal }
            result.append(SensorRecord(id: UUID().uuidString, heartRate: avgHR, timestamp: groupStart + groupSeconds / 2, isAbnormal: hasAbnormal))
        }
        return result
    }
}

// MARK: - 主界面
struct ContentView: View {
    @StateObject private var vm = SessionViewModel()
    @State private var showHistory = false
    @State private var inputHR = ""
    @State private var inputSpo2 = ""
    @State private var inputBR = ""
    @State private var inputBD = ""
    @State private var inputTemp = ""
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    recordingControlSection
                    if vm.isRecording { latestDataSection }
                    chartSection
                    historySection
                    testInputSection
                }
                .padding()
            }
            .navigationTitle("健康监测")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink(destination: TestChartView(vm: vm)) {
                        Image(systemName: "plus")
                    }
                }
            }
            .onAppear {
                vm.fetchSessions { latestId in
                    if let id = latestId { vm.fetchRecords(for: id) }
                }
            }
        }
    }
    
    // MARK: - 录制控制
    var recordingControlSection: some View {
        VStack(spacing: 12) {
            Text(vm.statusMessage).font(.caption).foregroundStyle(.gray)
            Button {
                vm.isRecording ? vm.stopRecording() : vm.startRecording()
            } label: {
                HStack {
                    Image(systemName: vm.isRecording ? "stop.circle.fill" : "record.circle")
                    Text(vm.isRecording ? "停止录制" : "开始录制").font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(vm.isRecording ? .red : .green)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }
    
    // MARK: - 最新数据
    var latestDataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("实时数据").font(.headline)
            HStack {
                dataItem(title: "心率", value: "\(Int(vm.latestHeartRate))", unit: "BPM", color: .red)
                dataItem(title: "血氧", value: "\(Int(vm.latestSpo2))", unit: "%", color: .blue)
                dataItem(title: "呼吸", value: "\(Int(vm.latestBreathRate))", unit: "RPM", color: .green)
            }
            HStack {
                dataItem(title: "深度", value: String(format: "%.1f", vm.latestBreathDepth), unit: "°", color: .orange)
                dataItem(title: "温度", value: String(format: "%.1f", vm.latestTemperature), unit: "°C", color: .purple)
                Spacer()
            }
        }
        .padding()
        .background(.blue.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    func dataItem(title: String, value: String, unit: String, color: Color) -> some View {
        VStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold()).foregroundStyle(color)
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - 折线图
    var chartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("心率趋势").font(.headline)
                Spacer()
                if !vm.abnormalRecords.isEmpty {
                    Text("⚠️ \(vm.abnormalRecords.count) 个异常").font(.caption).foregroundStyle(.red)
                }
            }
            if vm.records.isEmpty {
                Text("暂无数据").foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 200)
            } else {
                Chart {
                    ForEach(vm.records) { record in
                        LineMark(x: .value("时间", record.timestamp), y: .value("心率", record.heartRate))
                            .foregroundStyle(.red.opacity(0.6))
                            .interpolationMethod(.catmullRom)
                    }
                    ForEach(vm.abnormalRecords) { record in
                        PointMark(x: .value("时间", record.timestamp), y: .value("心率", record.heartRate))
                            .foregroundStyle(.red)
                            .symbolSize(15)
                    }
                }
                .frame(height: 220)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: .dateTime.hour().minute())
                        AxisGridLine()
                    }
                }
                .chartYScale(domain: 40...130)
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel("\(value.as(Double.self).map { Int($0) } ?? 0)")
                        AxisGridLine()
                    }
                }
            }
        }
        .padding()
        .background(.red.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - 可折叠历史列表
    var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut) { showHistory.toggle() }
            } label: {
                HStack {
                    Text("历史录制").font(.headline).foregroundStyle(.primary)
                    Spacer()
                    Text("\(vm.sessions.count) 条").font(.caption).foregroundStyle(.secondary)
                    Image(systemName: showHistory ? "chevron.up" : "chevron.down").foregroundStyle(.secondary).font(.caption)
                }
                .padding()
                .background(.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            
            if showHistory {
                if vm.sessions.isEmpty {
                    Text("暂无录制").foregroundStyle(.secondary).padding(.horizontal)
                } else {
                    ForEach(vm.sessions) { session in
                        Button {
                            vm.fetchRecords(for: session.id)
                            withAnimation { showHistory = false }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(session.startTime.formatted(.dateTime.month().day().hour().minute())).font(.subheadline.bold())
                                    if let end = session.endTime {
                                        Text("时长: \(duration(from: session.startTime, to: end))").font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text("录制中...").font(.caption).foregroundStyle(.green)
                                    }
                                }
                                Spacer()
                                if vm.selectedSessionId == session.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                                }
                            }
                            .padding()
                            .background(.gray.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
    
    // MARK: - 测试输入
    var testInputSection: some View {
        VStack(spacing: 12) {
            Text("测试输入（之后换成蓝牙数据）").font(.caption).foregroundStyle(.secondary)
            Group {
                TextField("心率 (BPM)", text: $inputHR)
                TextField("血氧 (%)", text: $inputSpo2)
                TextField("呼吸频率 (RPM)", text: $inputBR)
                TextField("呼吸深度 (°)", text: $inputBD)
                TextField("温度 (°C)", text: $inputTemp)
            }
            .textFieldStyle(.roundedBorder)
            .keyboardType(.decimalPad)
            
            Button("发送数据") {
                guard !inputHR.isEmpty else { return }
                vm.sendData(
                    heartRate: Double(inputHR) ?? 0,
                    spo2: Double(inputSpo2) ?? 0,
                    breathRate: Double(inputBR) ?? 0,
                    breathDepth: Double(inputBD) ?? 0,
                    temperature: Double(inputTemp) ?? 0
                )
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding()
            .background(.blue)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
    
    func duration(from start: Date, to end: Date) -> String {
        let seconds = Int(end.timeIntervalSince(start))
        let minutes = seconds / 60
        let hours = minutes / 60
        if hours > 0 { return "\(hours)小时\(minutes % 60)分钟" }
        else { return "\(minutes)分钟\(seconds % 60)秒" }
    }
}

// MARK: - 测试数据页面
struct TestChartView: View {
    @ObservedObject var vm: SessionViewModel
    @State private var isLoading = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                
                // 状态提示
                if !vm.uploadStatus.isEmpty {
                    Text(vm.uploadStatus)
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                
                // 图表
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("心率趋势").font(.headline)
                        Spacer()
                        if !vm.testAbnormalRecords.isEmpty {
                            Text("⚠️ \(vm.testAbnormalRecords.count) 个异常").font(.caption).foregroundStyle(.red)
                        }
                    }
                    
                    if isLoading {
                        ProgressView("加载中...")
                            .frame(maxWidth: .infinity)
                            .frame(height: 300)
                    } else if vm.testRecords.isEmpty {
                        Text("上传CSV文件后显示图表")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 300)
                    } else {
                        Chart {
                            ForEach(vm.testRecords) { record in
                                LineMark(x: .value("时间", record.timestamp), y: .value("心率", record.heartRate))
                                    .foregroundStyle(.red.opacity(0.6))
                                    .interpolationMethod(.catmullRom)
                            }
                            ForEach(vm.testAbnormalRecords) { record in
                                PointMark(x: .value("时间", record.timestamp), y: .value("心率", record.heartRate))
                                    .foregroundStyle(.red)
                                    .symbolSize(15)
                            }
                        }
                        .frame(height: 300)
                        .chartXAxis {
                            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                                AxisValueLabel(format: .dateTime.hour().minute())
                                AxisGridLine()
                            }
                        }
                        .chartYScale(domain: 40...130)
                        .chartYAxis {
                            AxisMarks { value in
                                AxisValueLabel("\(value.as(Double.self).map { Int($0) } ?? 0)")
                                AxisGridLine()
                            }
                        }
                    }
                }
                .padding()
                .background(.red.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding()
        }
        .navigationTitle("测试数据分析")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isLoading = true
                    vm.uploadBundleCSV()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        isLoading = false
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .onAppear {
            if vm.testSessionId != nil && vm.testRecords.isEmpty {
                isLoading = true
                vm.fetchTestRecords()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    isLoading = false
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
