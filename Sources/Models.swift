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

struct FanPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var fanSpeeds: [Int: Double]
    var fanAutoModes: [Int: Bool]

    static func == (lhs: FanPreset, rhs: FanPreset) -> Bool {
        lhs.id == rhs.id
    }
}

final class FanPresetStore: ObservableObject {
    @Published var presets: [FanPreset] = []
    @Published var activePresetID: UUID?

    private let presetsKey = "fanPresets"
    private let activeKey = "activeFanPresetID"

    init() {
        load()
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: presetsKey),
              let decoded = try? JSONDecoder().decode([FanPreset].self, from: data) else { return }
        presets = decoded
        activePresetID = UserDefaults.standard.string(forKey: activeKey).flatMap { UUID(uuidString: $0) }
    }

    func save() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: presetsKey)
        }
        if let id = activePresetID {
            UserDefaults.standard.set(id.uuidString, forKey: activeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: activeKey)
        }
    }

    func add(_ preset: FanPreset) {
        presets.append(preset)
        save()
    }

    func remove(_ preset: FanPreset) {
        presets.removeAll { $0.id == preset.id }
        if activePresetID == preset.id { activePresetID = nil }
        save()
    }

    func update(_ preset: FanPreset) {
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx] = preset
            save()
        }
    }

    func activate(_ preset: FanPreset) {
        activePresetID = preset.id
        save()
    }

    var activePreset: FanPreset? {
        presets.first { $0.id == activePresetID }
    }
}
