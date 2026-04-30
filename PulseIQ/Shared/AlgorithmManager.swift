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
        let pastHRVs = hrvSamples.filter { $0.endDate >= thirtyDaysAgo && $0.endDate < calendar.startOfDay(for: date) && $0.value.isFinite }
        let baselineHRV = pastHRVs.isEmpty ? 50.0 : pastHRVs.reduce(0) { $0 + $1.value } / Double(pastHRVs.count)
        
        let pastRHRs = rhrSamples.filter { $0.endDate >= thirtyDaysAgo && $0.endDate < calendar.startOfDay(for: date) && $0.value.isFinite }
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

nonisolated extension String {
    static let heartRateVariabilitySDNN = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
    static let restingHeartRate = "HKQuantityTypeIdentifierRestingHeartRate"
    static let respiratoryRate = "HKQuantityTypeIdentifierRespiratoryRate"
    static let oxygenSaturation = "HKQuantityTypeIdentifierOxygenSaturation"
    static let activeEnergyBurned = "HKQuantityTypeIdentifierActiveEnergyBurned"
    static let basalEnergyBurned = "HKQuantityTypeIdentifierBasalEnergyBurned"
    static let heartRate = "HKQuantityTypeIdentifierHeartRate"
    static let stepCount = "HKQuantityTypeIdentifierStepCount"
    static let distanceWalkingRunning = "HKQuantityTypeIdentifierDistanceWalkingRunning"
    static let distanceCycling = "HKQuantityTypeIdentifierDistanceCycling"
    static let distanceSwimming = "HKQuantityTypeIdentifierDistanceSwimming"
    static let swimmingStrokeCount = "HKQuantityTypeIdentifierSwimmingStrokeCount"
    static let flightsClimbed = "HKQuantityTypeIdentifierFlightsClimbed"
    static let bodyMass = "HKQuantityTypeIdentifierBodyMass"
    static let bodyMassIndex = "HKQuantityTypeIdentifierBodyMassIndex"
    static let leanBodyMass = "HKQuantityTypeIdentifierLeanBodyMass"
    static let bodyFatPercentage = "HKQuantityTypeIdentifierBodyFatPercentage"
    static let height = "HKQuantityTypeIdentifierHeight"
    static let waistCircumference = "HKQuantityTypeIdentifierWaistCircumference"
    static let vo2Max = "HKQuantityTypeIdentifierVO2Max"
    static let walkingHeartRateAverage = "HKQuantityTypeIdentifierWalkingHeartRateAverage"
    static let heartRateRecoveryOneMinute = "HKQuantityTypeIdentifierHeartRateRecoveryOneMinute"
    static let appleExerciseTime = "HKQuantityTypeIdentifierAppleExerciseTime"
    static let appleMoveTime = "HKQuantityTypeIdentifierAppleMoveTime"
    static let appleStandTime = "HKQuantityTypeIdentifierAppleStandTime"
    static let sleepAnalysis = "HKCategoryTypeIdentifierSleepAnalysis"
    static let sleepDurationGoal = "HKQuantityTypeIdentifierSleepDurationGoal"
    static let appleSleepingWristTemperature = "HKQuantityTypeIdentifierAppleSleepingWristTemperature"
    static let environmentalAudioExposure = "HKQuantityTypeIdentifierEnvironmentalAudioExposure"
    static let headphoneAudioExposure = "HKQuantityTypeIdentifierHeadphoneAudioExposure"
    static let walkingSpeed = "HKQuantityTypeIdentifierWalkingSpeed"
    static let walkingStepLength = "HKQuantityTypeIdentifierWalkingStepLength"
    static let walkingAsymmetryPercentage = "HKQuantityTypeIdentifierWalkingAsymmetryPercentage"
    static let walkingDoubleSupportPercentage = "HKQuantityTypeIdentifierWalkingDoubleSupportPercentage"
    static let stairAscentSpeed = "HKQuantityTypeIdentifierStairAscentSpeed"
    static let stairDescentSpeed = "HKQuantityTypeIdentifierStairDescentSpeed"
    static let sixMinuteWalkTestDistance = "HKQuantityTypeIdentifierSixMinuteWalkTestDistance"
    static let bloodPressureSystolic = "HKQuantityTypeIdentifierBloodPressureSystolic"
    static let bloodPressureDiastolic = "HKQuantityTypeIdentifierBloodPressureDiastolic"
    static let bloodGlucose = "HKQuantityTypeIdentifierBloodGlucose"
    static let bodyTemperature = "HKQuantityTypeIdentifierBodyTemperature"
    static let dietaryEnergyConsumed = "HKQuantityTypeIdentifierDietaryEnergyConsumed"
    static let dietaryProtein = "HKQuantityTypeIdentifierDietaryProtein"
    static let dietaryCarbohydrates = "HKQuantityTypeIdentifierDietaryCarbohydrates"
    static let dietaryFatTotal = "HKQuantityTypeIdentifierDietaryFatTotal"
    static let dietaryWater = "HKQuantityTypeIdentifierDietaryWater"
    static let dietaryCaffeine = "HKQuantityTypeIdentifierDietaryCaffeine"
    static let atrialFibrillationBurden = "HKQuantityTypeIdentifierAtrialFibrillationBurden"
    static let numberOfTimesFallen = "HKQuantityTypeIdentifierNumberOfTimesFallen"
    static let peripheralPerfusionIndex = "HKQuantityTypeIdentifierPeripheralPerfusionIndex"
}

/// Registry mapping HK identifiers to human-friendly display metadata.
public struct HealthKitMetricInfo: Sendable {
    public let displayName: String
    public let unit: String
    public let icon: String
    public let colorName: String
    public let multiplier: Double
    public let category: String  // Apple Health-style grouping
    public let description: String
    
    nonisolated public init(displayName: String, unit: String, icon: String, colorName: String, multiplier: Double, category: String, description: String = "") {
        self.displayName = displayName
        self.unit = unit
        self.icon = icon
        self.colorName = colorName
        self.multiplier = multiplier
        self.category = category
        self.description = description
    }
    
    /// Returns display info for any known HK type identifier, or a sensible default.
    nonisolated public static func info(for typeIdentifier: String) -> HealthKitMetricInfo {
        return registry[typeIdentifier] ?? HealthKitMetricInfo(
            displayName: typeIdentifier
                .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
                .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: ""),
            unit: "",
            icon: "chart.line.uptrend.xyaxis",
            colorName: "gray",
            multiplier: 1.0,
            category: "Other",
            description: "No additional data recorded."
        )
    }
    
    /// Ordered list of categories matching Apple Health's layout
    nonisolated public static let categoryOrder = ["Heart", "Activity", "Sleep", "Body Measurements", "Respiratory", "Vitals", "Mobility", "Nutrition", "Hearing", "Other"]
    
    nonisolated private static let registry: [String: HealthKitMetricInfo] = [
        // Heart
        String.heartRate: .init(displayName: "Heart Rate", unit: "bpm", icon: "heart.fill", colorName: "red", multiplier: 1.0, category: "Heart", description: "The number of times your heart beats per minute."),
        String.restingHeartRate: .init(displayName: "Resting HR", unit: "bpm", icon: "heart.fill", colorName: "red", multiplier: 1.0, category: "Heart", description: "Your heart rate when you are at rest."),
        String.walkingHeartRateAverage: .init(displayName: "Walking HR", unit: "bpm", icon: "figure.walk", colorName: "red", multiplier: 1.0, category: "Heart", description: "Your average heart rate while walking."),
        String.heartRateVariabilitySDNN: .init(displayName: "HRV", unit: "ms", icon: "waveform.path.ecg", colorName: "red", multiplier: 1.0, category: "Heart", description: "The variation in time between each heartbeat."),
        String.heartRateRecoveryOneMinute: .init(displayName: "HR Recovery", unit: "bpm", icon: "heart.text.square", colorName: "red", multiplier: 1.0, category: "Heart", description: "The reduction in heart rate one minute after stopping exercise."),
        String.atrialFibrillationBurden: .init(displayName: "AFib Burden", unit: "%", icon: "waveform.path.ecg.rectangle", colorName: "red", multiplier: 100.0, category: "Heart", description: "The percentage of time spent in Atrial Fibrillation."),
        String.vo2Max: .init(displayName: "VO2 Max", unit: "mL/kg·min", icon: "lungs.fill", colorName: "mint", multiplier: 1.0, category: "Heart", description: "A measurement of the maximum amount of oxygen your body can use during exercise."),
        // Activity         String.activeEnergyBurned: .init(displayName: "Active Energy", unit: "kcal", icon: "flame.fill", colorName: "orange", multiplier: 1.0, category: "Activity", description: "Energy burned from exercise and movement."),
        // Sleep
        String.sleepAnalysis: .init(displayName: "Sleep", unit: "hrs", icon: "bed.double.fill", colorName: "indigo", multiplier: 1.0/3600.0, category: "Sleep", description: "The total time you spent asleep."),
        String.sleepDurationGoal: .init(displayName: "Sleep Goal", unit: "hrs", icon: "target", colorName: "indigo", multiplier: 1.0/3600.0, category: "Sleep", description: "Your daily target for sleep duration."),
        String.basalEnergyBurned: .init(displayName: "Resting Energy", unit: "kcal", icon: "bolt.fill", colorName: "yellow", multiplier: 1.0, category: "Activity", description: "Energy your body burns while at rest."),

        String.stepCount: .init(displayName: "Steps", unit: "steps", icon: "figure.walk", colorName: "green", multiplier: 1.0, category: "Activity", description: "The total number of steps taken during the day."),
        String.distanceWalkingRunning: .init(displayName: "Distance", unit: "m", icon: "map.fill", colorName: "green", multiplier: 1.0, category: "Activity", description: "Distance traveled while walking or running."),
        String.distanceCycling: .init(displayName: "Cycling", unit: "m", icon: "bicycle", colorName: "green", multiplier: 1.0, category: "Activity", description: "Distance traveled while cycling."),
        String.distanceSwimming: .init(displayName: "Swimming", unit: "m", icon: "figure.pool.swim", colorName: "blue", multiplier: 1.0, category: "Activity", description: "Distance traveled while swimming."),
        String.swimmingStrokeCount: .init(displayName: "Swim Strokes", unit: "strokes", icon: "figure.pool.swim", colorName: "blue", multiplier: 1.0, category: "Activity", description: "Total number of swimming strokes."),
        String.flightsClimbed: .init(displayName: "Flights Climbed", unit: "floors", icon: "arrow.up.right", colorName: "green", multiplier: 1.0, category: "Activity", description: "The number of flights of stairs climbed."),
        String.appleExerciseTime: .init(displayName: "Exercise Time", unit: "min", icon: "figure.run", colorName: "green", multiplier: 1.0, category: "Activity", description: "The amount of time you have been active at or above a brisk walk intensity."),
        String.appleMoveTime: .init(displayName: "Move Time", unit: "min", icon: "figure.walk", colorName: "green", multiplier: 1.0, category: "Activity", description: "The amount of time you have been moving during the day."),
        String.appleStandTime: .init(displayName: "Stand Time", unit: "min", icon: "figure.stand", colorName: "cyan", multiplier: 1.0, category: "Activity", description: "The number of hours in which you stood and moved for at least one minute."),
        // Body Measurements
        String.bodyMass: .init(displayName: "Weight", unit: "kg", icon: "scalemass.fill", colorName: "purple", multiplier: 1.0, category: "Body Measurements", description: "Your current body weight."),
        String.bodyMassIndex: .init(displayName: "BMI", unit: "", icon: "person.fill", colorName: "purple", multiplier: 1.0, category: "Body Measurements", description: "A calculation based on height and weight."),
        String.leanBodyMass: .init(displayName: "Lean Mass", unit: "kg", icon: "figure.strengthtraining.traditional", colorName: "purple", multiplier: 1.0, category: "Body Measurements", description: "Your weight excluding body fat."),
        String.bodyFatPercentage: .init(displayName: "Body Fat", unit: "%", icon: "person.fill", colorName: "purple", multiplier: 100.0, category: "Body Measurements", description: "The percentage of your body weight that is fat."),
        String.height: .init(displayName: "Height", unit: "cm", icon: "ruler", colorName: "purple", multiplier: 1.0, category: "Body Measurements", description: "Your current height."),
        String.waistCircumference: .init(displayName: "Waist", unit: "cm", icon: "circle.dashed", colorName: "purple", multiplier: 1.0, category: "Body Measurements", description: "The measurement around your waist."),
        // Respiratory
        String.respiratoryRate: .init(displayName: "Respiratory Rate", unit: "rpm", icon: "lungs.fill", colorName: "teal", multiplier: 1.0, category: "Respiratory", description: "The number of breaths you take per minute."),
        String.oxygenSaturation: .init(displayName: "SpO2", unit: "%", icon: "o.circle.fill", colorName: "blue", multiplier: 100.0, category: "Respiratory", description: "The percentage of oxygen in your blood."),
        // Vitals
        String.bodyTemperature: .init(displayName: "Body Temp", unit: "°C", icon: "thermometer.medium", colorName: "orange", multiplier: 1.0, category: "Vitals", description: "Your core body temperature."),
        String.appleSleepingWristTemperature: .init(displayName: "Wrist Temp", unit: "°C", icon: "thermometer.medium", colorName: "orange", multiplier: 1.0, category: "Vitals", description: "The temperature of your wrist while you sleep."),
        String.bloodPressureSystolic: .init(displayName: "BP Systolic", unit: "mmHg", icon: "heart.circle.fill", colorName: "red", multiplier: 1.0, category: "Vitals", description: "The pressure in your arteries when your heart beats."),
        String.bloodPressureDiastolic: .init(displayName: "BP Diastolic", unit: "mmHg", icon: "heart.circle", colorName: "pink", multiplier: 1.0, category: "Vitals", description: "The pressure in your arteries when your heart rests between beats."),
        String.bloodGlucose: .init(displayName: "Blood Glucose", unit: "mg/dL", icon: "drop.fill", colorName: "red", multiplier: 1.0, category: "Vitals", description: "The concentration of glucose in your blood."),
        // Mobility
        String.walkingSpeed: .init(displayName: "Walking Speed", unit: "m/s", icon: "figure.walk", colorName: "mint", multiplier: 1.0, category: "Mobility", description: "The speed at which you walk on flat ground."),
        String.walkingStepLength: .init(displayName: "Step Length", unit: "cm", icon: "ruler.fill", colorName: "mint", multiplier: 1.0, category: "Mobility", description: "The distance between your feet during a step."),
        String.walkingAsymmetryPercentage: .init(displayName: "Walk Asymmetry", unit: "%", icon: "figure.walk", colorName: "mint", multiplier: 100.0, category: "Mobility", description: "The difference in step time between your left and right feet."),
        String.walkingDoubleSupportPercentage: .init(displayName: "Double Support", unit: "%", icon: "figure.walk", colorName: "mint", multiplier: 100.0, category: "Mobility", description: "The percentage of a walk where both feet are on the ground."),
        String.stairAscentSpeed: .init(displayName: "Stair Ascent", unit: "m/s", icon: "arrow.up.right", colorName: "mint", multiplier: 1.0, category: "Mobility", description: "The speed at which you climb a flight of stairs."),
        String.stairDescentSpeed: .init(displayName: "Stair Descent", unit: "m/s", icon: "arrow.down.right", colorName: "mint", multiplier: 1.0, category: "Mobility", description: "The speed at which you descend a flight of stairs."),
        String.sixMinuteWalkTestDistance: .init(displayName: "6-Min Walk", unit: "m", icon: "figure.walk", colorName: "mint", multiplier: 1.0, category: "Mobility", description: "The distance you can walk on a flat surface in six minutes."),
        // Nutrition
        String.dietaryEnergyConsumed: .init(displayName: "Calories In", unit: "kcal", icon: "fork.knife", colorName: "orange", multiplier: 1.0, category: "Nutrition", description: "The total energy consumed from food and drink."),
        String.dietaryProtein: .init(displayName: "Protein", unit: "g", icon: "fork.knife", colorName: "orange", multiplier: 1.0, category: "Nutrition", description: "Total protein consumed."),
        String.dietaryCarbohydrates: .init(displayName: "Carbs", unit: "g", icon: "fork.knife", colorName: "orange", multiplier: 1.0, category: "Nutrition", description: "Total carbohydrates consumed."),
        String.dietaryFatTotal: .init(displayName: "Fat", unit: "g", icon: "fork.knife", colorName: "orange", multiplier: 1.0, category: "Nutrition", description: "Total fat consumed."),
        String.dietaryWater: .init(displayName: "Water", unit: "mL", icon: "drop.fill", colorName: "blue", multiplier: 1.0, category: "Nutrition", description: "Total amount of water consumed."),
        String.dietaryCaffeine: .init(displayName: "Caffeine", unit: "mg", icon: "cup.and.saucer.fill", colorName: "brown", multiplier: 1.0, category: "Nutrition", description: "Total caffeine consumed."),
        // Hearing
        String.environmentalAudioExposure: .init(displayName: "Env. Sound", unit: "dB", icon: "ear.fill", colorName: "blue", multiplier: 1.0, category: "Hearing", description: "Exposure to environmental sound levels."),
        String.headphoneAudioExposure: .init(displayName: "Headphone Audio", unit: "dB", icon: "headphones", colorName: "blue", multiplier: 1.0, category: "Hearing", description: "Exposure to headphone sound levels."),
        // Other
        String.numberOfTimesFallen: .init(displayName: "Falls", unit: "", icon: "figure.fall", colorName: "red", multiplier: 1.0, category: "Other", description: "The number of times a fall was detected."),
        String.peripheralPerfusionIndex: .init(displayName: "Perfusion Index", unit: "%", icon: "drop.circle.fill", colorName: "red", multiplier: 100.0, category: "Other", description: "A measure of the pulse strength at the sensor site."),
    ]
}
