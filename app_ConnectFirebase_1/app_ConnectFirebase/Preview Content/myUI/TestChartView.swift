import SwiftUI
import Charts

private let twoHours: TimeInterval = 2 * 3600

// MARK: - 测试数据页面
struct TestChartView: View {
    @ObservedObject var vm: SessionViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if !vm.uploadStatus.isEmpty {
                    Text(vm.uploadStatus).font(.caption).foregroundStyle(.gray)
                }
                if vm.isUploading {
                    ProgressView("分析中...").frame(maxWidth: .infinity).padding(.vertical, 60)
                } else if let analysis = vm.sleepAnalysis {
                    SummarySection(analysis: analysis, records: vm.testRecords)
                    CoreEventSection(analysis: analysis, records: vm.testRecords, rawRecords: vm.testRawRecords)
                    TypeJudgmentSection(analysis: analysis)
                    PositionImpactSection(analysis: analysis)
                    AISuggestionSection(analysis: analysis)
                } else {
                    Text("点击右上角按钮加载CSV数据")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                }
            }
            .padding()
        }
        .navigationTitle("Sleep Report")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    vm.loadLocalCSV()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onAppear {
            if vm.sleepAnalysis == nil {
                vm.loadLocalCSV()
            }
        }
    }
}

// MARK: - Section Card
struct SectionCard<Content: View>: View {
    let title: String
    let color: Color
    let content: Content
    init(_ title: String, color: Color = .blue, @ViewBuilder content: () -> Content) {
        self.title = title; self.color = color; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).foregroundStyle(color)
            content
        }
        .padding()
        .background(color.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - 滑动提示
struct ScrollHint: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "hand.draw")
            Text("左右滑动 · 当前显示 2 小时")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

// MARK: - Legend Item
func legendItem(color: Color, label: String) -> some View {
    HStack(spacing: 4) {
        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 16, height: 6)
        Text(label).font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - 1. Summary
struct SummarySection: View {
    let analysis: SleepAnalysis
    let records: [SensorRecord]

    var ahiColor: Color {
        switch analysis.ahiClassification {
        case "Normal":   return .green
        case "Mild":     return .yellow
        case "Moderate": return .orange
        default:         return .red
        }
    }

    var body: some View {
        SectionCard("1. Summary", color: .blue) {
            // AHI 卡片
            HStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text(analysis.ahiClassification).font(.title2.bold()).foregroundStyle(ahiColor)
                    Text("Sleep Status").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding()
                .background(ahiColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(spacing: 4) {
                    Text(String(format: "%.1f", analysis.ahi)).font(.title2.bold()).foregroundStyle(.blue)
                    Text("AHI (events/hr)").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding()
                .background(.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            Text(analysis.summary)
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !records.isEmpty {
                // ── 修改1：事件散点图，纵轴为持续时长（秒），无 HR 折线 ──
                Text("Breathing Events – Duration").font(.subheadline.bold())
                ScrollHint()

                Chart {
                    ForEach(analysis.events) { event in
                        let duration = event.endTime.timeIntervalSince(event.startTime)
                        PointMark(
                            x: .value("Time", event.startTime),
                            y: .value("Duration (s)", duration)
                        )
                        .foregroundStyle(event.type == .apnea ? Color.red : Color.orange)
                        .symbolSize(70)
                        .symbol(event.type == .apnea ? .circle : .square)
                        .annotation(position: .top) {
                            Text(event.type == .apnea ? "A" : "H")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(event.type == .apnea ? .red : .orange)
                        }
                    }
                }
                .frame(height: 160)
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: twoHours)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .minute, count: 30)) { _ in
                        AxisValueLabel(format: .dateTime.hour().minute())
                        AxisGridLine()
                    }
                }
                .chartYScale(domain: 0...120)
                .chartYAxis {
                    AxisMarks(values: [0, 30, 60, 90, 120]) { v in
                        AxisValueLabel("\(v.as(Double.self).map { Int($0) } ?? 0)s")
                        AxisGridLine()
                    }
                }

                HStack(spacing: 12) {
                    legendItem(color: .red,    label: "Apnea (●)")
                    legendItem(color: .orange, label: "Hypopnea (■)")
                }
            }
        }
    }
}

// MARK: - 2. Core Event
struct CoreEventSection: View {
    let analysis: SleepAnalysis
    let records: [SensorRecord]       // 降采样后，用于画折线
    let rawRecords: [SensorRecord]    // 原始数据，用于精确查峰谷值

    // 每个事件区间内 HR 最高点（从原始数据查）
    struct HRPeak: Identifiable {
        let id: UUID
        let time: Date
        let value: Double
        let eventType: SleepEventType
    }

    // 每个事件区间内 SpO₂ 最低点（从原始数据查）
    struct SpO2Valley: Identifiable {
        let id: UUID
        let time: Date
        let value: Double
        let eventType: SleepEventType
    }

    var hrPeaks: [HRPeak] {
        analysis.events.compactMap { event in
            let inRange = rawRecords.filter { $0.timestamp >= event.startTime && $0.timestamp <= event.endTime }
            guard let peak = inRange.max(by: { $0.heartRate < $1.heartRate }) else { return nil }
            return HRPeak(id: event.id, time: peak.timestamp, value: peak.heartRate, eventType: event.type)
        }
    }

    var spo2Valleys: [SpO2Valley] {
        analysis.events.compactMap { event in
            let inRange = rawRecords.filter { $0.timestamp >= event.startTime && $0.timestamp <= event.endTime }
            guard let valley = inRange.min(by: { $0.spo2 < $1.spo2 }) else { return nil }
            return SpO2Valley(id: event.id, time: valley.timestamp, value: valley.spo2, eventType: event.type)
        }
    }

    var body: some View {
        SectionCard("2. Core Event", color: .red) {
            GroupBox("Breathing Interruption") {
                HStack {
                    statItem("Apnea",    value: "\(analysis.totalApnea)",    unit: "events",  color: .red)
                    statItem("Hypopnea", value: "\(analysis.totalHypopnea)", unit: "events",  color: .orange)
                    statItem("Longest",  value: "\(Int(analysis.longestEventSeconds))", unit: "seconds", color: .purple)
                }
            }
            GroupBox("Oxygen Impact") {
                HStack {
                    statItem("Avg SpO₂", value: String(format: "%.1f", analysis.avgSpo2), unit: "%", color: .blue)
                    statItem("Avg Drop",  value: String(format: "%.1f", analysis.avgSpo2DropDuringEvents), unit: "% during events", color: .indigo)
                }
            }
            GroupBox("Autonomic Response") {
                HStack {
                    statItem("Avg HR",   value: String(format: "%.0f", analysis.avgHeartRate), unit: "BPM", color: .red)
                    statItem("HR Spike", value: String(format: "+%.0f", analysis.avgHRSpikeDuringEvents), unit: "BPM avg", color: .pink)
                }
            }

            if !records.isEmpty {
                Text("Heart Rate").font(.subheadline.bold())
                ScrollHint()

                Chart {
                    // 底部事件色条
                    ForEach(analysis.events) { event in
                        RectangleMark(
                            xStart: .value("S", event.startTime),
                            xEnd:   .value("E", event.endTime),
                            yStart: .value("Y0", 40.0),
                            yEnd:   .value("Y1", 45.0)
                        )
                        .foregroundStyle(event.type == .apnea ? Color.red : Color.orange)
                        .opacity(0.9)
                    }
                    // HR 折线
                    ForEach(records) { r in
                        LineMark(x: .value("Time", r.timestamp), y: .value("HR", r.heartRate))
                            .foregroundStyle(.teal.opacity(0.85))
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .interpolationMethod(.catmullRom)
                    }
                    // 每个事件区间内 HR 峰值点 + 数值标注
                    ForEach(hrPeaks) { peak in
                        PointMark(x: .value("Time", peak.time), y: .value("HR", peak.value))
                            .foregroundStyle(peak.eventType == .apnea ? Color.red : Color.orange)
                            .symbolSize(40)
                            .annotation(position: .top, spacing: 2) {
                                Text("\(Int(peak.value))")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(peak.eventType == .apnea ? Color.red : Color.orange)
                            }
                    }
                }
                .frame(height: 150)
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: twoHours)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .minute, count: 30)) { _ in
                        AxisValueLabel(format: .dateTime.hour().minute())
                        AxisGridLine()
                    }
                }
                .chartYScale(domain: 40...115)
                .chartYAxis {
                    AxisMarks(values: [40, 60, 80, 100]) { v in
                        AxisValueLabel("\(v.as(Double.self).map { Int($0) } ?? 0)")
                        AxisGridLine()
                    }
                }

                Text("SpO₂").font(.subheadline.bold()).padding(.top, 4)

                Chart {
                    // 底部事件色条
                    ForEach(analysis.events) { event in
                        RectangleMark(
                            xStart: .value("S", event.startTime),
                            xEnd:   .value("E", event.endTime),
                            yStart: .value("Y0", 80.0),
                            yEnd:   .value("Y1", 81.2)
                        )
                        .foregroundStyle(event.type == .apnea ? Color.red : Color.orange)
                        .opacity(0.9)
                    }
                    // SpO₂ 折线
                    ForEach(records) { r in
                        LineMark(x: .value("Time", r.timestamp), y: .value("SpO₂", r.spo2))
                            .foregroundStyle(.blue.opacity(0.85))
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .interpolationMethod(.catmullRom)
                    }
                    // 每个事件区间内 SpO₂ 谷值点 + 数值标注
                    ForEach(spo2Valleys) { valley in
                        PointMark(x: .value("Time", valley.time), y: .value("SpO₂", valley.value))
                            .foregroundStyle(valley.eventType == .apnea ? Color.red : Color.orange)
                            .symbolSize(40)
                            .annotation(position: .bottom, spacing: 2) {
                                Text("\(Int(valley.value))%")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(valley.eventType == .apnea ? Color.red : Color.orange)
                            }
                    }
                }
                .frame(height: 150)
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: twoHours)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .minute, count: 30)) { _ in
                        AxisValueLabel(format: .dateTime.hour().minute())
                        AxisGridLine()
                    }
                }
                .chartYScale(domain: 78...100)
                .chartYAxis {
                    AxisMarks(values: [80, 85, 90, 95, 100]) { v in
                        AxisValueLabel("\(v.as(Double.self).map { Int($0) } ?? 0)%")
                        AxisGridLine()
                    }
                }

                HStack(spacing: 16) {
                    legendItem(color: .teal,   label: "HR")
                    legendItem(color: .blue,   label: "SpO₂")
                    legendItem(color: .orange, label: "Hypopnea peak")
                }
            }
        }
    }

    func statItem(_ title: String, value: String, unit: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).foregroundStyle(color)
            Text(unit).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 3. Type Judgment
struct TypeJudgmentSection: View {
    let analysis: SleepAnalysis

    var total: Int { analysis.osaCount + analysis.csaCount + analysis.uncertainCount }
    var osaPercent: Double { total > 0 ? Double(analysis.osaCount) / Double(total) * 100 : 0 }
    var csaPercent: Double { total > 0 ? Double(analysis.csaCount) / Double(total) * 100 : 0 }
    var uncPercent: Double { total > 0 ? Double(analysis.uncertainCount) / Double(total) * 100 : 0 }

    var body: some View {
        SectionCard("3. Type Judgment", color: .purple) {
            HStack {
                typeItem("OSA",       percent: osaPercent, color: .orange)
                typeItem("CSA",       percent: csaPercent, color: .purple)
                typeItem("Uncertain", percent: uncPercent, color: .gray)
            }
            if total > 0 {
                Chart {
                    SectorMark(angle: .value("OSA", osaPercent), innerRadius: .ratio(0.5))
                        .foregroundStyle(.orange)
                        .annotation(position: .overlay) {
                            if osaPercent > 8 { Text("\(Int(osaPercent))%").font(.caption.bold()).foregroundStyle(.white) }
                        }
                    SectorMark(angle: .value("CSA", max(csaPercent, 0.01)), innerRadius: .ratio(0.5))
                        .foregroundStyle(.purple)
                        .annotation(position: .overlay) {
                            if csaPercent > 8 { Text("\(Int(csaPercent))%").font(.caption.bold()).foregroundStyle(.white) }
                        }
                    SectorMark(angle: .value("Uncertain", max(uncPercent, 0.01)), innerRadius: .ratio(0.5))
                        .foregroundStyle(.gray)
                        .annotation(position: .overlay) {
                            if uncPercent > 8 { Text("\(Int(uncPercent))%").font(.caption.bold()).foregroundStyle(.white) }
                        }
                }
                .frame(height: 180)
            }
            Text("OSA: chest movement persists during airflow reduction. CSA: both airflow and chest movement are absent.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func typeItem(_ label: String, percent: Double, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(String(format: "%.0f%%", percent)).font(.title3.bold()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(8)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 4. Position Impact
struct PositionImpactSection: View {
    let analysis: SleepAnalysis

    var positionConclusion: String {
        if analysis.supineAHI > analysis.sideAHI + 3 {
            return "Events were more frequent when sleeping on your back. Sleeping on your side may significantly reduce breathing disturbances."
        } else if analysis.supineAHI <= 5 && analysis.sideAHI <= 5 {
            return "Breathing disturbances were minimal in both positions."
        } else {
            return "Position did not significantly affect breathing event frequency."
        }
    }

    var body: some View {
        SectionCard("4. Position Impact", color: .green) {
            HStack {
                posItem("Supine AHI", value: analysis.supineAHI, hours: analysis.supineHours, color: .orange)
                posItem("Side AHI",   value: analysis.sideAHI,   hours: analysis.sideHours,   color: .green)
            }
            Chart {
                BarMark(x: .value("Position", "Supine"), y: .value("AHI", analysis.supineAHI))
                    .foregroundStyle(.orange).cornerRadius(6)
                BarMark(x: .value("Position", "Side"), y: .value("AHI", analysis.sideAHI))
                    .foregroundStyle(.green).cornerRadius(6)
                RuleMark(y: .value("Normal", 5))
                    .foregroundStyle(.red.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("Normal < 5").font(.caption2).foregroundStyle(.red.opacity(0.7))
                    }
            }
            .frame(height: 160)
            .chartYAxis {
                AxisMarks { v in
                    AxisValueLabel("\(v.as(Double.self).map { Int($0) } ?? 0)")
                    AxisGridLine()
                }
            }
            Text(positionConclusion)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func posItem(_ label: String, value: Double, hours: Double, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(String(format: "%.1f", value)).font(.title2.bold()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.1f hrs", hours)).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding()
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 5. AI Suggestion
struct AISuggestionSection: View {
    let analysis: SleepAnalysis

    var body: some View {
        SectionCard("5. AI Suggestion", color: .teal) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(analysis.suggestions, id: \.self) { suggestion in
                    Text(suggestion)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.teal.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            Text("Suggestions are rule-based and not a substitute for medical advice.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
