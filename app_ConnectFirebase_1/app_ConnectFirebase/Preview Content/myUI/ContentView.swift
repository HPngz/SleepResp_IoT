import SwiftUI
import Charts

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
                vm.fetchSessions { _ in
                    if let id = vm.sessions.first?.id {
                        vm.fetchRecords(for: id)
                    }
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
                    ForEach(vm.rawAbnormalRecords) { record in
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

    // MARK: - 工具方法
    func duration(from start: Date, to end: Date) -> String {
        let seconds = Int(end.timeIntervalSince(start))
        let minutes = seconds / 60
        let hours = minutes / 60
        if hours > 0 { return "\(hours)小时\(minutes % 60)分钟" }
        else { return "\(minutes)分钟\(seconds % 60)秒" }
    }
}

#Preview {
    ContentView()
}
