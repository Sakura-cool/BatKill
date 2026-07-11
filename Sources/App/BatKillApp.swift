//  BatKillApp.swift
//  BatKill
//
//  SwiftUI application entry point. Declares the @main struct that launches
//  the app and wires up the single WindowGroup used for the Settings panel.
//  All heavy lifting (power monitoring, process management, menu bar hosting)
//  is delegated to AppDelegate via @NSApplicationDelegateAdaptor.
//
//  Architecture role:
//    @main -> BatKillApp (this file)
//         -> AppDelegate (App/AppDelegate.swift)
//         -> ContentView / SettingsView (Views/SettingsView.swift)

import SwiftUI
import ServiceManagement
import Combine

// MARK: - App Entry Point

/// BatKill -- macOS menu bar utility that terminates selected apps on battery
/// power and restores them when AC power returns. Includes hardware temperature
/// monitoring and fan control.
///
/// The `@main` attribute tells the Swift compiler this is the application entry
/// point. The single `WindowGroup` hosts the settings panel (SettingsView),
/// injected with all seven environment objects that the view tree depends on.
@main
struct BatKillApp: App {
    /// The shared AppDelegate that owns every subsystem. Environment objects
    /// are projected from its properties into the SwiftUI view tree.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup(id: "settings") {
            SettingsView()
                .environmentObject(appDelegate.batteryMonitor)
                .environmentObject(appDelegate.appLister)
                .environmentObject(appDelegate.processKiller)
                .environmentObject(appDelegate.localizationManager)
                .environmentObject(appDelegate.versionChecker)
                .environmentObject(appDelegate.updater)
                .environmentObject(appDelegate.hardwareMonitor)
        }
        .windowResizability(.contentSize)
        // Suppress the default "New Window" menu item -- we manage windows manually
        .commands { CommandGroup(replacing: .newItem) { } }
    }
}
