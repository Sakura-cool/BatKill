//  AppItem.swift
//  BatKill
//
//  Core data models representing user-manageable applications.
//  Contains:
//    - AppCategory: Classification enum for discovered software (app, service, launch agent, custom).
//    - AppItem: The primary model for each application tracked by BatKill, including
//      selection state, running status, and metadata used for kill/restore operations.
//
//  AppItem conforms to Codable for persisting the user's selection list across launches.
//  The `isRunning` and `pid` fields are transient (not encoded) and re-evaluated on each refresh.
//
//  Extracted from: Models.swift

import Foundation

// MARK: - App Category

/// Classification of discovered software by how it was found and how it behaves.
///
/// - `application`: A standard `.app` bundle found in /Applications, ~/Applications, or LaunchServices.
/// - `service`: A background service (e.g., Homebrew-managed daemon discovered via `launchctl`).
/// - `launchAgent`: A per-user or system-wide LaunchAgent plist discovered via `launchctl list`.
/// - `custom`: A manually added path that doesn't fit the other categories.
enum AppCategory: String, Codable, CaseIterable {
    case application = "Application"
    case service = "Service"
    case launchAgent = "Launch Agent"
    case custom = "Custom"
}

// MARK: - App Item

/// Represents a single application that BatKill can track, kill, and restore.
///
/// Each `AppItem` is either discovered automatically by `AppLister` (scan of /Applications,
/// LaunchServices, launchctl) or manually added by the user. The `isSelected` flag determines
/// whether BatKill will terminate this app when switching to battery power.
///
/// ### Persistence
/// Only the fields listed in `CodingKeys` are saved to `UserDefaults` via `selectedPaths`.
/// Transient fields (`isRunning`, `pid`) are re-evaluated every time `refreshAppList()` runs.
struct AppItem: Identifiable, Codable, Equatable {
    /// Unique identifier derived from the app's filesystem path.
    /// Using `path` as the ID ensures no two items point to the same location.
    var id: String { path }

    /// Display name of the application (e.g., "Google Chrome", "colima").
    var name: String

    /// CFBundleIdentifier if available (e.g., "com.google.Chrome").
    /// `nil` for services and launch agents that lack an Info.plist.
    var bundleIdentifier: String?

    /// Absolute filesystem path to the `.app` bundle or executable.
    /// Used by ProcessKiller to launch/terminate the process.
    var path: String

    /// Process name as reported by the system (used for `NSRunningApplication` matching).
    var processName: String

    /// Whether the app is currently running. Transient -- re-evaluated on each `refreshAppList()` call.
    /// NOT persisted to UserDefaults (excluded from CodingKeys).
    var isRunning: Bool = false

    /// Whether the user has checked this app for auto-kill on battery.
    /// Persisted via `selectedPaths` in UserDefaults.
    var isSelected: Bool = false

    /// Whether this app was discovered from system directories or is a known system component.
    /// System apps are hidden by default in the UI but can be revealed with a filter toggle.
    var isSystemApp: Bool = false

    /// The category of this item (standard app, background service, launch agent, or custom).
    var category: AppCategory = .application

    /// Process ID if the app is currently running. Transient -- re-evaluated on each refresh.
    /// NOT persisted to UserDefaults (excluded from CodingKeys).
    var pid: Int32?

    /// The launchd service label for background services (e.g., "homebrew.mxcl.colima").
    /// Used to start/stop services via `launchctl`.
    var serviceLabel: String?

    // MARK: CodingKeys

    enum CodingKeys: String, CodingKey {
        case name, bundleIdentifier, path, processName, isSelected, isSystemApp, category, serviceLabel
        // isRunning and pid are transient -- re-evaluated on each refresh, not persisted
    }
}
