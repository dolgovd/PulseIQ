#if os(iOS)
import Foundation
import HealthKit
import CoreData
import Combine

public class HealthKitManager: ObservableObject {
    public static let shared = HealthKitManager()
    let healthStore = HKHealthStore()
    
    @Published public var isAuthorized = false
    
    private init() {}
    
    public func requestAuthorization(completion: @escaping (Bool) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(false)
            return
        }
        
        // Define all the types we want to read
        var typesToRead: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
            HKObjectType.quantityType(forIdentifier: .restingHeartRate)!,
            HKObjectType.quantityType(forIdentifier: .respiratoryRate)!,
            HKObjectType.quantityType(forIdentifier: .oxygenSaturation)!,
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKObjectType.quantityType(forIdentifier: .basalEnergyBurned)!,
            HKObjectType.quantityType(forIdentifier: .heartRate)!,
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        ]
        
        if #available(iOS 16.0, *) {
            if let wristTemp = HKObjectType.quantityType(forIdentifier: .appleSleepingWristTemperature) {
                typesToRead.insert(wristTemp)
            }
        }
        
        healthStore.requestAuthorization(toShare: nil, read: typesToRead) { success, error in
            DispatchQueue.main.async {
                self.isAuthorized = success
                completion(success)
            }
        }
    }
    
    // Setup observer query for background syncing
    public func startObserving() {
        guard isAuthorized else { return }
        
        let typesToObserve: [HKQuantityTypeIdentifier] = [
            .heartRateVariabilitySDNN,
            .restingHeartRate,
            .activeEnergyBurned,
            .respiratoryRate,
            .oxygenSaturation
        ]
        
        for identifier in typesToObserve {
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
        let typesToObserve: [HKQuantityTypeIdentifier] = [
            .heartRateVariabilitySDNN,
            .restingHeartRate,
            .activeEnergyBurned,
            .respiratoryRate,
            .oxygenSaturation
        ]
        for identifier in typesToObserve {
            if let sampleType = HKObjectType.quantityType(forIdentifier: identifier) {
                fetchLatestData(for: sampleType) {}
            }
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
                for sample in quantitySamples {
                    let healthSample = HealthSample(context: context)
                    healthSample.id = sample.uuid
                    healthSample.type = sample.sampleType.identifier
                    healthSample.value = sample.quantity.doubleValue(for: self.unit(for: type))
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
        case HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue: return HKUnit.secondUnit(with: .milli)
        case HKQuantityTypeIdentifier.restingHeartRate.rawValue, HKQuantityTypeIdentifier.heartRate.rawValue: return HKUnit.count().unitDivided(by: HKUnit.minute())
        case HKQuantityTypeIdentifier.respiratoryRate.rawValue: return HKUnit.count().unitDivided(by: HKUnit.minute())
        case HKQuantityTypeIdentifier.oxygenSaturation.rawValue: return HKUnit.percent()
        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue, HKQuantityTypeIdentifier.basalEnergyBurned.rawValue: return HKUnit.kilocalorie()
        default: return HKUnit.count()
        }
    }
}
#endif
