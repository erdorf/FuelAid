//
//  SubscriptionStore.swift
//  FuelAid
//
//  Created by ERIC DIEVENDORF on 5/17/26.
//

import Foundation
import Observation
import StoreKit

@MainActor
@Observable
final class SubscriptionStore {
    static let monthlyProductID = "com.dorfnet.FuelAid.pro.monthly"
    static let yearlyProductID = "com.dorfnet.FuelAid.pro.yearly"
    static let productIDs = [monthlyProductID, yearlyProductID]

    private(set) var hasProAccess = false
    private(set) var products: [Product] = []
    private(set) var entitlementCheckCompleted = false

    var vehicleLimit: Int? {
        hasProAccess ? nil : 2
    }

    var planName: String {
        hasProAccess ? "Paid subscription" : "Free version"
    }

    func canAddVehicle(currentCount: Int) -> Bool {
        guard let vehicleLimit else { return true }
        return currentCount < vehicleLimit
    }

    func start() async {
        await loadProducts()
        await refreshEntitlements()
        observeTransactionUpdates()
    }

    func refreshEntitlements() async {
        var hasActiveSubscription = false

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else {
                continue
            }

            if Self.productIDs.contains(transaction.productID), transaction.revocationDate == nil {
                if let expirationDate = transaction.expirationDate, expirationDate < Date() {
                    continue
                }

                hasActiveSubscription = true
            }
        }

        hasProAccess = hasActiveSubscription
        entitlementCheckCompleted = true
    }

    private func loadProducts() async {
        do {
            products = try await Product.products(for: Self.productIDs).sorted { $0.displayName < $1.displayName }
        } catch {
            products = []
        }
    }

    private func observeTransactionUpdates() {
        Task(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result else {
                    continue
                }

                await transaction.finish()
                await self?.refreshEntitlements()
            }
        }
    }
}

enum PremiumFeature: String, CaseIterable, Identifiable {
    case unlimitedVehicles = "Unlimited vehicles"
    case advancedReporting = "Advanced reporting"
    case csvImportExport = "CSV export/import"
    case maintenanceReminders = "Maintenance reminders"
    case trailerTracking = "Trailer tracking"
    case carPlay = "CarPlay features"
    case businessMileageReporting = "Business mileage reporting"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .unlimitedVehicles:
            return "car.2.fill"
        case .advancedReporting:
            return "chart.bar.xaxis"
        case .csvImportExport:
            return "square.and.arrow.up.on.square"
        case .maintenanceReminders:
            return "wrench.and.screwdriver"
        case .trailerTracking:
            return "box.truck"
        case .carPlay:
            return "car.front.waves.up"
        case .businessMileageReporting:
            return "briefcase"
        }
    }
}
