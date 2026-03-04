import Foundation
import SwiftUI
import FirebaseFirestore

// MARK: - SensorRecord
struct SensorRecord: Identifiable {
    let id: String
    let heartRate: Double
    let spo2: Double
    let airflow: Double
    let chestMovement: Double
    let breathRate: Double
    let position: String
    let timestamp: Date
    let isAbnormal: Bool
}

// MARK: - Session
struct Session: Identifiable {
    let id: String
    let startTime: Date
    let endTime: Date?
}

// MARK: - Sleep Event Type
enum SleepEventType: String {
    case apnea = "Apnea"
    case hypopnea = "Hypopnea"
}

enum SleepEventClassification: String {
    case osa = "OSA"
    case csa = "CSA"
    case uncertain = "Uncertain"
}

struct SleepEvent: Identifiable {
    let id = UUID()
    let type: SleepEventType
    let classification: SleepEventClassification
    let startTime: Date
    let endTime: Date
    let duration: TimeInterval
    let minSpo2: Double
    let spo2Drop: Double
    let position: String
}

// MARK: - Sleep Analysis Result
struct SleepAnalysis {
    let events: [SleepEvent]
    let totalHours: Double
    let ahi: Double
    let ahiClassification: String
    let summary: String
    let totalApnea: Int
    let totalHypopnea: Int
    let longestEventSeconds: Double
    let avgSpo2: Double
    let avgSpo2DropDuringEvents: Double
    let avgHeartRate: Double
    let avgHRSpikeDuringEvents: Double
    let osaCount: Int
    let csaCount: Int
    let uncertainCount: Int
    let supineAHI: Double
    let sideAHI: Double
    let supineHours: Double
    let sideHours: Double
    let suggestions: [String]
}

// MARK: - SessionViewModel
class SessionViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var currentSessionId: String? = nil
    @Published var records: [SensorRecord] = []
    @Published var abnormalRecords: [SensorRecord] = []
    @Published var statusMessage = ""
    @Published var sessions: [Session] = []
    @Published var selectedSessionId: String? = nil
    // 图表用（24s/点，约1200点）
    @Published var testRecords: [SensorRecord] = []
    @Published var testRawAbnormalRecords: [SensorRecord] = []
    @Published var isUploading = false
    @Published var uploadStatus = ""
    @Published var latestHeartRate: Double = 0
    @Published var latestSpo2: Double = 0
    @Published var latestBreathRate: Double = 0
    @Published var latestBreathDepth: Double = 0
    @Published var latestTemperature: Double = 0
    @Published var rawAbnormalRecords: [SensorRecord] = []
    @Published var sleepAnalysis: SleepAnalysis? = nil
    @Published var testRawRecords: [SensorRecord] = []

    private let db = Firestore.firestore()
    private var timer: Timer? = nil

    // MARK: - 开始录制
    func startRecording() {
        let ref = db.collection("sessions").document()
        let sessionId = ref.documentID
        ref.setData(["startTime": Timestamp(date: Date()), "endTime": NSNull()]) { error in
            if let error = error { self.statusMessage = "开始失败: \(error.localizedDescription)"; return }
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
        db.collection("sessions").document(sessionId).updateData(["endTime": Timestamp(date: Date())]) { error in
            if let error = error { self.statusMessage = "停止失败: \(error.localizedDescription)"; return }
            self.isRecording = false
            self.statusMessage = "录制完成 ✅"
            self.fetchSessions { _ in
                if let id = self.currentSessionId { self.fetchRecords(for: id) }
            }
        }
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 写入数据
    func sendData(heartRate: Double, spo2: Double, breathRate: Double, breathDepth: Double, temperature: Double) {
        guard let sessionId = currentSessionId, isRecording else { statusMessage = "请先开始录制"; return }
        latestHeartRate = heartRate
        latestSpo2 = spo2
        latestBreathRate = breathRate
        latestBreathDepth = breathDepth
        latestTemperature = temperature
        let isAbnormal = heartRate > 100 || heartRate < 50
        db.collection("sessions").document(sessionId).collection("data").addDocument(data: [
            "heartRate": heartRate, "spo2": spo2, "breathRate": breathRate,
            "breathDepth": breathDepth, "temperature": temperature,
            "isAbnormal": isAbnormal, "timestamp": Timestamp(date: Date())
        ]) { error in
            self.statusMessage = error != nil
                ? "写入失败: \(error!.localizedDescription)"
                : (isAbnormal ? "⚠️ 异常数据已记录" : "写入成功 ✅")
        }
    }

    // MARK: - 取某次 Session 的数据
    func fetchRecords(for sessionId: String) {
        selectedSessionId = sessionId
        db.collection("sessions").document(sessionId).collection("data")
            .order(by: "timestamp", descending: false)
            .getDocuments { snapshot, _ in
                guard let docs = snapshot?.documents else { return }
                let allRecords: [SensorRecord] = docs.compactMap { doc in
                    let d = doc.data()
                    guard let hr = d["heartRate"] as? Double,
                          let ts = d["timestamp"] as? Timestamp,
                          hr > 0 else { return nil }
                    return SensorRecord(
                        id: doc.documentID, heartRate: hr,
                        spo2: d["spo2"] as? Double ?? 97.0,
                        airflow: d["airflow"] as? Double ?? 1.0,
                        chestMovement: d["chestMovement"] as? Double ?? 1.0,
                        breathRate: d["breathRate"] as? Double ?? 14.0,
                        position: d["position"] as? String ?? "supine",
                        timestamp: ts.dateValue(),
                        isAbnormal: d["isAbnormal"] as? Bool ?? (hr > 100 || hr < 50)
                    )
                }
                self.rawAbnormalRecords = allRecords.filter { $0.isAbnormal }
                self.records = self.downsample(allRecords)
                self.statusMessage = "加载 \(allRecords.count) 条 → 显示 \(self.records.count) 点，异常 \(self.abnormalRecords.count) 个"
            }
    }

    // MARK: - 本地读取CSV（不经过Firebase）
    func loadLocalCSV() {
        isUploading = true
        uploadStatus = "解析中..."

        guard let url = Bundle.main.url(forResource: "sleep_data", withExtension: "csv"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            uploadStatus = "❌ 文件读取失败"
            isUploading = false
            return
        }

        var lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard lines.count > 1 else {
            uploadStatus = "❌ 文件格式错误"
            isUploading = false
            return
        }
        lines.removeFirst()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var allRecords: [SensorRecord] = []
        for line in lines {
            let cols = line.components(separatedBy: ",")
            guard cols.count >= 2,
                  let hr = Double(cols[1].trimmingCharacters(in: .whitespaces)) else { continue }
            let date       = formatter.date(from: cols[0].trimmingCharacters(in: .whitespaces)) ?? Date()
            let spo2       = Double(cols.count > 2 ? cols[2].trimmingCharacters(in: .whitespaces) : "") ?? 97.0
            let airflow    = Double(cols.count > 3 ? cols[3].trimmingCharacters(in: .whitespaces) : "") ?? 1.0
            let chestMov   = Double(cols.count > 4 ? cols[4].trimmingCharacters(in: .whitespaces) : "") ?? 1.0
            let breathRate = Double(cols.count > 5 ? cols[5].trimmingCharacters(in: .whitespaces) : "") ?? 14.0
            let position   = cols.count > 6
                ? cols[6].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\r", with: "")
                : "supine"
            allRecords.append(SensorRecord(
                id: UUID().uuidString, heartRate: hr, spo2: spo2,
                airflow: airflow, chestMovement: chestMov, breathRate: breathRate,
                position: position, timestamp: date,
                isAbnormal: hr > 100 || hr < 50
            ))
        }

        DispatchQueue.main.async {
            self.testRawAbnormalRecords = allRecords.filter { $0.isAbnormal }
            // 24秒/点 → 8小时约1200点，2小时窗口内约150点，波动清晰
            self.testRecords = self.downsampleForChart(allRecords, secondsPerPoint: 24)
            // 分析用原始数据，保证精度
            self.testRawRecords = allRecords
            self.sleepAnalysis = self.analyzeSleep(records: allRecords)
            self.uploadStatus = "已加载 \(allRecords.count) 条数据"
            self.isUploading = false
        }
    }

    // MARK: - 取所有 Session 列表
    func fetchSessions(completion: ((String?) -> Void)? = nil) {
        db.collection("sessions").order(by: "startTime", descending: true)
            .getDocuments { snapshot, _ in
                guard let docs = snapshot?.documents else { return }
                self.sessions = docs.compactMap { doc in
                    let data = doc.data()
                    guard let start = data["startTime"] as? Timestamp else { return nil }
                    return Session(id: doc.documentID, startTime: start.dateValue(),
                                   endTime: (data["endTime"] as? Timestamp)?.dateValue())
                }
                completion?(self.sessions.first?.id)
            }
    }

    // MARK: - 图表降采样（固定秒数/点）
    func downsampleForChart(_ input: [SensorRecord], secondsPerPoint: Double = 24) -> [SensorRecord] {
        guard input.count > 1,
              let first = input.first?.timestamp else { return input }
        var result: [SensorRecord] = []
        var groupStart = first
        var group: [SensorRecord] = []

        func flush() {
            guard !group.isEmpty else { return }
            let c = Double(group.count)
            result.append(SensorRecord(
                id: UUID().uuidString,
                heartRate:     group.map { $0.heartRate }.reduce(0, +) / c,
                spo2:          group.map { $0.spo2 }.reduce(0, +) / c,
                airflow:       group.map { $0.airflow }.reduce(0, +) / c,
                chestMovement: group.map { $0.chestMovement }.reduce(0, +) / c,
                breathRate:    group.map { $0.breathRate }.reduce(0, +) / c,
                position:      group.last?.position ?? "supine",
                timestamp:     groupStart + secondsPerPoint / 2,
                isAbnormal:    group.contains { $0.isAbnormal }
            ))
        }
        for r in input {
            if r.timestamp < groupStart + secondsPerPoint { group.append(r) }
            else { flush(); groupStart += secondsPerPoint; group = [r] }
        }
        flush()
        return result
    }

    // MARK: - 通用降采样（按时长自动选粒度）
    func downsample(_ input: [SensorRecord]) -> [SensorRecord] {
        guard input.count > 1,
              let first = input.first?.timestamp,
              let last  = input.last?.timestamp else { return input }
        let duration = last.timeIntervalSince(first)
        let gs: Double
        switch duration {
        case ..<600:       gs = 10
        case 600..<3600:   gs = 60
        case 3600..<21600: gs = 300
        default:           gs = 600
        }
        return downsampleForChart(input, secondsPerPoint: gs)
    }

    // MARK: - Sleep Analysis
    func analyzeSleep(records: [SensorRecord]) -> SleepAnalysis {
        guard !records.isEmpty,
              let firstTime = records.first?.timestamp,
              let lastTime  = records.last?.timestamp else { return emptyAnalysis() }

        let totalHours = max(lastTime.timeIntervalSince(firstTime) / 3600.0, 0.01)
        var events: [SleepEvent] = []
        var i = 0

        while i < records.count {
            let r = records[i]
            let isApnea    = r.airflow < 0.1
            let isHypopnea = r.airflow >= 0.1 && r.airflow < 0.7
            guard isApnea || isHypopnea else { i += 1; continue }

            var j = i + 1
            while j < records.count {
                let next = records[j]
                let still = isApnea ? next.airflow < 0.1 : (next.airflow >= 0.1 && next.airflow < 0.7)
                if still { j += 1 } else { break }
            }
            let eventRecs = Array(records[i..<j])
            let duration  = records[min(j, records.count - 1)].timestamp.timeIntervalSince(r.timestamp)

            if duration >= 10 {
                let windowRecs = Array(records[i..<min(j + 10, records.count)])
                let minSpo2    = windowRecs.map { $0.spo2 }.min() ?? r.spo2
                let spo2Drop   = 97.5 - minSpo2
                let qualifies  = isApnea || (isHypopnea && spo2Drop >= 3.0)

                if qualifies {
                    let avgChest = eventRecs.map { $0.chestMovement }.reduce(0, +) / Double(eventRecs.count)
                    let classification: SleepEventClassification = isApnea
                        ? (avgChest > 0.2 ? .osa : .csa)
                        : .osa
                    events.append(SleepEvent(
                        type: isApnea ? .apnea : .hypopnea,
                        classification: classification,
                        startTime: r.timestamp,
                        endTime: records[min(j, records.count - 1)].timestamp,
                        duration: duration,
                        minSpo2: minSpo2,
                        spo2Drop: spo2Drop,
                        position: r.position
                    ))
                }
            }
            i = j
        }

        let totalApnea    = events.filter { $0.type == .apnea }.count
        let totalHypopnea = events.filter { $0.type == .hypopnea }.count
        let ahi           = Double(totalApnea + totalHypopnea) / totalHours
        let ahiClass: String = ahi < 5 ? "Normal" : ahi < 15 ? "Mild" : ahi < 30 ? "Moderate" : "Severe"
        let longestEvent  = events.map { $0.duration }.max() ?? 0
        let avgSpo2       = records.map { $0.spo2 }.reduce(0, +) / Double(records.count)
        let avgSpo2Drop   = events.isEmpty ? 0.0 : events.map { $0.spo2Drop }.reduce(0, +) / Double(events.count)
        let avgHR         = records.map { $0.heartRate }.reduce(0, +) / Double(records.count)

        var hrSpikes: [Double] = []
        for event in events {
            let during = records.filter { $0.timestamp >= event.startTime && $0.timestamp <= event.endTime }
            let after  = records.filter { $0.timestamp > event.endTime && $0.timestamp <= event.endTime.addingTimeInterval(30) }
            if let maxAfter = after.map({ $0.heartRate }).max(), !during.isEmpty {
                let avgDuring = during.map { $0.heartRate }.reduce(0, +) / Double(during.count)
                hrSpikes.append(maxAfter - avgDuring)
            }
        }
        let avgHRSpike = hrSpikes.isEmpty ? 0 : hrSpikes.reduce(0, +) / Double(hrSpikes.count)

        let osaCount  = events.filter { $0.classification == .osa }.count
        let csaCount  = events.filter { $0.classification == .csa }.count
        let uncCount  = events.filter { $0.classification == .uncertain }.count

        let supineH   = Double(records.filter { $0.position == "supine" }.count) / Double(records.count) * totalHours
        let sideH     = Double(records.filter { $0.position == "side"   }.count) / Double(records.count) * totalHours
        let supineAHI = supineH > 0 ? Double(events.filter { $0.position == "supine" }.count) / supineH : 0
        let sideAHI   = sideH   > 0 ? Double(events.filter { $0.position == "side"   }.count) / sideH   : 0

        let summary: String
        if osaCount > csaCount {
            summary = "Repeated airflow reduction with preserved respiratory effort suggests an obstructive pattern."
        } else if csaCount > 0 {
            summary = "Central apnea events detected with absent chest movement, suggesting central nervous system involvement."
        } else {
            summary = "Breathing patterns appear normal throughout the night."
        }

        var suggestions: [String] = []
        if supineAHI > sideAHI + 3 {
            suggestions.append("💡 Your AHI is significantly higher when lying on your back. Try sleeping on your side.")
        }
        if avgHRSpike > 8 {
            suggestions.append("⚡ Large HR fluctuations during events indicate high autonomic nerve pressure. Consider consulting a specialist.")
        }
        if avgSpo2 < 94 {
            suggestions.append("🩺 Low average SpO₂ detected throughout the night. Further medical evaluation is recommended.")
        }
        if ahi >= 15 {
            suggestions.append("⚠️ Moderate to severe sleep apnea detected. A sleep study and medical consultation are strongly advised.")
        }
        if csaCount > 0 {
            suggestions.append("🧠 Central apnea events were detected, which may relate to heart or neurological conditions. Consult your doctor.")
        }
        if suggestions.isEmpty {
            suggestions.append("✅ Sleep breathing patterns look generally healthy. Maintain consistent sleep habits.")
        }

        return SleepAnalysis(
            events: events, totalHours: totalHours, ahi: ahi,
            ahiClassification: ahiClass, summary: summary,
            totalApnea: totalApnea, totalHypopnea: totalHypopnea,
            longestEventSeconds: longestEvent, avgSpo2: avgSpo2,
            avgSpo2DropDuringEvents: avgSpo2Drop, avgHeartRate: avgHR,
            avgHRSpikeDuringEvents: avgHRSpike, osaCount: osaCount,
            csaCount: csaCount, uncertainCount: uncCount,
            supineAHI: supineAHI, sideAHI: sideAHI,
            supineHours: supineH, sideHours: sideH,
            suggestions: suggestions
        )
    }

    private func emptyAnalysis() -> SleepAnalysis {
        SleepAnalysis(
            events: [], totalHours: 0, ahi: 0, ahiClassification: "N/A", summary: "",
            totalApnea: 0, totalHypopnea: 0, longestEventSeconds: 0,
            avgSpo2: 0, avgSpo2DropDuringEvents: 0, avgHeartRate: 0, avgHRSpikeDuringEvents: 0,
            osaCount: 0, csaCount: 0, uncertainCount: 0,
            supineAHI: 0, sideAHI: 0, supineHours: 0, sideHours: 0,
            suggestions: []
        )
    }
}
