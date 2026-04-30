import Foundation

public class AlgorithmManager {
    public static let shared = AlgorithmManager()
    
    // Baselines are now dynamically calculated (30-day moving average)
    private let targetSleepHours: Double = 8.0 // hours
    private let maxExpectedEnergy: Double = 1000.0 // kcals
    
    private init() {}
    
    /// Calculates Readiness/Recovery Score (0-100%) dynamically using a 30-day baseline.
    public func calculateRecovery(samples: [HealthSample], date: Date = Date(), sleepHours: Double?) -> Double {
        let calendar = Calendar.current
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: date) ?? Date.distantPast
        
        // Filter by type
        let hrvSamples = samples.filter { $0.type == String.heartRateVariabilitySDNN }
        let rhrSamples = samples.filter { $0.type == String.restingHeartRate }
        
        // Calculate 30-day baselines
        let pastHRVs = hrvSamples.filter { $0.endDate >= thirtyDaysAgo && $0.endDate < calendar.startOfDay(for: date) }
        let baselineHRV = pastHRVs.isEmpty ? 50.0 : pastHRVs.reduce(0) { $0 + $1.value } / Double(pastHRVs.count)
        
        let pastRHRs = rhrSamples.filter { $0.endDate >= thirtyDaysAgo && $0.endDate < calendar.startOfDay(for: date) }
        let baselineRHR = pastRHRs.isEmpty ? 60.0 : pastRHRs.reduce(0) { $0 + $1.value } / Double(pastRHRs.count)
        
        // Get today's latest values
        let latestHRV = hrvSamples.first(where: { calendar.isDate($0.endDate, inSameDayAs: date) })?.value
        let latestRHR = rhrSamples.first(where: { calendar.isDate($0.endDate, inSameDayAs: date) })?.value
        
        guard latestHRV != nil || latestRHR != nil || sleepHours != nil else { return 50.0 }
        
        var hrvScore = 0.5
        var rhrScore = 0.5
        var slpScore = 0.5
        var factorsCount = 0.0
        
        if let hrv = latestHRV {
            let ratio = hrv / baselineHRV
            // Strict mapping: ratio 1.0 -> 0.5 score. 1.2 -> 1.0 score. 0.8 -> 0.0 score.
            hrvScore = min(max((ratio - 0.8) / 0.4, 0.0), 1.0)
            factorsCount += 1
        }
        
        if let rhr = latestRHR {
            let ratio = baselineRHR / rhr // lower RHR is better
            rhrScore = min(max((ratio - 0.8) / 0.4, 0.0), 1.0)
            factorsCount += 1
        }
        
        if let sleep = sleepHours {
            // Strict sleep mapping: 8h -> 1.0, 6h -> 0.5, 4h -> 0.0
            slpScore = min(max((sleep - 4.0) / 4.0, 0.0), 1.0)
            factorsCount += 1
        }
        
        let totalScore = factorsCount > 0 ? (hrvScore + rhrScore + slpScore) / factorsCount : 0.5
        return min(max(totalScore * 100.0, 1.0), 100.0)
    }
    
    /// Calculates Exertion Strain (0.0 - 10.0)
    public func calculateExertion(activeEnergyKcals: Double) -> Double {
        let exertion = (activeEnergyKcals / maxExpectedEnergy) * 10.0
        return min(max(exertion, 0.0), 10.0)
    }
    
    /// Calculates current Body Battery (0 - 100)
    public func calculateBodyBattery(recoveryScore: Double, exertionScore: Double) -> Double {
        // Battery starts the day at the Recovery Score capacity.
        // It depletes by ~5 points for every 1.0 of Exertion.
        let currentBattery = recoveryScore - (exertionScore * 5.0)
        return min(max(currentBattery, 5.0), 100.0) // Bottom out at 5%
    }
}

public extension String {
    static let heartRateVariabilitySDNN = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
    static let restingHeartRate = "HKQuantityTypeIdentifierRestingHeartRate"
    static let respiratoryRate = "HKQuantityTypeIdentifierRespiratoryRate"
    static let oxygenSaturation = "HKQuantityTypeIdentifierOxygenSaturation"
    static let activeEnergyBurned = "HKQuantityTypeIdentifierActiveEnergyBurned"
}
