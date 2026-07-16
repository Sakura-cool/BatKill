//  FanPresetTests.swift
//  BatKill Tests
//
//  Unit tests for FanPreset model and FanPresetStore.
//  Tests encoding/decoding, equality, and store CRUD operations.

import Foundation

final class FanPresetTests: TestCase {
    let name = "FanPresetTests"
    
    func setUp() {
        UserDefaults.standard.removeObject(forKey: "fanPresets")
        UserDefaults.standard.removeObject(forKey: "activeFanPresetID")
    }
    
    func tearDown() {
        UserDefaults.standard.removeObject(forKey: "fanPresets")
        UserDefaults.standard.removeObject(forKey: "activeFanPresetID")
    }
    
    func run() {
        testFanPresetEncoding()
        testFanPresetDecoding()
        testFanPresetRoundTrip()
        testFanPresetEquality()
        testFanPresetIsBuiltIn()
        testFanPresetAutoModeID()
        testFanPresetStoreAdd()
        testFanPresetStoreRemove()
        testFanPresetStoreUpdate()
        testFanPresetStoreActivate()
        testFanPresetStoreAutoPreset()
        testFanPresetStorePersistence()
    }
    
    // MARK: - FanPreset Codable Tests
    
    private func testFanPresetEncoding() {
        runTest("FanPreset encoding") {
            let preset = FanPreset(
                id: UUID(),
                name: "Silent",
                fanSpeeds: [0: 1200.0, 1: 800.0],
                fanAutoModes: [0: false, 1: false]
            )
            
            let encoder = JSONEncoder()
            let data = try encoder.encode(preset)
            
            XCTAssertNotNil(data, "Encoded data should not be nil")
            XCTAssertTrue(data.count > 0, "Encoded data should not be empty")
        }
    }
    
    private func testFanPresetDecoding() {
        runTest("FanPreset decoding") {
            let testID = UUID()
            let json = """
            {
                "id": "\(testID.uuidString)",
                "name": "Performance",
                "fanSpeeds": {"0": 2400, "1": 1800},
                "fanAutoModes": {"0": false, "1": false}
            }
            """
            
            let data = json.data(using: .utf8)!
            let decoder = JSONDecoder()
            let preset = try decoder.decode(FanPreset.self, from: data)
            
            XCTAssertEqual(preset.id, testID)
            XCTAssertEqual(preset.name, "Performance")
            XCTAssertEqual(preset.fanSpeeds[0], 2400.0)
            XCTAssertEqual(preset.fanSpeeds[1], 1800.0)
            XCTAssertEqual(preset.fanAutoModes[0], false)
            XCTAssertEqual(preset.fanAutoModes[1], false)
        }
    }
    
    private func testFanPresetRoundTrip() {
        runTest("FanPreset encode/decode round trip") {
            let testID = UUID()
            let original = FanPreset(
                id: testID,
                name: "Balanced",
                fanSpeeds: [0: 1500.0, 1: 1000.0],
                fanAutoModes: [0: true, 1: false]
            )
            
            let encoder = JSONEncoder()
            let data = try encoder.encode(original)
            
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(FanPreset.self, from: data)
            
            XCTAssertEqual(decoded.id, original.id)
            XCTAssertEqual(decoded.name, original.name)
            XCTAssertEqual(decoded.fanSpeeds, original.fanSpeeds)
            XCTAssertEqual(decoded.fanAutoModes, original.fanAutoModes)
        }
    }
    
    // MARK: - FanPreset Equality Tests
    
    private func testFanPresetEquality() {
        runTest("FanPreset equality based on id") {
            let testID = UUID()
            
            let preset1 = FanPreset(
                id: testID,
                name: "Silent",
                fanSpeeds: [0: 1000.0],
                fanAutoModes: [0: false]
            )
            
            // Same ID, different properties
            let preset2 = FanPreset(
                id: testID,
                name: "Loud",  // Different name
                fanSpeeds: [0: 3000.0],  // Different speeds
                fanAutoModes: [0: true]  // Different mode
            )
            
            XCTAssertEqual(preset1, preset2, "Same ID should be equal regardless of other properties")
        }
    }
    
    private func testFanPresetIsBuiltIn() {
        runTest("FanPreset isBuiltIn property") {
            let builtIn = FanPreset(
                id: FanPreset.autoModeID,
                name: "Auto",
                fanSpeeds: [:],
                fanAutoModes: [:]
            )
            
            let custom = FanPreset(
                id: UUID(),
                name: "Custom",
                fanSpeeds: [:],
                fanAutoModes: [:]
            )
            
            XCTAssertTrue(builtIn.isBuiltIn, "Preset with autoModeID should be built-in")
            XCTAssertFalse(custom.isBuiltIn, "Preset with random UUID should not be built-in")
        }
    }
    
    private func testFanPresetAutoModeID() {
        runTest("FanPreset autoModeID is constant") {
            let id1 = FanPreset.autoModeID
            let id2 = FanPreset.autoModeID
            
            XCTAssertEqual(id1, id2, "autoModeID should be constant")
            XCTAssertEqual(id1.uuidString, "00000000-0000-0000-0000-000000000001")
        }
    }
    
    // MARK: - FanPresetStore Tests
    
    private func testFanPresetStoreAdd() {
        runTest("FanPresetStore add preset") {
            let store = FanPresetStore()
            let initialCount = store.presets.count
            
            let newPreset = FanPreset(
                name: "TestPreset",
                fanSpeeds: [0: 1200.0],
                fanAutoModes: [0: false]
            )
            
            store.add(newPreset)
            
            XCTAssertEqual(store.presets.count, initialCount + 1, "Should have one more preset")
            XCTAssertTrue(store.presets.contains(where: { $0.name == "TestPreset" }))
        }
    }
    
    private func testFanPresetStoreRemove() {
        runTest("FanPresetStore remove preset") {
            let store = FanPresetStore()
            let initialCount = store.presets.count
            
            let presetToRemove = FanPreset(
                name: "ToRemove",
                fanSpeeds: [:],
                fanAutoModes: [:]
            )
            
            store.add(presetToRemove)
            XCTAssertEqual(store.presets.count, initialCount + 1)
            
            store.remove(presetToRemove)
            XCTAssertEqual(store.presets.count, initialCount, "Should be back to initial count")
            XCTAssertFalse(store.presets.contains(where: { $0.id == presetToRemove.id }))
        }
    }
    
    private func testFanPresetStoreRemoveBuiltIn() {
        runTest("FanPresetStore cannot remove built-in preset") {
            let store = FanPresetStore()
            let initialCount = store.presets.count
            
            guard let builtIn = store.presets.first(where: { $0.isBuiltIn }) else {
                XCTAssertTrue(false, "Should have built-in preset")
                return
            }
            
            store.remove(builtIn)
            
            XCTAssertEqual(store.presets.count, initialCount, "Should not remove built-in preset")
            XCTAssertTrue(store.presets.contains(where: { $0.isBuiltIn }))
        }
    }
    
    private func testFanPresetStoreUpdate() {
        runTest("FanPresetStore update preset") {
            let store = FanPresetStore()
            
            let preset = FanPreset(
                name: "ToUpdate",
                fanSpeeds: [0: 1000.0],
                fanAutoModes: [0: false]
            )
            store.add(preset)
            
            guard let idx = store.presets.firstIndex(where: { $0.id == preset.id }) else {
                XCTAssertTrue(false, "Should find preset")
                return
            }
            
            var updatedPreset = preset
            updatedPreset.fanSpeeds = [0: 2000.0, 1: 1500.0]
            updatedPreset.fanAutoModes = [0: false, 1: false]
            
            store.update(updatedPreset)
            
            XCTAssertEqual(store.presets[idx].fanSpeeds[0], 2000.0)
            XCTAssertEqual(store.presets[idx].fanSpeeds[1], 1500.0)
        }
    }
    
    private func testFanPresetStoreActivate() {
        runTest("FanPresetStore activate preset") {
            let store = FanPresetStore()
            
            let preset = FanPreset(
                name: "ToActivate",
                fanSpeeds: [:],
                fanAutoModes: [:]
            )
            store.add(preset)
            
            XCTAssertNil(store.activePresetID, "Should start with no active preset")
            
            store.activate(preset)
            
            XCTAssertEqual(store.activePresetID, preset.id)
            XCTAssertEqual(store.activePreset?.id, preset.id)
        }
    }
    
    private func testFanPresetStoreAutoPreset() {
        runTest("FanPresetStore always has auto preset") {
            let store = FanPresetStore()
            store.ensureAutoPreset(fanCount: 1)
            
            XCTAssertTrue(store.presets.count >= 1, "Should have at least 1 preset (Auto)")
            XCTAssertTrue(store.presets.first?.isBuiltIn ?? false, "First preset should be built-in Auto")
            XCTAssertEqual(store.autoModePreset?.name, "Auto")
        }
    }
    
    private func testFanPresetStorePersistence() {
        runTest("FanPresetStore persistence across instances") {
            // First instance: add a preset
            let store1 = FanPresetStore()
            let initialCount = store1.presets.count
            
            let preset = FanPreset(
                name: "PersistentPreset",
                fanSpeeds: [0: 1200.0],
                fanAutoModes: [0: false]
            )
            store1.add(preset)
            store1.activate(preset)
            
            // Second instance: should load from UserDefaults
            let store2 = FanPresetStore()
            
            XCTAssertEqual(store2.presets.count, initialCount + 1)
            XCTAssertTrue(store2.presets.contains(where: { $0.name == "PersistentPreset" }))
            XCTAssertEqual(store2.activePresetID, preset.id)
        }
    }
}
