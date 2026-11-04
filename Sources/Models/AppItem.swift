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

// MARK: - Suspend Strategy

/// How BatKill preserves a running app's state when switching to battery,
/// and how it restores it when AC power returns.
///
/// - `suspend`: Send `SIGSTOP` to freeze the app in place; on AC, `SIGCONT`
///   resumes it exactly where it paused. Preserves all internal state
///   (unsaved edits, playback position) but keeps the process in memory.
/// - `graceful`: Gracefully quit (`terminate()`) with an extended wait so the
///   app can persist its own state (autosave / resume); on AC, relaunch and
///   let the app restore what it saved. Frees all memory. Default.
/// - `force`: Existing escalation chain (`terminate` -> `forceTerminate` ->
///   SIGTERM -> SIGKILL -> killall). Most battery-efficient, loses state. Fallback.
enum SuspendStrategy: String, Codable, CaseIterable {
    case suspend
    case graceful
    case force
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

    /// How BatKill preserves/restores this app's state on battery/AC transitions.
    /// Persisted per-app via `appSuspendStrategies` in UserDefaults (hydrated by AppLister).
    /// Defaults to `.graceful` (graceful quit + app-driven state save).
    var suspendStrategy: SuspendStrategy = .graceful

    /// Whether this app is currently frozen by a `SIGSTOP` (suspend mode) and
    /// awaits a `SIGCONT` resume on AC. Transient -- hydrated from `suspendedPaths`.
    /// NOT persisted to UserDefaults (excluded from CodingKeys).
    var isSuspended: Bool = false

    // MARK: CodingKeys

    enum CodingKeys: String, CodingKey {
        case name, bundleIdentifier, path, processName, isSelected, isSystemApp, category, serviceLabel, suspendStrategy
        // isRunning, pid and isSuspended are transient -- re-evaluated on each refresh, not persisted
    }
}

// MARK: - AppItem Decodable (Backward Compatible)

/// Custom decoding so `suspendStrategy` (added in v0.2.4) tolerates older
/// persisted data that predates the key, falling back to `.graceful` (default).
/// Defined in an extension to preserve the memberwise initializer.
extension AppItem {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        path = try container.decode(String.self, forKey: .path)
        processName = try container.decode(String.self, forKey: .processName)
        isSelected = try container.decodeIfPresent(Bool.self, forKey: .isSelected) ?? false
        isSystemApp = try container.decodeIfPresent(Bool.self, forKey: .isSystemApp) ?? false
        category = try container.decodeIfPresent(AppCategory.self, forKey: .category) ?? .application
        serviceLabel = try container.decodeIfPresent(String.self, forKey: .serviceLabel)
        suspendStrategy = try container.decodeIfPresent(SuspendStrategy.self, forKey: .suspendStrategy) ?? .graceful
        // isRunning, pid, isSuspended are transient -- left at their defaults
    }
}

// MARK: - Suspend Strategy Capability (v0.2.4 CHANGE-061)

/// Capability-aware suspend-strategy selection. BatKill picks a per-app default
/// from an ordered preference sequence (`suspend` -> `graceful` -> `force`),
/// taking the first mode the app actually supports. The user's manual choice is
/// stored as a temporary override (see `AppLister`); these helpers decide the
/// auto default and repair any stored mode the app no longer supports.
extension AppItem {
    /// Whether this app participates in the suspend-strategy sequence.
    /// `.application` and `.custom` can be configured; `.launchAgent`/`.service`
    /// keep their existing kill/restore strategy (not strategy-based).
    var participatesInSuspendSequence: Bool {
        category == .application || category == .custom
    }

    /// Whether this app technically supports the given suspend strategy.
    ///
    /// - `suspend` needs a signalable process (`SIGSTOP`/`SIGCONT`) -- any
    ///   process works, no launch mechanism required.
    /// - `graceful`/`force` exit the process and must relaunch it on AC, which
    ///   requires an independent launch mechanism (`.app` bundles). `.custom`
    ///   (e.g. XPC helpers) has none, so only `suspend` can restore it.
    func supports(_ strategy: SuspendStrategy) -> Bool {
        guard participatesInSuspendSequence else { return false }
        switch category {
        case .application:
            return true // .app has a launch mechanism + a signalable PID
        case .custom:
            return strategy == .suspend // no launch mechanism; suspend-only
        default:
            return false
        }
    }

    /// The auto-default strategy: first supported mode in the sequence
    /// `suspend` -> `graceful` -> `force` (prefer resumable suspend).
    var autoSuspendStrategy: SuspendStrategy {
        if supports(.suspend) { return .suspend }
        if supports(.graceful) { return .graceful }
        return .force
    }

    /// Whether the temporary per-app strategy config has expired (default ~30
    /// days since last manual update), so BatKill re-evaluates auto defaults to
    /// follow an app's changed capabilities after a software update.
    static func isSuspendStrategyConfigExpired(lastSetAt: Date, now: Date, interval: TimeInterval) -> Bool {
        now.timeIntervalSince(lastSetAt) > interval
    }

    /// Repairs a stored strategy map: any entry whose mode is no longer
    /// supported by its app is downgraded (per sequence) to the first supported
    /// mode, so erroneous config stops taking effect. Only apps participating
    /// in the sequence are touched.
    static func repairedStrategies(_ strategies: [String: String], for apps: [AppItem]) -> [String: String] {
        var result = strategies
        for app in apps where app.participatesInSuspendSequence {
            guard let raw = strategies[app.path],
                  let stored = SuspendStrategy(rawValue: raw),
                  !app.supports(stored) else { continue }
            result[app.path] = app.autoSuspendStrategy.rawValue
        }
        return result
    }
}
