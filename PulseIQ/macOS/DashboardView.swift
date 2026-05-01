#if os(macOS)
import SwiftUI
import CoreData
import Charts
import UniformTypeIdentifiers
import MultipeerConnectivity
import Combine

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

@MainActor
class DashboardViewModel: ObservableObject {
    @Published var recoveryScore: Double = 50.0
    @Published var todayExertion: Double = 0.0
    @Published var bodyBattery: Double = 50.0
    @Published var sleepScore: Double = 7.5
    
    @Published var recoveryHistory: [ChartDataPoint] = []
    @Published var exertionHistory: [ChartDataPoint] = []
    @Published var bodyBatteryHistory: [ChartDataPoint] = []
    @Published var sleepHistory: [ChartDataPoint] = []
    
    @Published var groupedDiscoveredMetrics: [String: [String]] = [:]
    
    @Published var isCalculating = false
    
    private var lastSampleCount = 0
    private var lastSelectedDate: Date?
    
    func updateIfNeeded(date: Date) {
        // Debounce: only update if count changes or date changes
        // Since we don't pass samples anymore, we rely on the Core Data fetch in the task
        calculateMetrics(date: date)
    }
    
    private func calculateMetrics(date: Date) {
        isCalculating = true
        
        // Move to background thread and fetch data there to keep main thread free
        Task.detached(priority: .userInitiated) { [weak self] in
            let calendar = Calendar.current
            let context = CoreDataManager.shared.container.newBackgroundContext()
            
            // 1. Fetch only the last 90 days of data to keep memory/CPU low
            let ninetyDaysAgo = calendar.date(byAdding: .day, value: -90, to: Date()) ?? Date.distantPast
            let fetchRequest: NSFetchRequest<HealthSample> = NSFetchRequest(entityName: "HealthSample")
            fetchRequest.predicate = NSPredicate(format: "endDate >= %@", ninetyDaysAgo as NSDate)
            
            guard let samples = try? context.fetch(fetchRequest) else {
                await MainActor.run { [weak self] in
                    self?.isCalculating = false
                }
                return
            }
            
            // Convert to simple DTOs
            let dtos = samples.map { SyncPayload.SampleDto(id: $0.id, type: $0.type, value: $0.value, startDate: $0.startDate, endDate: $0.endDate) }
            
            // Local constants to avoid any cross-isolation issues with static strings
            let hrvType = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
            let rhrType = "HKQuantityTypeIdentifierRestingHeartRate"
            let energyType = "HKQuantityTypeIdentifierActiveEnergyBurned"
            let sleepType = "HKCategoryTypeIdentifierSleepAnalysis"
            
            func calculateRecoveryLocal(samples: [SyncPayload.SampleDto], date: Date) -> Double {
                let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: date) ?? Date.distantPast
                let hrvSamples = samples.filter { $0.type == hrvType }
                let rhrSamples = samples.filter { $0.type == rhrType }
                
                let pastHRVs = hrvSamples.filter { $0.endDate >= thirtyDaysAgo && $0.endDate < calendar.startOfDay(for: date) && $0.value.isFinite }
                let baselineHRV = pastHRVs.isEmpty ? 50.0 : pastHRVs.reduce(0) { $0 + $1.value } / Double(pastHRVs.count)
                
                let pastRHRs = rhrSamples.filter { $0.endDate >= thirtyDaysAgo && $0.endDate < calendar.startOfDay(for: date) && $0.value.isFinite }
                let baselineRHR = pastRHRs.isEmpty ? 60.0 : pastRHRs.reduce(0) { $0 + $1.value } / Double(pastRHRs.count)
                
                let latestHRV = hrvSamples.first(where: { calendar.isDate($0.endDate, inSameDayAs: date) })?.value
                let latestRHR = rhrSamples.first(where: { calendar.isDate($0.endDate, inSameDayAs: date) })?.value
                
                guard latestHRV != nil || latestRHR != nil else { return 50.0 }
                
                var hrvScore = 0.5
                var rhrScore = 0.5
                var factorsCount = 0.0
                
                if let hrv = latestHRV {
                    let ratio = hrv / baselineHRV
                    hrvScore = min(max((ratio - 0.8) / 0.4, 0.0), 1.0)
                    factorsCount += 1
                }
                if let rhr = latestRHR {
                    let ratio = baselineRHR / rhr
                    rhrScore = min(max((ratio - 0.8) / 0.4, 0.0), 1.0)
                    factorsCount += 1
                }
                
                let totalScore = factorsCount > 0 ? (hrvScore + rhrScore + 0.5) / (factorsCount + 1) : 0.5
                return min(max(totalScore * 100.0, 1.0), 100.0)
            }

            let recovery = calculateRecoveryLocal(samples: dtos, date: date)
            
            let todayEnergy = dtos
                .filter { $0.type == energyType && calendar.isDate($0.endDate, inSameDayAs: date) }
                .reduce(0) { $0 + $1.value }
            let exertion = (todayEnergy / 1000.0) * 10.0
            
            let battery = min(max(recovery - (exertion * 5.0), 5.0), 100.0)
            
            func calculateSleepDuration(samples: [SyncPayload.SampleDto]) -> Double {
                guard !samples.isEmpty else { return 0 }
                
                // Prioritize precise stages (3=Core, 4=Deep, 5=REM) if available
                let stages = samples.filter { val in [3.0, 4.0, 5.0].contains(val.value) }
                
                // If we have stages, use them exclusively. 
                // Otherwise, use all available samples (handles both new 'Unspecified' and old 'Duration' data).
                let filtered = stages.isEmpty ? samples : stages
                
                // Sort by start date to merge intervals
                let sorted = filtered.sorted { $0.startDate < $1.startDate }
                var merged: [(start: Date, end: Date)] = []
                
                for s in sorted {
                    if let last = merged.last, s.startDate < last.end {
                        let newEnd = max(last.end, s.endDate)
                        merged[merged.count - 1] = (last.start, newEnd)
                    } else {
                        merged.append((s.startDate, s.endDate))
                    }
                }
                
                let totalSeconds = merged.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
                return totalSeconds / 3600.0
            }

            let todaySleepSamples = dtos.filter { $0.type == sleepType && calendar.isDate($0.endDate, inSameDayAs: date) }
            let finalSleep = calculateSleepDuration(samples: todaySleepSamples)
            
            var recTrend: [ChartDataPoint] = []
            var exeTrend: [ChartDataPoint] = []
            var batTrend: [ChartDataPoint] = []
            var slpTrend: [ChartDataPoint] = []
            
            let energySamples = dtos.filter { $0.type == energyType }
            let allSleepSamples = dtos.filter { $0.type == sleepType }
            
            for i in 0..<90 {
                guard let day = calendar.date(byAdding: .day, value: -i, to: date) else { continue }
                
                let rec = calculateRecoveryLocal(samples: dtos, date: day)
                recTrend.append(ChartDataPoint(date: day, value: rec))
                
                let energy = energySamples
                    .filter { calendar.isDate($0.endDate, inSameDayAs: day) }
                    .reduce(0) { $0 + $1.value }
                let exe = (energy / 1000.0) * 10.0
                exeTrend.append(ChartDataPoint(date: day, value: exe))
                
                let bat = min(max(rec - (exe * 5.0), 5.0), 100.0)
                batTrend.append(ChartDataPoint(date: day, value: bat))
                
                let daySleepSamples = allSleepSamples.filter { calendar.isDate($0.endDate, inSameDayAs: day) }
                let hrs = calculateSleepDuration(samples: daySleepSamples)
                if hrs > 0 {
                    slpTrend.append(ChartDataPoint(date: day, value: hrs))
                }
            }
            
            // 3. Dynamic Metric Grouping
            let allTypes = Set(dtos.map { $0.type })
            let excludedTypes: Set<String> = [energyType]
            let filtered = allTypes.subtracting(excludedTypes)
            
            var grouped: [String: [String]] = [:]
            for typeId in filtered {
                let info = HealthKitMetricInfo.info(for: typeId)
                grouped[info.category, default: []].append(typeId)
            }
            for (category, types) in grouped {
                grouped[category] = types.sorted {
                    HealthKitMetricInfo.info(for: $0).displayName < HealthKitMetricInfo.info(for: $1).displayName
                }
            }
            
            // Capture final results into immutable constants for safe transfer to Main Actor
            let resRecovery = recovery
            let resExertion = exertion
            let resBattery = battery
            let resSleep = finalSleep
            let resRecTrend = recTrend
            let resExeTrend = exeTrend
            let resBatTrend = batTrend
            let resSlpTrend = slpTrend
            let resGrouped = grouped
            
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.recoveryScore = resRecovery
                self.todayExertion = resExertion
                self.bodyBattery = resBattery
                self.sleepScore = resSleep
                
                self.recoveryHistory = resRecTrend
                self.exertionHistory = resExeTrend
                self.bodyBatteryHistory = resBatTrend
                self.sleepHistory = resSlpTrend
                
                self.groupedDiscoveredMetrics = resGrouped
                self.isCalculating = false
            }
        }
    }
}

public struct DashboardView: View {
    @EnvironmentObject private var syncManager: SyncManager
    @Environment(\.managedObjectContext) private var viewContext
    
    @FetchRequest(
        entity: HealthSample.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \HealthSample.endDate, ascending: false)],
        animation: .default)
    private var samples: FetchedResults<HealthSample>
    
    @StateObject private var viewModel = DashboardViewModel()
    
    let columns = [
        GridItem(.adaptive(minimum: 350, maximum: .infinity), spacing: 20)
    ]
    
    @State private var selectedNav: String? = "overview"
    @State private var selectedDate: Date = Date()
    @State private var selectedMetricTitle: String? = "Recovery"
    @State private var showingDatePicker = false
    
    @State private var draggedMetric: String?
    
    // Favorites are no longer needed since pinned metrics are fixed
    // and discovered metrics auto-populate
    
    // MARK: - Derived Metrics
    // These now come from the ViewModel to avoid main thread hangs
    
    private var currentChartConfiguration: ChartConfiguration? {
        guard let title = selectedMetricTitle else { return nil }
        // Pinned computed metrics
        switch title {
        case "Recovery": return ChartConfiguration(title: "Recovery", history: viewModel.recoveryHistory, color: .green)
        case "Sleep": return ChartConfiguration(title: "Sleep", history: viewModel.sleepHistory, color: .indigo)
        case "Exertion": return ChartConfiguration(title: "Exertion", history: viewModel.exertionHistory, color: .orange)
        case "Body Battery": return ChartConfiguration(title: "Body Battery", history: viewModel.bodyBatteryHistory, color: .cyan)
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
        let sleepHours = Int(viewModel.sleepScore)
let sleepMinutes = Int((viewModel.sleepScore - Double(sleepHours)) * 60)
        let sleepStr = sleepHours > 0 ? "\(sleepHours)h \(sleepMinutes)m" : "--h"
        
        switch title {
        case "Recovery":
            MetricCard(title: "Recovery", value: String(format: "%.0f%%", viewModel.recoveryScore), icon: "bolt.heart.fill", color: viewModel.recoveryScore > 66 ? .green : (viewModel.recoveryScore > 33 ? .yellow : .red), description: "Your body's readiness for physical and mental stress.", isSelected: selectedMetricTitle == "Recovery") { toggleMetric("Recovery") }
        case "Sleep":
            MetricCard(title: "Sleep", value: sleepStr, icon: "bed.double.fill", color: .indigo, description: "Total duration of your last recorded sleep session.", isSelected: selectedMetricTitle == "Sleep") { toggleMetric("Sleep") }
        case "Body Battery":
            MetricCard(title: "Body Battery", value: String(format: "%.0f", viewModel.bodyBattery), icon: "battery.100.bolt", color: .cyan, description: "Your remaining energy level for the day.", isSelected: selectedMetricTitle == "Body Battery") { toggleMetric("Body Battery") }
        case "Exertion":
            MetricCard(title: "Exertion", value: String(format: "%.1f", viewModel.todayExertion), icon: "flame.fill", color: .orange, description: "Daily strain based on your active energy expenditure.", isSelected: selectedMetricTitle == "Exertion") { toggleMetric("Exertion") }
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
            description: info.description,
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
                    headerView
                    overviewSection
                    categorySections
                }
                .padding(.vertical, 24)
            }
            .background(Color(NSColor.windowBackgroundColor))
            .onAppear {
                viewModel.updateIfNeeded(date: selectedDate)
            }
            .onChange(of: samples.count) {
                viewModel.updateIfNeeded(date: selectedDate)
            }
            .onChange(of: selectedMetricTitle) { oldValue, newValue in
                if let _ = newValue {
                    syncManager.requestFullSync()
                    viewModel.updateIfNeeded(date: selectedDate)
                }
            }
        }
    }
    
    @ViewBuilder
    private var headerView: some View {
        HStack(alignment: .center) {
            Text(Calendar.current.isDateInToday(selectedDate) ? "Today's Training Readiness" : "Training Readiness")
                .font(.system(size: 32, weight: .bold, design: .rounded))
            
            if viewModel.isCalculating {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 8)
            }
            
            Spacer()
            
            // Connection Status Indicator
            HStack(spacing: 8) {
                Circle()
                    .fill(syncManager.isConnected ? Color.green : (syncManager.nearbyPeers.isEmpty ? Color.red : Color.orange))
                    .frame(width: 8, height: 8)
                
                VStack(alignment: .leading, spacing: 0) {
                    Text(syncManager.isConnected ? "Connected to iPhone" : (syncManager.nearbyPeers.isEmpty ? "Disconnected" : "Found Device..."))
                        .font(.caption.bold())
                    
                    if !syncManager.isConnected && !syncManager.nearbyPeers.isEmpty {
                        Text(syncManager.nearbyPeers.first?.displayName ?? "")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                }
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(20)
            .onTapGesture {
                syncManager.reset()
            }
            .padding(.trailing, 8)
            
            // Full Sync Button
            Button(action: {
                syncManager.requestFullSync()
            }) {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.bold())
                    .symbolEffect(.rotate, options: .repeating, isActive: syncManager.isSyncing)
            }
            .disabled(!syncManager.isConnected || syncManager.isSyncing)
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
            .padding(.trailing, 8)
            
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
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Overview")
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(pinnedMetricTitles, id: \.self) { title in
                        pinnedCard(title)
                    }
                }
            }
            .padding(20)
            
            if let selected = selectedMetricTitle,
               pinnedMetricTitles.contains(selected),
               let config = currentChartConfiguration {
                DetailChartSection(config: config, selectedDate: selectedDate)
                    .padding(.bottom, 20)
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
    
    @ViewBuilder
    private var categorySections: some View {
        let grouped = viewModel.groupedDiscoveredMetrics
        let sortedCategories = HealthKitMetricInfo.categoryOrder.filter { grouped[$0] != nil }
        
        ForEach(sortedCategories, id: \.self) { category in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(category)
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    if syncManager.isSyncing {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .symbolEffect(.rotate, options: .repeating)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 10)
                
                if let typeIds = grouped[category] {
                    let metricChunks = typeIds.chunked(into: 4)
                    ForEach(metricChunks.indices, id: \.self) { i in
                        let chunk = metricChunks[i]
                        
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(chunk, id: \.self) { typeId in
                                dynamicCard(for: typeId)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, (chunk == metricChunks.last && selectedMetricTitle == nil) ? 20 : 10)
                        
                        if let selected = selectedMetricTitle,
                           chunk.contains(selected),
                           let config = currentChartConfiguration {
                            DetailChartSection(config: config, selectedDate: selectedDate)
                                .padding(.bottom, 20)
                        }
                    }
                }
            }
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
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
    var description: String = ""
    var isSelected: Bool
    var action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(color)
                    .symbolEffect(.bounce, options: .nonRepeating, value: isHovered)
                
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                
                Spacer()
                
                Text(value)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
            }
            
            if !description.isEmpty {
                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 100)
        .background(isSelected ? color.opacity(0.15) : Color(NSColor.controlBackgroundColor))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isSelected ? color : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
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
    
    var binnedHistory: [ChartDataPoint] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: config.history, by: { calendar.startOfDay(for: $0.date) })
        let allBinned = grouped.map { (key, value) -> ChartDataPoint in
            let avg = value.reduce(0) { $0 + $1.value } / Double(value.count)
            return ChartDataPoint(date: key, value: avg)
        }.sorted { $0.date < $1.date }
        
        guard let latest = allBinned.last?.date else { return [] }
        let startLimit = latest.addingTimeInterval(-filter.timeInterval + 3600)
        return allBinned.filter { $0.date >= startLimit }
    }
    
    private var dateDomain: (start: Date, end: Date) {
        let points = binnedHistory
        guard let first = points.first?.date, let last = points.last?.date else {
            let end = selectedDate
            let start = end.addingTimeInterval(-filter.timeInterval)
            return (start, end)
        }
        return (first, last)
    }
    
    var yDomain: ClosedRange<Double> {
        let values = binnedHistory.map { $0.value }.filter { $0.isFinite }
        let rawMin = values.min() ?? 0
        let rawMax = values.max() ?? 10
        
        // Only use the 70.0 threshold for percentage-based metrics
        let isPercentage = config.title == "Recovery" || config.title == "Body Battery"
        let threshold = 70.0
        
        let minVal = isPercentage ? min(rawMin, threshold * 0.5) : rawMin * 0.9
        let maxVal = isPercentage ? max(rawMax, threshold * 1.1) : rawMax * 1.1
        
        let diff = maxVal - minVal
        let padding = max(diff * 0.05, 0.5)
        
        let start = minVal - padding
        let end = maxVal + padding
        
        return (start.isFinite ? start : 0)...(end.isFinite ? end : 10)
    }
    
    private func findClosest(to target: Date, in history: [ChartDataPoint]) -> ChartDataPoint? {
        history.min(by: { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) })
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            chartHeader
                .padding(.horizontal, 20)
            
            if binnedHistory.isEmpty {
                emptyStateView
            } else {
                chartMainView
            }
        }
        .padding(.vertical, 24)
        .frame(height: 350)
        .frame(maxWidth: .infinity)
        .background(Color.clear)
    }
    
    @ViewBuilder
    private var chartHeader: some View {
        HStack {
            Text("\(config.title) Trend")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Spacer()
            
            HStack(spacing: 0) {
                ForEach([TimeFilter.w1, .d30, .d60, .d90], id: \.self) { f in
                    filterButton(f)
                }
            }
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
        }
    }
    
    @ViewBuilder
    private func filterButton(_ f: TimeFilter) -> some View {
        Text(f.rawValue)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(filter == f ? Color.orange : Color.gray.opacity(0.1))
            .foregroundColor(filter == f ? .white : .primary)
            .onTapGesture { filter = f }
    }
    
    @ViewBuilder
    private var emptyStateView: some View {
        Text("No data for this period")
            .font(.subheadline)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @ViewBuilder
    private var chartMainView: some View {
        let gradient = LinearGradient(colors: [config.color.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom)
        
        Chart {
            chartMainContent(gradient: gradient)
        }
        .chartXScale(domain: dateDomain.start...dateDomain.end)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: filter == .w1 ? 2 : (filter == .d30 ? 7 : 14))) { value in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month().day())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine()
                AxisValueLabel()
                    .offset(x: -16)
            }
            AxisMarks(position: .trailing) { _ in
                AxisValueLabel()
                    .offset(x: 16)
            }
        }
        .chartOverlay { chartOverlay($0) }
        .padding(.horizontal, 32)
        .clipped()
    }
    
    @ChartContentBuilder
    private func chartMainContent(gradient: LinearGradient) -> some ChartContent {
        chartAnnotations
        chartDataMarks(gradient: gradient)
        chartHoverSelection
    }
    
    
    @ChartContentBuilder
    private var chartAnnotations: some ChartContent {
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
        }
    }
    
    @ChartContentBuilder
    private func chartDataMarks(gradient: LinearGradient) -> some ChartContent {
        ForEach(binnedHistory) { point in
            AreaMark(x: .value("Date", point.date), y: .value("Value", point.value))
                .foregroundStyle(gradient)
                .interpolationMethod(.catmullRom)
            
            LineMark(x: .value("Date", point.date), y: .value("Value", point.value))
                .foregroundStyle(config.color)
                .lineStyle(StrokeStyle(lineWidth: 3))
                .interpolationMethod(.catmullRom)
            
            PointMark(x: .value("Date", point.date), y: .value("Value", point.value))
                .foregroundStyle(config.color)
                .symbolSize(30)
        }
    }
    
    @ChartContentBuilder
    private var chartHoverSelection: some ChartContent {
        if let hoverDate = rawSelectedDate,
           let closestData = findClosest(to: hoverDate, in: binnedHistory) {
            RuleMark(x: .value("Selected Date", closestData.date))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5]))
                .foregroundStyle(Color.gray.opacity(0.5))
        }
    }
    
    private func chartOverlay(_ proxy: ChartProxy) -> some View {
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
                tooltipView(data: closestData, xPos: xPos, totalWidth: geo.size.width)
            }
        }
    }
    
    @ViewBuilder
    private func tooltipView(data: ChartDataPoint, xPos: CGFloat, totalWidth: CGFloat) -> some View {
        let xOffset = min(max(xPos, 60), totalWidth - 60)
        
        VStack(alignment: .leading, spacing: 6) {
            Text(data.date, format: .dateTime.month().day())
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text(String(format: "%.1f", data.value))
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
        .position(x: xOffset, y: 35)
    }
}
#endif
