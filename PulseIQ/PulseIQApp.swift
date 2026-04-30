//
//  PulseIQApp.swift
//  PulseIQ
//
//  Created by dima on 24-04-2026.
//

import SwiftUI
import CoreData

@main
struct PulseIQApp: App {
    let coreDataManager = CoreDataManager.shared
    let syncManager = SyncManager.shared // Initializes Multipeer Connectivity immediately

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, coreDataManager.container.viewContext)
                .environmentObject(syncManager)
        }
    }
}
