//
//  FuelAidApp.swift
//  FuelAid
//
//  Created by ERIC DIEVENDORF on 5/17/26.
//

import SwiftUI
import CoreData

@main
struct FuelAidApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
