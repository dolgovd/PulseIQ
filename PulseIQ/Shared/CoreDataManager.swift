import CoreData
import Foundation

public class CoreDataManager: Sendable {
    nonisolated public static let shared = CoreDataManager()
    public let container: NSPersistentContainer

    private init() {
        // Create NSManagedObjectModel programmatically to avoid needing .xcdatamodeld file
        let model = NSManagedObjectModel()
        
        // 1. Define HealthSample Entity
        let healthSampleEntity = NSEntityDescription()
        healthSampleEntity.name = "HealthSample"
        healthSampleEntity.managedObjectClassName = "HealthSample"
        
        let idAttr = NSAttributeDescription()
        idAttr.name = "id"
        idAttr.attributeType = .UUIDAttributeType
        idAttr.isOptional = false
        
        let typeAttr = NSAttributeDescription()
        typeAttr.name = "type"
        typeAttr.attributeType = .stringAttributeType
        typeAttr.isOptional = false
        
        let valueAttr = NSAttributeDescription()
        valueAttr.name = "value"
        valueAttr.attributeType = .doubleAttributeType
        valueAttr.isOptional = false
        
        let startAttr = NSAttributeDescription()
        startAttr.name = "startDate"
        startAttr.attributeType = .dateAttributeType
        startAttr.isOptional = false
        
        let endAttr = NSAttributeDescription()
        endAttr.name = "endDate"
        endAttr.attributeType = .dateAttributeType
        endAttr.isOptional = false
        
        healthSampleEntity.properties = [idAttr, typeAttr, valueAttr, startAttr, endAttr]
        
        // 2. Define DailySummary Entity
        let dailySummaryEntity = NSEntityDescription()
        dailySummaryEntity.name = "DailySummary"
        dailySummaryEntity.managedObjectClassName = "DailySummary"
        
        let dateAttr = NSAttributeDescription()
        dateAttr.name = "date"
        dateAttr.attributeType = .dateAttributeType
        dateAttr.isOptional = false
        
        let recoveryAttr = NSAttributeDescription()
        recoveryAttr.name = "recoveryScore"
        recoveryAttr.attributeType = .doubleAttributeType
        recoveryAttr.isOptional = false
        
        let sleepAttr = NSAttributeDescription()
        sleepAttr.name = "sleepDuration"
        sleepAttr.attributeType = .doubleAttributeType
        sleepAttr.isOptional = false
        
        let exertionAttr = NSAttributeDescription()
        exertionAttr.name = "exertionScore"
        exertionAttr.attributeType = .doubleAttributeType
        exertionAttr.isOptional = false
        
        dailySummaryEntity.properties = [dateAttr, recoveryAttr, sleepAttr, exertionAttr]
        
        // Add entities to model
        model.entities = [healthSampleEntity, dailySummaryEntity]
        
        // Initialize Container
        container = NSPersistentContainer(name: "PulseIQDataModel", managedObjectModel: model)
        
        container.loadPersistentStores { description, error in
            if let error = error {
                print("Core Data failed to load: \(error.localizedDescription)")
            }
        }
        
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }
}

// MARK: - Core Data Models

@objc(HealthSample)
public class HealthSample: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var type: String
    @NSManaged public var value: Double
    @NSManaged public var startDate: Date
    @NSManaged public var endDate: Date
}

@objc(DailySummary)
public class DailySummary: NSManagedObject {
    @NSManaged public var date: Date
    @NSManaged public var recoveryScore: Double
    @NSManaged public var sleepDuration: Double
    @NSManaged public var exertionScore: Double
}
