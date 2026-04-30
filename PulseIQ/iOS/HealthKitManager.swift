#if os(iOS)
import Foundation
import HealthKit
import CoreData
import Combine

public class HealthKitManager: ObservableObject {
    public static let shared = HealthKitManager()
    let healthStore = HKHealthStore()
    
    @Published public var isAuthorized = false
    
    private init() {
        NotificationCenter.default.addObserver(forName: Notification.Name("TriggerFullSync"), object: nil, queue: .main) { _ in
            self.forceSyncAll()
        }
    }
    
    // MARK: - All supported HealthKit quantity types
    
    /// Comprehensive list of all quantity types we want to read from HealthKit.
    /// This covers the vast majority of metrics available on Apple Watch & iPhone.
    private static let allQuantityTypes: [HKQuantityTypeIdentifier] = [
        // Heart & Cardiovascular
        .heartRate,
        .restingHeartRate,
        .walkingHeartRateAverage,
        .heartRateVariabilitySDNN,
        .heartRateRecoveryOneMinute,
        .atrialFibrillationBurden,
        
        // Respiratory
        .respiratoryRate,
        .oxygenSaturation,
        .forcedExpiratoryVolume1,
        .forcedVitalCapacity,
        .peakExpiratoryFlowRate,
        
        // Activity & Energy
        .activeEnergyBurned,
        .basalEnergyBurned,
        .stepCount,
        .distanceWalkingRunning,
        .distanceCycling,
        .distanceSwimming,
        .swimmingStrokeCount,
        .flightsClimbed,
        .appleExerciseTime,
        .appleMoveTime,
        .appleStandTime,
        .nikeFuel,
        
        // Body Measurements
        .bodyMass,
        .bodyMassIndex,
        .leanBodyMass,
        .bodyFatPercentage,
        .height,
        .waistCircumference,
        
        // Vitals
        .bodyTemperature,
        .bloodPressureSystolic,
        .bloodPressureDiastolic,
        .bloodGlucose,
        
        // Nutrition
        .dietaryEnergyConsumed,
        .dietaryProtein,
        .dietaryCarbohydrates,
        .dietaryFatTotal,
        .dietaryWater,
        .dietaryCaffeine,
        
        // Other
        .numberOfTimesFallen,
        .uvExposure,
        .electrodermalActivity,
        .peripheralPerfusionIndex,
        
        // Audio
        .environmentalAudioExposure,
        .headphoneAudioExposure,
        
        // Mobility
        .walkingSpeed,
        .walkingStepLength,
        .walkingAsymmetryPercentage,
        .walkingDoubleSupportPercentage,
        .stairAscentSpeed,
        .stairDescentSpeed,
        .sixMinuteWalkTestDistance,
    ]
    
    /// Build the set of HKObjectTypes to request read access for
    private static var allReadTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        
        for identifier in allQuantityTypes {
            if let qType = HKObjectType.quantityType(forIdentifier: identifier) {
                types.insert(qType)
            }
        }
        
        // Category types
        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleepType)
        }
        
        // iOS 16+ types
        if #available(iOS 16.0, *) {
            if let wristTemp = HKObjectType.quantityType(forIdentifier: .appleSleepingWristTemperature) {
                types.insert(wristTemp)
            }
        }
        
        // iOS 17+ types
        if #available(iOS 17.0, *) {
            if let cardioFitness = HKObjectType.quantityType(forIdentifier: .vo2Max) {
                types.insert(cardioFitness)
            }
        }
        
        return types
    }
    
    public func requestAuthorization(completion: @escaping (Bool) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(false)
            return
        }
        
        healthStore.requestAuthorization(toShare: nil, read: Self.allReadTypes) { success, error in
            DispatchQueue.main.async {
                self.isAuthorized = success
                completion(success)
            }
        }
    }
    
    // Setup observer query for background syncing
    public func startObserving() {
        guard isAuthorized else { return }
        
        for identifier in Self.allQuantityTypes {
            guard let sampleType = HKObjectType.quantityType(forIdentifier: identifier) else { continue }
            
            let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { [weak self] query, completionHandler, error in
                guard error == nil else {
                    completionHandler()
                    return
                }
                
                // Fetch the actual data delta
                self?.fetchLatestData(for: sampleType) {
                    completionHandler()
                }
            }
            
            healthStore.execute(query)
            healthStore.enableBackgroundDelivery(for: sampleType, frequency: .hourly) { success, error in
                if let error = error {
                    print("Failed to enable background delivery for \(identifier.rawValue): \(error.localizedDescription)")
                }
            }
        }
    }
    
    public func checkAuthorizationStatus() {
        // Since HealthKit doesn't have a single "is authorized" property, we request it on launch. 
        // If already granted, this is a no-op that just returns success immediately.
        requestAuthorization { success in
            if success {
                self.startObserving()
            }
        }
    }
    
    public func forceSyncAll() {
        guard isAuthorized else { return }
        
        // Fetch all quantity types
        for identifier in Self.allQuantityTypes {
            if let sampleType = HKObjectType.quantityType(forIdentifier: identifier) {
                fetchLatestData(for: sampleType) {}
            }
        }
        
        // Fetch Sleep
        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            fetchSleepData(for: sleepType)
        }
        
        // Also add iOS 16+ types
        if #available(iOS 16.0, *) {
            if let wristTemp = HKObjectType.quantityType(forIdentifier: .appleSleepingWristTemperature) {
                fetchLatestData(for: wristTemp) {}
            }
        }
        
        // Then send ALL stored data to the Mac
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.forceSendAllStoredData()
        }
    }
    
    private func fetchSleepData(for type: HKCategoryType) {
        let lastDate = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: lastDate, end: Date(), options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1000, sortDescriptors: [sortDescriptor]) { _, samples, error in
            guard let categorySamples = samples as? [HKCategorySample], error == nil else { return }
            
            let context = CoreDataManager.shared.container.newBackgroundContext()
            context.perform {
                var newSamples: [HealthSample] = []
                for sample in categorySamples {
                    let healthSample = HealthSample(context: context)
                    healthSample.id = sample.uuid
                    healthSample.type = "HKCategoryTypeIdentifierSleepAnalysis"
                    
                    // For sleep, we store duration in hours as the value
                    let duration = sample.endDate.timeIntervalSince(sample.startDate) / 3600.0
                    healthSample.value = duration
                    healthSample.startDate = sample.startDate
                    healthSample.endDate = sample.endDate
                    newSamples.append(healthSample)
                }
                
                if context.hasChanges {
                    try? context.save()
                    SyncManager.shared.send(samples: newSamples)
                }
            }
        }
        healthStore.execute(query)
    }
    
    /// Reads ALL samples from local CoreData and sends them to connected peers.
    /// This ensures the Mac receives the full historical dataset.
    public func forceSendAllStoredData() {
        let context = CoreDataManager.shared.container.viewContext
        let fetchRequest: NSFetchRequest<HealthSample> = NSFetchRequest(entityName: "HealthSample")
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "endDate", ascending: false)]
        
        context.perform {
            guard let allSamples = try? context.fetch(fetchRequest), !allSamples.isEmpty else {
                print("No stored samples to send.")
                return
            }
            
            // Send in batches of 500 to avoid hitting MultipeerConnectivity size limits
            let batchSize = 500
            let batches = stride(from: 0, to: allSamples.count, by: batchSize).map {
                Array(allSamples[$0..<min($0 + batchSize, allSamples.count)])
            }
            
            for (index, batch) in batches.enumerated() {
                SyncManager.shared.send(samples: batch)
                print("Sent batch \(index + 1)/\(batches.count) (\(batch.count) samples)")
            }
            
            print("Force-sent all \(allSamples.count) stored samples to Mac.")
        }
    }
    
    private func fetchLatestData(for type: HKQuantityType, completion: @escaping () -> Void) {
        let fetchRequest: NSFetchRequest<HealthSample> = NSFetchRequest(entityName: "HealthSample")
        fetchRequest.predicate = NSPredicate(format: "type == %@", type.identifier)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "endDate", ascending: false)]
        fetchRequest.fetchLimit = 1
        
        let context = CoreDataManager.shared.container.viewContext
        var lastDate = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        
        context.performAndWait {
            if let lastSample = try? context.fetch(fetchRequest).first, lastSample.endDate > lastDate {
                lastDate = lastSample.endDate
            }
        }
        
        let predicate = HKQuery.predicateForSamples(withStart: lastDate, end: Date(), options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        
        // Limit query to last 1000 samples to avoid memory issues and timeouts
        let sampleQuery = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1000, sortDescriptors: [sortDescriptor]) { _, samples, error in
            guard let quantitySamples = samples as? [HKQuantitySample], error == nil else {
                completion()
                return
            }
            
            context.perform {
                var newSamples: [HealthSample] = []
                let unit = self.unit(for: type)
                
                for sample in quantitySamples {
                    // Safety check: Ensure the quantity is compatible with the unit before conversion
                    guard sample.quantity.is(compatibleWith: unit) else {
                        print("HealthKitManager: Skipping sample \(sample.uuid) - Incompatible unit \(unit.unitString) for type \(type.identifier)")
                        continue
                    }
                    
                    let healthSample = HealthSample(context: context)
                    healthSample.id = sample.uuid
                    healthSample.type = sample.sampleType.identifier
                    healthSample.value = sample.quantity.doubleValue(for: unit)
                    healthSample.startDate = sample.startDate
                    healthSample.endDate = sample.endDate
                    newSamples.append(healthSample)
                }
                
                if context.hasChanges {
                    try? context.save()
                    SyncManager.shared.send(samples: newSamples)
                }
                completion()
            }
        }
        
        healthStore.execute(sampleQuery)
    }
    
    private func unit(for type: HKQuantityType) -> HKUnit {
        switch type.identifier {
        // Heart
        case HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue:
            return HKUnit.secondUnit(with: .milli)
        case HKQuantityTypeIdentifier.restingHeartRate.rawValue,
             HKQuantityTypeIdentifier.heartRate.rawValue,
             HKQuantityTypeIdentifier.walkingHeartRateAverage.rawValue:
            return HKUnit.count().unitDivided(by: HKUnit.minute())
        case HKQuantityTypeIdentifier.heartRateRecoveryOneMinute.rawValue:
            return HKUnit.count().unitDivided(by: HKUnit.minute())
            
        // Respiratory
        case HKQuantityTypeIdentifier.respiratoryRate.rawValue:
            return HKUnit.count().unitDivided(by: HKUnit.minute())
        case HKQuantityTypeIdentifier.oxygenSaturation.rawValue:
            return HKUnit.percent()
        case HKQuantityTypeIdentifier.forcedExpiratoryVolume1.rawValue,
             HKQuantityTypeIdentifier.forcedVitalCapacity.rawValue:
            return HKUnit.liter()
        case HKQuantityTypeIdentifier.peakExpiratoryFlowRate.rawValue:
            return HKUnit.liter().unitDivided(by: HKUnit.minute())
            
        // Energy
        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
             HKQuantityTypeIdentifier.basalEnergyBurned.rawValue,
             HKQuantityTypeIdentifier.dietaryEnergyConsumed.rawValue:
            return HKUnit.kilocalorie()
            
        // Distance
        case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
             HKQuantityTypeIdentifier.distanceCycling.rawValue,
             HKQuantityTypeIdentifier.distanceSwimming.rawValue,
             HKQuantityTypeIdentifier.sixMinuteWalkTestDistance.rawValue:
            return HKUnit.meter()
            
        // Counts
        case HKQuantityTypeIdentifier.stepCount.rawValue,
             HKQuantityTypeIdentifier.flightsClimbed.rawValue,
             HKQuantityTypeIdentifier.swimmingStrokeCount.rawValue,
             HKQuantityTypeIdentifier.numberOfTimesFallen.rawValue,
             HKQuantityTypeIdentifier.nikeFuel.rawValue:
            return HKUnit.count()
            
        // Time (minutes)
        case HKQuantityTypeIdentifier.appleExerciseTime.rawValue,
             HKQuantityTypeIdentifier.appleMoveTime.rawValue,
             HKQuantityTypeIdentifier.appleStandTime.rawValue:
            return HKUnit.minute()
            
        // Body
        case HKQuantityTypeIdentifier.bodyMass.rawValue,
             HKQuantityTypeIdentifier.leanBodyMass.rawValue:
            return HKUnit.gramUnit(with: .kilo)
        case HKQuantityTypeIdentifier.height.rawValue,
             HKQuantityTypeIdentifier.waistCircumference.rawValue:
            return HKUnit.meterUnit(with: .centi)
        case HKQuantityTypeIdentifier.bodyMassIndex.rawValue:
            return HKUnit.count()
        case HKQuantityTypeIdentifier.bodyFatPercentage.rawValue:
            return HKUnit.percent()
            
        // Vitals
        case HKQuantityTypeIdentifier.bodyTemperature.rawValue,
             "HKQuantityTypeIdentifierAppleSleepingWristTemperature":
            return HKUnit.degreeCelsius()
        case HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue,
             HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue:
            return HKUnit.millimeterOfMercury()
        case HKQuantityTypeIdentifier.bloodGlucose.rawValue:
            return HKUnit.gramUnit(with: .milli).unitDivided(by: HKUnit.literUnit(with: .deci))
            
        // Nutrition
        case HKQuantityTypeIdentifier.dietaryProtein.rawValue,
             HKQuantityTypeIdentifier.dietaryCarbohydrates.rawValue,
             HKQuantityTypeIdentifier.dietaryFatTotal.rawValue,
             HKQuantityTypeIdentifier.dietaryCaffeine.rawValue:
            return HKUnit.gram()
        case HKQuantityTypeIdentifier.dietaryWater.rawValue:
            return HKUnit.literUnit(with: .milli)
            
        // Audio
        case HKQuantityTypeIdentifier.environmentalAudioExposure.rawValue,
             HKQuantityTypeIdentifier.headphoneAudioExposure.rawValue:
            return HKUnit.decibelAWeightedSoundPressureLevel()
            
        // Mobility
        case HKQuantityTypeIdentifier.walkingSpeed.rawValue:
            return HKUnit.meter().unitDivided(by: HKUnit.second())
        case HKQuantityTypeIdentifier.walkingStepLength.rawValue:
            return HKUnit.meterUnit(with: .centi)
        case HKQuantityTypeIdentifier.walkingAsymmetryPercentage.rawValue,
             HKQuantityTypeIdentifier.walkingDoubleSupportPercentage.rawValue,
             HKQuantityTypeIdentifier.atrialFibrillationBurden.rawValue:
            return HKUnit.percent()
        case HKQuantityTypeIdentifier.stairAscentSpeed.rawValue,
             HKQuantityTypeIdentifier.stairDescentSpeed.rawValue:
            return HKUnit.meter().unitDivided(by: HKUnit.second())
            
        // VO2Max
        case "HKQuantityTypeIdentifierVO2Max":
            return HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: HKUnit.minute()))
            
        // UV
        case HKQuantityTypeIdentifier.uvExposure.rawValue:
            return HKUnit.count()
        case HKQuantityTypeIdentifier.electrodermalActivity.rawValue:
            return HKUnit.siemen()
        case HKQuantityTypeIdentifier.peripheralPerfusionIndex.rawValue:
            return HKUnit.percent()
            
        default:
            return HKUnit.count()
        }
    }
}
#endif
