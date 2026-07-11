//  FanPreset.swift
//  BatKill
//
//  Fan preset configuration models for the hardware monitor's fan control feature.
//  Contains:
//    - SavedState: Lightweight snapshot of user preferences for serialization.
//    - FanPreset: A named configuration of fan speeds and auto/manual modes.
//    - FanPresetStore: Observable store that manages presets via UserDefaults persistence.
//
//  Fan presets allow users to save, load, and switch between different fan configurations
//  (e.g., "Silent", "Performance", "Auto") with a single click from the temperature window.
//
//  Extracted from: Models.swift

import Foundation
import Combine

// MARK: - Saved State

/// Lightweight snapshot of the user's core preferences, used for serialization.
///
/// Captures which apps are selected for auto-kill and whether the auto-kill feature
/// is enabled. This is used for state persistence or potential export/import scenarios.
struct SavedState: Codable {
    /// List of filesystem paths for apps the user has selected for auto-kill.
    var selectedPaths: [String]

    /// Whether auto-kill on battery is currently enabled.
    var autoKillEnabled: Bool
}

// MARK: - Fan Preset

/// A named fan configuration that stores per-fan speed targets and auto/manual mode settings.
///
/// Each preset maps fan indices (0, 1, ...) to target speeds (in RPM) and mode flags.
/// A speed of `0` with auto mode `true` means "let the system manage this fan."
///
/// ### Built-in Preset
/// A special "Auto" preset (identified by `autoModeID`) is always present at index 0.
/// It sets all fans to auto mode and cannot be deleted by the user.
struct FanPreset: Codable, Identifiable, Equatable {
    /// Unique identifier for this preset.
    var id = UUID()

    /// User-facing name (e.g., "Auto", "Silent", "Max Performance").
    var name: String

    /// Target fan speeds keyed by fan index (0-based).
    /// A value of `0` combined with `fanAutoModes[i] == true` means the system controls the fan.
    var fanSpeeds: [Int: Double]

    /// Per-fan mode flags keyed by fan index.
    /// `true` = automatic (system-managed), `false` = manual (user-controlled speed).
    var fanAutoModes: [Int: Bool]

    // MARK: - Built-in Preset

    /// Well-known UUID for the built-in "Auto" preset.
    /// This preset cannot be deleted or renamed; it represents system-default fan behavior.
    static let autoModeID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// Equality is based solely on `id` — two presets with the same ID are considered equal
    /// regardless of their current speed/mode values.
    static func == (lhs: FanPreset, rhs: FanPreset) -> Bool {
        lhs.id == rhs.id
    }

    /// Whether this is the built-in "Auto" preset that cannot be deleted.
    var isBuiltIn: Bool { id == Self.autoModeID }
}

// MARK: - Fan Preset Store

/// Observable store that manages the collection of fan presets with UserDefaults persistence.
///
/// Handles CRUD operations on presets, ensures the built-in "Auto" preset always exists,
/// and tracks which preset is currently active. The store is shared as an `@EnvironmentObject`
/// across SwiftUI views that display or modify fan configurations.
///
/// ### UserDefaults Keys
/// - `fanPresets`: JSON-encoded `[FanPreset]` array.
/// - `activeFanPresetID`: UUID string of the currently active preset (or absent if none).
final class FanPresetStore: ObservableObject {
    /// The full list of user-defined and built-in presets.
    /// Always starts with the built-in "Auto" preset at index 0.
    @Published var presets: [FanPreset] = []

    /// The UUID of the currently active (applied) preset, or `nil` if no preset is active.
    @Published var activePresetID: UUID?

    /// UserDefaults key for the JSON-encoded presets array.
    private let presetsKey = "fanPresets"

    /// UserDefaults key for the active preset's UUID string.
    private let activeKey = "activeFanPresetID"

    // MARK: - Initialization

    init() {
        load()
    }

    // MARK: - Load

    /// Loads presets from UserDefaults. If decoding fails, initializes with a default set.
    /// Always calls `ensureAutoPreset` afterward to guarantee the built-in Auto preset exists.
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

    /// Ensures the built-in "Auto" preset exists and has the correct number of fan entries.
    ///
    /// If the Auto preset is missing entirely, it is created and inserted at index 0.
    /// If it exists but has a mismatched fan count (e.g., after hardware change),
    /// its `fanAutoModes` dictionary is rebuilt with the correct number of entries.
    ///
    /// - Parameter fanCount: The current number of physical fans detected by the system.
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

    // MARK: - Save

    /// Persists the current presets array and active preset ID to UserDefaults.
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

    // MARK: - CRUD Operations

    /// Adds a new preset to the end of the list and persists to UserDefaults.
    ///
    /// - Parameter preset: The fan preset to add.
    func add(_ preset: FanPreset) {
        presets.append(preset)
        save()
    }

    /// Removes a preset by its `id`. The built-in "Auto" preset cannot be removed.
    ///
    /// If the removed preset was the active preset, `activePresetID` is cleared.
    ///
    /// - Parameter preset: The fan preset to remove (ignored if `isBuiltIn`).
    func remove(_ preset: FanPreset) {
        guard !preset.isBuiltIn else { return }
        presets.removeAll { $0.id == preset.id }
        if activePresetID == preset.id { activePresetID = nil }
        save()
    }

    /// Updates the fan speeds and auto-mode flags of an existing preset.
    ///
    /// - Parameter preset: The preset whose `fanSpeeds` and `fanAutoModes` should be applied
    ///   to the matching entry in the store.
    func update(_ preset: FanPreset) {
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx].fanSpeeds = preset.fanSpeeds
            presets[idx].fanAutoModes = preset.fanAutoModes
            save()
        }
    }

    /// Sets a preset as the currently active (applied) preset.
    ///
    /// - Parameter preset: The preset to activate.
    func activate(_ preset: FanPreset) {
        activePresetID = preset.id
        save()
    }

    // MARK: - Computed Properties

    /// The preset that is currently active (applied to the fans), or `nil` if none.
    var activePreset: FanPreset? {
        presets.first { $0.id == activePresetID }
    }

    /// The built-in "Auto" preset, which represents system-default fan behavior.
    var autoModePreset: FanPreset? {
        presets.first { $0.isBuiltIn }
    }
}
