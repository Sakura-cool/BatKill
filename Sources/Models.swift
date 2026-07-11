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
    var serviceLabel: String?  // launchd label for services (e.g., "homebrew.mxcl.colima")

    enum CodingKeys: String, CodingKey {
        case name, bundleIdentifier, path, processName, isSelected, isSystemApp, category, serviceLabel
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

    static let autoModeID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    static func == (lhs: FanPreset, rhs: FanPreset) -> Bool {
        lhs.id == rhs.id
    }

    var isBuiltIn: Bool { id == Self.autoModeID }
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
              let decoded = try? JSONDecoder().decode([FanPreset].self, from: data) else {
            ensureAutoPreset(fanCount: 2)
            return
        }
        presets = decoded
        activePresetID = UserDefaults.standard.string(forKey: activeKey).flatMap { UUID(uuidString: $0) }
        ensureAutoPreset(fanCount: 2)
    }

    func ensureAutoPreset(fanCount: Int) {
        if !presets.contains(where: { $0.isBuiltIn }) {
            var speeds: [Int: Double] = [:]
            var modes: [Int: Bool] = [:]
            for i in 0..<fanCount {
                speeds[i] = 0
                modes[i] = true
            }
            let auto = FanPreset(id: FanPreset.autoModeID, name: "Auto", fanSpeeds: speeds, fanAutoModes: modes)
            presets.insert(auto, at: 0)
            save()
        } else if let idx = presets.firstIndex(where: { $0.isBuiltIn }) {
            var modes = presets[idx].fanAutoModes
            if modes.count != fanCount {
                for i in 0..<fanCount {
                    modes[i] = true
                }
                presets[idx].fanAutoModes = modes
                save()
            }
        }
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
        guard !preset.isBuiltIn else { return }
        presets.removeAll { $0.id == preset.id }
        if activePresetID == preset.id { activePresetID = nil }
        save()
    }

    func update(_ preset: FanPreset) {
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx].fanSpeeds = preset.fanSpeeds
            presets[idx].fanAutoModes = preset.fanAutoModes
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

    var autoModePreset: FanPreset? {
        presets.first { $0.isBuiltIn }
    }
}

// MARK: - Temperature Threshold Store
final class TemperatureThresholdStore: ObservableObject {
    @Published var threshold: Double {
        didSet { UserDefaults.standard.set(threshold, forKey: key) }
    }

    private let key = "fanTemperatureThreshold"
    private let defaultValue: Double = 98

    init() {
        let stored = UserDefaults.standard.double(forKey: key)
        self.threshold = stored > 0 ? stored : 98
    }
}
