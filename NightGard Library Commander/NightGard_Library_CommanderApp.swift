//
//  NightGard_Library_CommanderApp.swift
//  NightGard Library Commander
//

import SwiftUI

@main
struct NightGard_Library_CommanderApp: App {
    @State private var libraryService = LibraryService()
    @State private var lockerService = PlaylistLockerService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(libraryService)
                .environment(lockerService)
                .task {
                    await libraryService.authorize()
                    lockerService.scanLocker()
                    await libraryService.refreshStats()
                }
        }
        #if os(macOS)
        .defaultSize(width: 900, height: 720)
        #endif
    }
}
