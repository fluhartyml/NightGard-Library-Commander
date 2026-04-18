//
//  NightGard_Library_CommanderApp.swift
//  NightGard Library Commander
//
//  Created by Michael Fluharty on 4/18/26.
//

import SwiftUI
import SwiftData

@main
struct NightGard_Library_CommanderApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
