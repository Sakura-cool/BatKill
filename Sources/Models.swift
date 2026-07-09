import Foundation

// MARK: - App Category
enum AppCategory: String, Codable, CaseIterable {
    case application = "Application"
    case service = "Service"
    case launchAgent = "Launch Agent"
    case custom = "Custom"
}

// MARK: - App Item
struct AppItem: Identifiable, Codable, Equatable {
    var id: String { path }
    var name: String
    var bundleIdentifier: String?
    var path: String
    var processName: String
    var isRunning: Bool = false
    var isSelected: Bool = false
    var isSystemApp: Bool = false
    var category: AppCategory = .application
    var pid: Int32?

    enum CodingKeys: String, CodingKey {
        case name, bundleIdentifier, path, processName, isSelected, isSystemApp, category
        // isRunning and pid are transient — re-evaluated on each refresh
    }
}

// MARK: - Persisted Preferences
struct SavedState: Codable {
    var selectedPaths: [String]
    var autoKillEnabled: Bool
}
