//
//  FuelAidApp.swift
//  FuelAid
//
//  Created by ERIC DIEVENDORF on 5/17/26.
//

import CoreData
import SwiftUI

@main
struct FuelAidApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    let persistenceController = PersistenceController.shared
    @State private var subscriptionStore = SubscriptionStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environment(subscriptionStore)
                .task {
                    await subscriptionStore.start()
                }
        }
    }
}
