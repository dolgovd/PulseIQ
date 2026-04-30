#if os(macOS)
import SwiftUI
import CoreData
import Charts
import UniformTypeIdentifiers

struct ChartDataPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

/// The 4 computed/pinned metrics always shown at the top
let pinnedMetricTitles = ["Recovery", "Body Battery", "Exertion", "Sleep"]

/// Map a color name string to a SwiftUI Color
func colorFromName(_ name: String) -> Color {
    switch name {
    case "red": return .red
    case "blue": return .blue
    case "green": return .green
    case "orange": return .orange
    case "yellow": return .yellow
    case "purple": return .purple
    case "cyan": return .cyan
    case "teal": return .teal
    case "indigo": return .indigo
    case "mint": return .mint
    case "pink": return .pink
    case "brown": return .brown
    default: return .gray
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

enum TimeFilter: String, CaseIterable {
    case w1 = "7 Days"
    case d30 = "30 Days"
    case d60 = "60 Days"
    case d90 = "90 Days"
    
    var timeInterval: TimeInterval {
        switch self {
        case .w1: return 7 * 24 * 3600
        case .d30: return 30 * 24 * 3600
        case .d60: return 60 * 24 * 3600
        case .d90: return 90 * 24 * 3600
        }
    }
}

struct ChartConfiguration {
    var title: String
    var history: [ChartDataPoint]
    var color: Color
}

public struct DashboardView: View {
    @Environment(\.managedObjectContext) private var viewContext
    
    @FetchRequest(
        entity: HealthSample.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \HealthSample.endDate, ascending: false)],
        animation: .default)
    private var samples: FetchedResults<HealthSample>
    
    let columns = Array(repeating: GridItem(.flexible(), spacing: 20), count: 4)
    
    @State private var selectedNav: String? = "overview"
    @State private var selectedDate: Date = Date()
    @State private var selectedMetricTitle: String? = "Recovery"
    @State private var showingDatePicker = false
    
    @State private var draggedMetric: String?
    
    /// Dynamically discover all unique HealthKit type identifiers present in CoreData
    private var discoveredMetricTypes: [String] {
        let allTypes = Set(samples.map { $0.type })
        // Exclude types already used by pinned computed metrics (activeEnergy is used by Exertion)
        let excludedTypes: Set<String> = [String.activeEnergyBurned]
        let filtered = allTypes.subtracting(excludedTypes)
        return filtered.sorted()
    }
    
    // Favorites are no longer needed since pinned metrics are fixed
    // and discovered metrics auto-populate
    
    // MARK: - Derived Metrics
    private var recoveryScore: Double {
        return AlgorithmManager.shared.calculateRecovery(samples: Array(samples), date: selectedDate, sleepHours: 7.5)
    }
    
    private var todayExertion: Double {
        let calendar = Calendar.current
        let todayEnergy = samples
            .filter { $0.type == String.activeEnergyBurned && calendar.isDate($0.endDate, inSameDayAs: selectedDate) }
            .reduce(0) { $0 + $1.value }
        return AlgorithmManager.shared.calculateExertion(activeEnergyKcals: todayEnergy)
    }
    
    private var bodyBattery: Double {
        return AlgorithmManager.shared.calculateBodyBattery(recoveryScore: recoveryScore, exertionScore: todayExertion)
    }
    
    // MARK: - History Calculations
    private var exertionHistory: [ChartDataPoint] {
        let calendar = Calendar.current
        var trend: [ChartDataPoint] = []
        for i in 0..<90 {
            guard let day = calendar.date(byAdding: .day, value: -i, to: Date()) else { continue }
            let energy = samples
                .filter { $0.type == String.activeEnergyBurned && calendar.isDate($0.endDate, inSameDayAs: day) }
                .reduce(0) { $0 + $1.value }
            let val = AlgorithmManager.shared.calculateExertion(activeEnergyKcals: energy)
            trend.append(ChartDataPoint(date: day, value: val))
        }
        return trend
    }
    
    private var recoveryHistory: [ChartDataPoint] {
        let calendar = Calendar.current
        var trend: [ChartDataPoint] = []
        let allSamples = Array(samples)
        for i in 0..<90 {
            guard let day = calendar.date(byAdding: .day, value: -i, to: Date()) else { continue }
            let val = AlgorithmManager.shared.calculateRecovery(samples: allSamples, date: day, sleepHours: 7.5)
            trend.append(ChartDataPoint(date: day, value: val))
        }
        return trend
    }
    
    private var bodyBatteryHistory: [ChartDataPoint] {
        let calendar = Calendar.current
        var trend: [ChartDataPoint] = []
        let allSamples = Array(samples)
        for i in 0..<90 {
            guard let day = calendar.date(byAdding: .day, value: -i, to: Date()) else { continue }
            let rec = AlgorithmManager.shared.calculateRecovery(samples: allSamples, date: day, sleepHours: 7.5)
            let energy = allSamples
                .filter { $0.type == String.activeEnergyBurned && calendar.isDate($0.endDate, inSameDayAs: day) }
                .reduce(0) { $0 + $1.value }
            let exe = AlgorithmManager.shared.calculateExertion(activeEnergyKcals: energy)
            let val = AlgorithmManager.shared.calculateBodyBattery(recoveryScore: rec, exertionScore: exe)
            trend.append(ChartDataPoint(date: day, value: val))
        }
        return trend
    }
    
    private var sleepHistory: [ChartDataPoint] {
        var trend: [ChartDataPoint] = []
        let calendar = Calendar.current
        for i in 0..<90 {
            if let day = calendar.date(byAdding: .day, value: -i, to: Date()) {
                let val = Double.random(in: 6.5...8.5)
                trend.append(ChartDataPoint(date: day, value: val))
            }
        }
        return trend
    }
    
    private var hrvHistory: [ChartDataPoint] {
        samples.filter { $0.type == String.heartRateVariabilitySDNN }.map { ChartDataPoint(date: $0.endDate, value: $0.value) }
    }
    
    private var restingHRHistory: [ChartDataPoint] {
        samples.filter { $0.type == String.restingHeartRate }.map { ChartDataPoint(date: $0.endDate, value: $0.value) }
    }
    
    private var respRateHistory: [ChartDataPoint] {
        samples.filter { $0.type == String.respiratoryRate }.map { ChartDataPoint(date: $0.endDate, value: $0.value) }
    }
    
    private var spo2History: [ChartDataPoint] {
        samples.filter { $0.type == String.oxygenSaturation }.map { ChartDataPoint(date: $0.endDate, value: $0.value * 100.0) }
    }
    
    private var currentChartConfiguration: ChartConfiguration? {
        guard let title = selectedMetricTitle else { return nil }
        // Pinned computed metrics
        switch title {
        case "Recovery": return ChartConfiguration(title: "Recovery", history: recoveryHistory, color: .green)
        case "Sleep": return ChartConfiguration(title: "Sleep", history: sleepHistory, color: .indigo)
        case "Exertion": return ChartConfiguration(title: "Exertion", history: exertionHistory, color: .orange)
        case "Body Battery": return ChartConfiguration(title: "Body Battery", history: bodyBatteryHistory, color: .cyan)
        default: break
        }
        // Dynamic HealthKit metrics: title IS the HK type identifier
        let info = HealthKitMetricInfo.info(for: title)
        let history = samples
            .filter { $0.type == title }
            .map { ChartDataPoint(date: $0.endDate, value: $0.value * info.multiplier) }
        return ChartConfiguration(title: info.displayName, history: history, color: colorFromName(info.colorName))
    }
    
    private func latestValue(for identifier: String, multiplier: Double = 1.0) -> Double? {
        let calendar = Calendar.current
        let endOfDay = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: selectedDate) ?? selectedDate
        return samples.first { $0.type == identifier && $0.endDate <= endOfDay }.map { $0.value * multiplier }
    }
    
    private func formatLatest(type identifier: String, unit: String, multiplier: Double = 1.0) -> String {
        if let val = latestValue(for: identifier, multiplier: multiplier) {
            return String(format: "%.1f %@", val, unit)
        }
        return "-- \(unit)"
    }
    
    private var dateFormatter: DateFormatter {
        let df = DateFormatter()
        df.dateFormat = "dd-MMM-yyyy"
        return df
    }
    
    private func toggleMetric(_ title: String) {
        if selectedMetricTitle == title {
            selectedMetricTitle = nil
        } else {
            selectedMetricTitle = title
        }
    }
    
    /// Card for pinned computed metrics
    @ViewBuilder
    private func pinnedCard(_ title: String) -> some View {
        switch title {
        case "Recovery":
            MetricCard(title: "Recovery", value: String(format: "%.0f%%", recoveryScore), icon: "bolt.heart.fill", color: recoveryScore > 66 ? .green : (recoveryScore > 33 ? .yellow : .red), isSelected: selectedMetricTitle == "Recovery") { toggleMetric("Recovery") }
        case "Sleep":
            MetricCard(title: "Sleep", value: "7h 30m", icon: "bed.double.fill", color: .indigo, isSelected: selectedMetricTitle == "Sleep") { toggleMetric("Sleep") }
        case "Exertion":
            MetricCard(title: "Exertion", value: String(format: "%.1f", todayExertion), icon: "flame.fill", color: .orange, isSelected: selectedMetricTitle == "Exertion") { toggleMetric("Exertion") }
        case "Body Battery":
            MetricCard(title: "Body Battery", value: String(format: "%.0f", bodyBattery), icon: "battery.100.bolt", color: .cyan, isSelected: selectedMetricTitle == "Body Battery") { toggleMetric("Body Battery") }
        default:
            EmptyView()
        }
    }
    
    /// Card for any dynamically-discovered HealthKit metric type
    private func dynamicCard(for typeIdentifier: String) -> some View {
        let info = HealthKitMetricInfo.info(for: typeIdentifier)
        let color = colorFromName(info.colorName)
        let valueStr = formatLatest(type: typeIdentifier, unit: info.unit, multiplier: info.multiplier)
        return MetricCard(
            title: info.displayName,
            value: valueStr,
            icon: info.icon,
            color: color,
            isSelected: selectedMetricTitle == typeIdentifier
        ) { toggleMetric(typeIdentifier) }
    }
    
    public var body: some View {
        NavigationSplitView {
            List(selection: $selectedNav) {
                NavigationLink("Overview", value: "overview")
                NavigationLink("Trends", value: "trends")
                NavigationLink("Workouts", value: "workouts")
            }
            .navigationTitle("PulseIQ")
            .listStyle(.sidebar)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    
                    // MARK: - Header
                    HStack(alignment: .center) {
                        Text(Calendar.current.isDateInToday(selectedDate) ? "Today's Training Readiness" : "Training Readiness")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                        
                        Spacer()
                        
                        if !Calendar.current.isDateInToday(selectedDate) {
                            Button("Today") {
                                selectedDate = Date()
                            }
                            .buttonStyle(.link)
                            .font(.headline)
                            .padding(.trailing, 8)
                        }
                        
                        Button(action: { showingDatePicker.toggle() }) {
                            HStack(spacing: 4) {
                                Text(dateFormatter.string(from: selectedDate))
                                    .font(.subheadline.bold())
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showingDatePicker, arrowEdge: .bottom) {
                            DatePicker("", selection: $selectedDate, displayedComponents: .date)
                                .datePickerStyle(.graphical)
                                .padding()
                                .frame(width: 300)
                        }
                    }
                    .padding(.horizontal)
                    
                    // MARK: - Pinned Metrics (always on top)
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(pinnedMetricTitles, id: \.self) { title in
                            pinnedCard(title)
                        }
                    }
                    .padding(.horizontal)
                    
                    // Chart for pinned metrics
                    if let selected = selectedMetricTitle,
                       pinnedMetricTitles.contains(selected),
                       let config = currentChartConfiguration {
                        DetailChartSection(config: config, selectedDate: selectedDate)
                            .padding(.horizontal)
                            .padding(.top, 8)
                    }
                    
                    // MARK: - Discovered HealthKit Metrics
                    if !discoveredMetricTypes.isEmpty {
                        Text("Health Metrics")
                            .font(.title2.bold())
                            .padding(.horizontal)
                            .padding(.top, 8)
                        
                        let metricChunks = discoveredMetricTypes.chunked(into: 4)
                        ForEach(metricChunks.indices, id: \.self) { i in
                            let chunk = metricChunks[i]
                            
                            LazyVGrid(columns: columns, spacing: 20) {
                                ForEach(chunk, id: \.self) { typeId in
                                    dynamicCard(for: typeId)
                                }
                            }
                            .padding(.horizontal)
                            
                            if let selected = selectedMetricTitle,
                               chunk.contains(selected),
                               let config = currentChartConfiguration {
                                DetailChartSection(config: config, selectedDate: selectedDate)
                                    .padding(.horizontal)
                                    .padding(.top, 8)
                            }
                        }
                    }
                    
                }
                .padding(.vertical, 24)
            }
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}

struct MetricDropDelegate: DropDelegate {
    let item: String
    @Binding var items: [String]
    @Binding var draggedItem: String?
    var onDrop: () -> Void
    
    func performDrop(info: DropInfo) -> Bool {
        draggedItem = nil
        onDrop()
        return true
    }
    
    func dropEntered(info: DropInfo) {
        guard let draggedItem = draggedItem,
              draggedItem != item,
              let from = items.firstIndex(of: draggedItem),
              let to = items.firstIndex(of: item) else { return }
        
        withAnimation {
            items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }
}

struct MetricCard: View {
    var title: String
    var value: String
    var icon: String
    var color: Color
    var isSelected: Bool
    var action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundColor(color)
                    .symbolEffect(.bounce, options: .nonRepeating, value: isHovered)
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(24)
        .background(isSelected ? color.opacity(0.15) : Color(NSColor.controlBackgroundColor))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isSelected ? color : Color.clear, lineWidth: 2)
        )
        .shadow(color: isHovered || isSelected ? color.opacity(0.3) : Color.black.opacity(0.05), radius: isHovered || isSelected ? 15 : 10, x: 0, y: isHovered || isSelected ? 8 : 4)
        .scaleEffect(isHovered && !isSelected ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            withAnimation {
                action()
            }
        }
    }
}

struct DetailChartSection: View {
    var config: ChartConfiguration
    var selectedDate: Date
    @State private var filter: TimeFilter = .w1
    @State private var rawSelectedDate: Date? = nil
    
    private var dateDomain: (start: Date, end: Date) {
        let halfDuration = filter.timeInterval / 2
        var startDate = selectedDate.addingTimeInterval(-halfDuration)
        var endDate = selectedDate.addingTimeInterval(halfDuration)
        
        let maxDataDate = config.history.max(by: { $0.date < $1.date })?.date ?? Date()
        
        if endDate > maxDataDate {
            endDate = maxDataDate
            startDate = maxDataDate.addingTimeInterval(-filter.timeInterval)
        }
        
        return (Calendar.current.startOfDay(for: startDate), Calendar.current.startOfDay(for: endDate))
    }
    
    var binnedHistory: [ChartDataPoint] {
        let domain = dateDomain
        let calendar = Calendar.current
        let inRange = config.history.filter { calendar.startOfDay(for: $0.date) >= domain.start && calendar.startOfDay(for: $0.date) <= domain.end }
        
        let grouping: (Date) -> Date
        // Bin by day
        grouping = { date in Calendar.current.startOfDay(for: date) }
        
        let grouped = Dictionary(grouping: inRange, by: { grouping($0.date) })
        let binned = grouped.map { (key, value) -> ChartDataPoint in
            let avg = value.reduce(0) { $0 + $1.value } / Double(value.count)
            return ChartDataPoint(date: key, value: avg)
        }.sorted { $0.date < $1.date }
        
        return binned
    }
    
    var yDomain: ClosedRange<Double> {
        let values = binnedHistory.map { $0.value }
        let minVal = values.min() ?? 0
        let maxVal = values.max() ?? 100
        let padding = max((maxVal - minVal) * 0.15, 2.0)
        return max(0, minVal - padding)...(maxVal + padding)
    }
    
    private func findClosest(to target: Date, in history: [ChartDataPoint]) -> ChartDataPoint? {
        history.min(by: { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) })
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("\(config.title) Trend")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Picker("", selection: $filter) {
                    ForEach(TimeFilter.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)
            }
            
            if config.history.isEmpty {
                Text("No data available")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if binnedHistory.isEmpty {
                Text("No data for this period")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart {
                    if config.title == "Recovery" {
                        RuleMark(y: .value("Yellow", 66))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundStyle(Color.yellow.opacity(0.8))
                        RuleMark(y: .value("Red", 33))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundStyle(Color.red.opacity(0.8))
                    }
                    
                    if config.title == "Body Battery" {
                        RuleMark(y: .value("Yellow", 50))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundStyle(Color.yellow.opacity(0.8))
                        RuleMark(y: .value("Red", 25))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundStyle(Color.red.opacity(0.8))
                    }
                    
                    ForEach(binnedHistory) { data in
                        LineMark(
                            x: .value("Date", data.date),
                            y: .value("Value", data.value)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(config.color.gradient)
                        .symbol(Circle().strokeBorder(lineWidth: 1.5))
                        .symbolSize(40)
                        
                        AreaMark(
                            x: .value("Date", data.date),
                            y: .value("Value", data.value)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(
                            gradient: Gradient(colors: [config.color.opacity(0.3), .clear]),
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                    }
                    
                    if let hoverDate = rawSelectedDate,
                       let closestData = findClosest(to: hoverDate, in: binnedHistory) {
                        RuleMark(x: .value("Selected Date", closestData.date))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5]))
                            .foregroundStyle(Color.gray.opacity(0.5))
                    }
                }
                .chartXScale(domain: {
                    let domain = dateDomain
                    return domain.start...domain.end
                }())
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    if let date: Date = proxy.value(atX: location.x) {
                                        rawSelectedDate = date
                                    }
                                case .ended:
                                    rawSelectedDate = nil
                                }
                            }
                        
                        if let hoverDate = rawSelectedDate,
                           let closestData = findClosest(to: hoverDate, in: binnedHistory),
                           let xPos = proxy.position(forX: closestData.date) {
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text(closestData.date, format: .dateTime.month().day())
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.1f", closestData.value))
                                    .font(.title3.bold())
                                    .foregroundColor(config.color)
                            }
                            .padding(12)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.gray.opacity(0.4), lineWidth: 1)
                            )
                            .shadow(color: Color.black.opacity(0.3), radius: 6, x: 0, y: 3)
                            .position(x: min(max(xPos, 60), geo.size.width - 60), y: 35)
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks()
                }
                .chartYScale(domain: yDomain)
            }
        }
        .padding(24)
        .frame(height: 300)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 4)
    }
}
#endif
