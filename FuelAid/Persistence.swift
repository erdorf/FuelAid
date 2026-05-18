//
//  Persistence.swift
//  FuelAid
//
//  Created by ERIC DIEVENDORF on 5/17/26.
//

import CloudKit
import CoreData

final class PersistenceController {
    static let shared = PersistenceController()

    static let cloudKitContainerIdentifier = "iCloud.com.dorfnet.FuelAid"

    @MainActor
    static let preview: PersistenceController = {
        let result = PersistenceController(inMemory: true)
        let viewContext = result.container.viewContext

        let vehicle = Vehicle(context: viewContext)
        vehicle.id = UUID()
        vehicle.createdAt = Date()
        vehicle.name = "Daily Driver"
        vehicle.make = "Toyota"
        vehicle.model = "RAV4"
        vehicle.year = 2024
        vehicle.licensePlate = "FUELAID"
        vehicle.recommendedTirePressure = 35
        vehicle.isDefault = true

        let firstFillUp = FillUp(context: viewContext)
        firstFillUp.id = UUID()
        firstFillUp.date = Calendar.current.date(byAdding: .day, value: -14, to: Date())
        firstFillUp.odometer = 10_240
        firstFillUp.gallons = 12.2
        firstFillUp.pricePerGallon = 3.19
        firstFillUp.totalCost = 38.92
        firstFillUp.location = "Northside Fuel"
        firstFillUp.vehicle = vehicle

        let secondFillUp = FillUp(context: viewContext)
        secondFillUp.id = UUID()
        secondFillUp.date = Date()
        secondFillUp.odometer = 10_602
        secondFillUp.gallons = 11.8
        secondFillUp.pricePerGallon = 3.09
        secondFillUp.totalCost = 36.46
        secondFillUp.location = "Highway Stop"
        secondFillUp.vehicle = vehicle

        let trip = Trip(context: viewContext)
        trip.id = UUID()
        trip.name = "Client Visit"
        trip.tripType = TripType.business.rawValue
        trip.startDate = Calendar.current.date(byAdding: .day, value: -2, to: Date())
        trip.endDate = Calendar.current.date(byAdding: .hour, value: 2, to: trip.startDate ?? Date())
        trip.startLocation = "Office"
        trip.endLocation = "Warehouse"
        trip.route = "I-35"
        trip.distance = 86
        trip.averageSpeed = 54
        trip.vehicle = vehicle

        let preferences = AppPreference(context: viewContext)
        preferences.id = UUID()
        preferences.createdAt = Date()
        preferences.autoLogFillUpLocations = true

        do {
            try viewContext.save()
        } catch {
            let nsError = error as NSError
            fatalError("Unresolved preview error \(nsError), \(nsError.userInfo)")
        }

        return result
    }()

    let container: NSPersistentCloudKitContainer
    private(set) var privatePersistentStore: NSPersistentStore?
    private(set) var sharedPersistentStore: NSPersistentStore?

    init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "FuelAid")

        if inMemory {
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            description.shouldAddStoreAsynchronously = false
            container.persistentStoreDescriptions = [description]
        } else {
            configureCloudKitStores()
        }

        container.loadPersistentStores { storeDescription, error in
            if let error = error as NSError? {
                fatalError("Unresolved persistent store error \(error), \(error.userInfo)")
            }

            if storeDescription.configuration == "Shared" {
                self.sharedPersistentStore = self.container.persistentStoreCoordinator.persistentStore(for: storeDescription.url!)
            } else {
                self.privatePersistentStore = self.container.persistentStoreCoordinator.persistentStore(for: storeDescription.url!)
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    func acceptShareInvitations(from metadata: CKShare.Metadata) {
        guard let sharedPersistentStore else {
            return
        }

        container.acceptShareInvitations(from: [metadata], into: sharedPersistentStore) { _, error in
            if let error {
                assertionFailure("Unable to accept CloudKit share: \(error.localizedDescription)")
            }
        }
    }

    private func configureCloudKitStores() {
        guard let privateStoreDescription = container.persistentStoreDescriptions.first else {
            return
        }

        let privateURL = privateStoreDescription.url
        let sharedURL = privateURL?.deletingLastPathComponent().appendingPathComponent("Shared.sqlite")

        privateStoreDescription.configuration = "Private"
        privateStoreDescription.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.cloudKitContainerIdentifier)
        privateStoreDescription.cloudKitContainerOptions?.databaseScope = .private
        privateStoreDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        privateStoreDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        let sharedStoreDescription = privateStoreDescription.copy() as! NSPersistentStoreDescription
        sharedStoreDescription.url = sharedURL
        sharedStoreDescription.configuration = "Shared"
        sharedStoreDescription.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.cloudKitContainerIdentifier)
        sharedStoreDescription.cloudKitContainerOptions?.databaseScope = .shared
        sharedStoreDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        sharedStoreDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        container.persistentStoreDescriptions = [privateStoreDescription, sharedStoreDescription]
    }
}
