//  FanCurve.swift
//  BatKill
//
//  Temperature-adaptive fan curve for the fan control module.
//
//  When a fan's manual mode uses the "调速" (temperature curve) sub-mode,
//  its target speed is derived from the current CPU temperature. The curve
//  spans 0 ... userThreshold in 10 °C steps — each step has a configurable
//  speed. Above the threshold the fan is handed back to the system (safety).
//
//  Threshold source: reuse the existing "温度阈值保护" setting
//  (`fanTemperatureThreshold`, valid 60-120 °C, default 98 when unset).

import Foundation

// MARK: - Manual Sub-Mode

/// Sub-mode of a fan's manual mode.
enum ManualSubMode: String, Codable, Equatable {
    /// Fixed speed (v0.1.x behavior): one slider sets one speed.
    case fixed
    /// Temperature curve: speed follows CPU temperature over 0...threshold.
    case curve
}

// MARK: - Curve Target

/// Result of evaluating a fan curve at a given temperature.
enum CurveTarget: Equatable {
    /// Write this target speed.
    case speed(Double)
    /// Temperature exceeded the curve threshold — return control to system.
    case systemControl
}

// MARK: - Fan Curve

/// Temperature-adaptive fan curve: per-10°C step speeds from 0 to threshold.
///
/// Steps are keyed by index `k` where temperature = `k * 10`. The final step
/// (at the threshold temperature) is included even when the threshold is not
/// a multiple of ten (e.g. threshold 98 → steps at 0/10/.../90/98).
struct FanCurve: Codable, Equatable {
    /// Step speeds keyed by step index (0 = 0 °C, 1 = 10 °C, ...).
    /// The last index corresponds to the threshold temperature.
    var stepSpeeds: [Int: Double]

    /// Temperature ceiling (°C). Speeds are evaluated across 0...threshold;
    /// temps above this value yield `.systemControl`.
    var threshold: Double

    /// UserDefaults key mirroring `TemperatureThresholdStore` so both share
    /// the same user setting (`fanTemperatureThreshold`).
    static let thresholdDefaultsKey = "fanTemperatureThreshold"

    /// Default threshold when the user has not configured one.
    static let defaultThreshold: Double = 98

    /// Builds a fresh default curve for the given threshold: every step at
    /// `baseSpeed` (caller passes the fan's current or min speed).
    init(threshold: Double, baseSpeed: Double) {
        self.threshold = threshold
        self.stepSpeeds = [:]
        for k in 0...Self.maxStepIndex(for: threshold) {
            stepSpeeds[k] = baseSpeed
        }
    }

    /// System default curve: a linear ramp from `minSpeed` at 0 °C up to
    /// `maxSpeed` at the threshold. Used when the user has not customized
    /// the curve (default after switching to 调速).
    static func systemDefault(threshold: Double, minSpeed: Double, maxSpeed: Double) -> FanCurve {
        var curve = FanCurve(threshold: threshold, baseSpeed: minSpeed)
        let maxStep = maxStepIndex(for: threshold)
        let range = max(maxSpeed - minSpeed, 1)
        for k in 0...maxStep {
            let ratio = Double(k) / Double(maxStep)
            curve.stepSpeeds[k] = minSpeed + range * ratio
        }
        return curve
    }

    /// Smoothed copy for the curve editor: forces monotonicity (clamped)
    /// then evens out local spikes by capping each step to the max of its
    /// neighbors' averages. Prevents "high temp low speed / low temp high
    /// speed" mistakes while keeping the user's overall intent.
    func smoothed() -> FanCurve {
        // 1) Monotonic clamp first (safety net).
        let clamped = clamped()

        // 2) Forward running maximum keeps monotonicity after smoothing.
        var out = clamped
        var runningMax = -Double.greatestFiniteMagnitude
        let keys = clamped.stepSpeeds.keys.sorted()
        for k in keys {
            guard let speed = clamped.stepSpeeds[k] else { continue }
            if speed > runningMax { runningMax = speed }
            out.stepSpeeds[k] = runningMax
        }
        return out
    }

    /// Reads the persisted threshold (same value `TemperatureThresholdStore`
    /// uses); falls back to `defaultThreshold` when unset/invalid.
    static func persistedThreshold() -> Double {
        let stored = UserDefaults.standard.double(forKey: thresholdDefaultsKey)
        return stored > 0 ? stored : defaultThreshold
    }

    /// Highest step index. Steps run 0°C, 10°C, … up to at least the
    /// threshold; the last step sits exactly at the threshold temperature
    /// even when it is not a multiple of ten (threshold 98 → 0/10/…/90/98).
    static func maxStepIndex(for threshold: Double) -> Int {
        max(0, Int(ceil(threshold / 10.0)))
    }

    /// Temperature (°C) at a given step index; the final step is the
    /// threshold temperature itself.
    static func temperature(atStep k: Int, threshold: Double) -> Double {
        if k >= maxStepIndex(for: threshold) { return threshold }
        return Double(k) * 10
    }

    /// Whether adjacent steps are monotonically non-decreasing
    /// (a hotter step must not request a lower speed than a cooler one).
    var isMonotonic: Bool {
        var last = -Double.greatestFiniteMagnitude
        for k in stepSpeeds.keys.sorted() {
            guard let speed = stepSpeeds[k], speed >= last else { return false }
            last = speed
        }
        return true
    }

    /// Clamped copy: forces monotonicity by raising each step to the max of
    /// all lower steps' speeds. Used as a model-layer safety net.
    func clamped() -> FanCurve {
        var out = self
        var runningMax = -Double.greatestFiniteMagnitude
        let keys = stepSpeeds.keys.sorted()
        for k in keys {
            if let speed = stepSpeeds[k], speed > runningMax {
                runningMax = speed
            } else {
                out.stepSpeeds[k] = runningMax
            }
        }
        return out
    }

    /// Evaluates the curve at a CPU temperature, returning a target speed or
    /// `.systemControl` when the temperature exceeds the curve threshold.
    func targetSpeed(for temp: Double) -> CurveTarget {
        let maxStep = Self.maxStepIndex(for: threshold)

        // Above threshold → hand control back to the system.
        if temp > threshold { return .systemControl }

        // Below 0 °C → lowest step.
        let t = max(temp, 0)
        let tempAtStep: (Int) -> Double = { Self.temperature(atStep: $0, threshold: self.threshold) }

        // Fast path: locate enclosing steps.
        let k = min(maxStep, Int(t / 10.0))
        let tK = tempAtStep(k)
        guard let sK = stepSpeeds[k] else { return .systemControl }

        // Exact step (or last step covers threshold).
        if t <= tK || k >= maxStep {
            return .speed(sK)
        }

        // Linear interpolation between step k and k+1.
        let k1 = k + 1
        let tK1 = tempAtStep(k1)
        let sK1 = stepSpeeds[k1] ?? sK
        guard tK1 > tK else { return .speed(sK) }
        let ratio = (t - tK) / (tK1 - tK)
        return .speed(sK + (sK1 - sK) * ratio)
    }
}

// MARK: - Fan Curve Store

/// Observable store managing per-fan manual sub-modes and fan curves with
/// UserDefaults persistence. Independent from `FanPresetStore` — the v0.1.x
/// preset format is untouched for backward compatibility.
final class FanCurveStore: ObservableObject {
    /// Manual sub-mode per fan index (`fanCurvesKey`-independent).
    @Published var subModes: [Int: ManualSubMode] = [:]
    /// Fan curve per fan index.
    @Published var curves: [Int: FanCurve] = [:]

    /// Latest CPU temperature read, used by the curve panel's marker.
    @Published var lastReadCPUTemp: Double = 0

    /// Last successfully written curve target speed per fan (runtime only,
    /// used to skip redundant writes while driving the curve).
    private var lastWrittenSpeeds: [Int: Double] = [:]

    /// Whether a curve fan has already handed control to the system on
    /// over-threshold (runtime only; reset on recovery to prevent write loops).
    private var systemControlFlags: [Int: Bool] = [:]

    /// UserDefaults keys for the two persisted stores.
    private let subModesKey = "fanManualSubModes"
    private let curvesKey = "fanCurves"

    /// Fallback sub-mode when a fan has no stored setting.
    static let defaultSubMode = ManualSubMode.fixed

    init() {
        load()
    }

    /// Loads persisted sub-modes and curves. Any corrupt data simply falls
    /// back to the defaults — never crashes on legacy storage.
    func load() {
        if let data = UserDefaults.standard.data(forKey: subModesKey),
           let decoded = try? JSONDecoder().decode([Int: ManualSubMode].self, from: data) {
            subModes = decoded
        }
        if let data = UserDefaults.standard.data(forKey: curvesKey),
           let decoded = try? JSONDecoder().decode([Int: FanCurve].self, from: data) {
            curves = decoded
        }
    }

    /// Persists both stores to UserDefaults.
    func save() {
        if let data = try? JSONEncoder().encode(subModes) {
            UserDefaults.standard.set(data, forKey: subModesKey)
        }
        if let data = try? JSONEncoder().encode(curves) {
            UserDefaults.standard.set(data, forKey: curvesKey)
        }
    }

    /// Sub-mode for a fan, falling back to `.fixed` when unset.
    func subMode(for index: Int) -> ManualSubMode {
        subModes[index] ?? Self.defaultSubMode
    }

    /// Curve for a fan, creating the system default on demand (linear ramp
    /// from `minSpeed` to `maxSpeed` across the temperature range).
    func curve(for index: Int, minSpeed: Double, maxSpeed: Double) -> FanCurve {
        if let curve = curves[index] { return curve }
        let curve = FanCurve.systemDefault(threshold: FanCurve.persistedThreshold(),
                                           minSpeed: minSpeed,
                                           maxSpeed: maxSpeed)
        curves[index] = curve
        save()
        return curve
    }

    /// Sets a fan's sub-mode (and persists).
    func setSubMode(_ mode: ManualSubMode, for index: Int) {
        subModes[index] = mode
        save()
    }

    /// Updates a fan's curve, applying the monotonic clamp as a safety net.
    func setCurve(_ curve: FanCurve, for index: Int) {
        curves[index] = curve   // raw per-step values, no monotonic clamp
        save()
    }

    /// Updates the curve in memory only (no UserDefaults write). Used by the
    /// chart's drag gesture on every position change; callers persist on end.
    func setCurveLive(_ curve: FanCurve, for index: Int) {
        curves[index] = curve   // raw: in-memory drag preview, no clamp
    }

    /// Persists a curve exactly as edited (independent per-step values; the
    /// monotonic clamp is NOT applied so users can set each temp node freely).
    func storeCurveRaw(_ curve: FanCurve, for index: Int) {
        curves[index] = curve
        save()
    }

    /// Applies preset per-fan sub-modes and curves so the fan-control UI
    /// switches to the matching sub-mode (定速 slider vs 调速 curve chart).
    func applyPresetSubModes(_ subModes: [Int: ManualSubMode]?,
                             curves presetCurves: [Int: FanCurve]?) {
        for (index, mode) in subModes ?? [:] {
            setSubMode(mode, for: index)
        }
        for (index, curve) in presetCurves ?? [:] {
            setCurve(curve, for: index)
        }
    }

    /// Last successfully written curve target speed (for write de-duplication).
    func lastWrittenSpeed(for index: Int) -> Double? {
        lastWrittenSpeeds[index]
    }

    /// Records a successfully written curve target speed.
    func recordWrittenSpeed(_ speed: Double, for index: Int) {
        lastWrittenSpeeds[index] = speed
    }

    /// Whether the fan has already been handed over to the system on
    /// over-threshold (prevents repeated hand-over writes each refresh tick).
    func isSystemControlActive(for index: Int) -> Bool {
        systemControlFlags[index] ?? false
    }

    /// Marks whether the curve fan is currently under system control.
    func setSystemControlActive(_ active: Bool, for index: Int) {
        systemControlFlags[index] = active
    }

    /// Curve target speed for a fan at a given CPU temperature.
    /// Falls back to the fan's current speed when above the threshold.
    func targetSpeed(for index: Int, fan: FanInfo, maxTemp: Double) -> Double {
        let curve = curve(for: index, minSpeed: fan.minSpeed, maxSpeed: fan.maxSpeed)
        if case .speed(let v) = curve.targetSpeed(for: maxTemp) {
            return v
        }
        return fan.currentSpeed
    }

    /// Drives one curve-mode fan for the current CPU temperature: writes the
    /// interpolated target speed on change, and hands control back to the
    /// system exactly once when the temperature exceeds the curve threshold.
    /// Called by the TemperatureView refresh timer each tick.
    func driveFan(fan: FanInfo, hardwareMonitor: HardwareMonitor) {
        guard !hardwareMonitor.thermalThrottled else { return }
        let temp = hardwareMonitor.maxCPUTemp
        guard subMode(for: fan.index) == .curve else { return }
        let curve = curve(for: fan.index, minSpeed: fan.minSpeed, maxSpeed: fan.maxSpeed)

        switch curve.targetSpeed(for: temp) {
        case .speed(let target):
            // Recovered back under threshold — re-enable manual control.
            if isSystemControlActive(for: fan.index) {
                hardwareMonitor.setFanModeWithAdmin(fanIndex: fan.index, auto: false) { _ in
                    self.setSystemControlActive(false, for: fan.index)
                }
            }
            // Skip redundant writes.
            if lastWrittenSpeed(for: fan.index) != target {
                hardwareMonitor.setFanSpeedWithAdmin(fanIndex: fan.index, speed: target) { ok in
                    if ok { self.recordWrittenSpeed(target, for: fan.index) }
                }
            }
        case .systemControl:
            // Hand over to system exactly once per over-threshold event.
            guard !isSystemControlActive(for: fan.index) else { return }
            hardwareMonitor.setFanModeWithAdmin(fanIndex: fan.index, auto: true) { _ in
                self.setSystemControlActive(true, for: fan.index)
            }
        }
    }
}
