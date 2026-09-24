//  FanCurvePanel.swift
//  BatKill
//
//  Temperature-curve editor for the fan control "调速" (curve) sub-mode,
//  shown as a chart (验收反馈 v3 + v4):
//    - X axis: temperature 0 ... user threshold (°C), one grid per 10 °C
//    - Y axis: fan speed (RPM), adaptive range around the curve's actual
//      speeds; labels shown in hundreds (300 → "3", unit "×100")
//    - Tapping a node opens an inline text field + 确定/取消 for that step
//    - A red vertical line marks the current CPU temperature with a label
//    - A "生效 Apply" button writes the target speed for the current temp

import SwiftUI

/// SwiftUI view rendering a fan's temperature-speed curve as a chart.
struct FanCurvePanel: View {
    let fan: FanInfo
    let curveStore: FanCurveStore
    let lm: LocalizationManager
    /// Called when the user taps "生效" with the target speed for the
    /// current CPU temperature. The parent performs the admin write.
    var onApplySpeed: ((Double) -> Void)?
    /// Status message after a write attempt (same slot as fixed-speed).
    var statusMessage: String?
    /// Whether an admin authorization button should be shown.
    var needsAdmin: Bool = false
    /// Called when the user taps "授权管理员".
    var onAuthorize: () -> Void = {}

    /// Step index being edited in place on the chart; nil = none.
    @State private var editingStep: Int?
    /// Text buffer for the inline step editor.
    @State private var editText: String = ""
    /// Transient validation message.
    @State private var editError: String?

    var body: some View {
        let curve = currentCurve
        return VStack(alignment: .leading, spacing: 4) {
            header(for: curve)
            curveChart(for: curve)
        }
        .id(curve.threshold)   // re-render when threshold/step count changes
    }

    private var currentCurve: FanCurve {
        curveStore.curve(for: fan.index, minSpeed: fan.minSpeed, maxSpeed: fan.maxSpeed)
    }

    private func header(for curve: FanCurve) -> some View {
        HStack {
            Text(lm.translate("Curve up to %d °C", "调速曲线至 %d °C", Int(curve.threshold)))
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
            Text("\(Int(FanCurve.temperature(atStep: 0, threshold: curve.threshold)))°C" +
                    " — \(Int(curve.threshold))°C  ·  \(Int(fan.minSpeed))~\(Int(fan.maxSpeed)) RPM")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Chart

    private func curveChart(for curve: FanCurve) -> some View {
        let maxStep = FanCurve.maxStepIndex(for: curve.threshold)
        let bounds = chartBounds(for: curve)
        let current = hardwareTemp()
        // Target speed at the current temperature for the Apply button.
        let targetSpeed: Double = {
            if case .speed(let v) = curve.targetSpeed(for: current) { return v }
            return fan.currentSpeed
        }()

        return VStack(spacing: 0) {
            GeometryReader { geo in
                let plot = plotRect(geo: geo, bounds: bounds)
                ZStack {
                    // Horizontal grid (speed), step 100 RPM, adaptive range.
                    ForEach(Array(stride(from: bounds.minY, through: bounds.maxY, by: 100)), id: \.self) { speed in
                        yGridLine(plot: plot, speed: speed)
                        Text("\(Int(speed / 100))")          // 300 → "3"
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.secondary)
                            .position(x: plot.x0 - 14, y: yFor(speed: speed, plot: plot, bounds: bounds))
                    }
                    // Vertical grid (temperature), one per 10 °C with labels.
                    ForEach(0...maxStep, id: \.self) { k in
                        let t = FanCurve.temperature(atStep: k, threshold: curve.threshold)
                        xGridLine(plot: plot, temp: t, curve: curve)
                        Text("\(Int(t))")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.secondary)
                            .position(x: xFor(temp: t, plot: plot, curve: curve), y: plot.y1 + 10)
                    }
                    // Curve polyline
                    curvePath(plot: plot, curve: curve, bounds: bounds)
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    // Current-temperature marker (red vertical line + label)
                    Rectangle()
                        .fill(Color.red.opacity(0.5))
                        .frame(width: 1.5, height: plot.y1 - plot.y0)
                        .position(x: xFor(temp: current, plot: plot, curve: curve),
                                  y: (plot.y0 + plot.y1) / 2)
                    Text("\(Int(current))°")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(.red)
                        .padding(.horizontal, 3)
                        .background(Color(NSColor.windowBackgroundColor).opacity(0.7))
                        .position(x: min(xFor(temp: current, plot: plot, curve: curve) + 8,
                                         plot.x1 - 14),
                                  y: plot.y0 + 8)
                    // Tappable nodes (+ inline editor on selection)
                    nodes(plot: plot, curve: curve, maxStep: maxStep, bounds: bounds)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(height: 150)

            // Action row: Apply (like fixed-speed 设定转速) + authorize +
            // status message — mirrors FanFixedSpeedControls interaction.
            HStack(spacing: 8) {
                Text(lm.translate("Y: ×100 RPM", "Y 轴: ×100 转/分"))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Text(lm.translate("Current %d °C → %d RPM", "当前 %d °C → %d 转/分",
                                  Int(current), Int(targetSpeed)))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.red)
                Spacer()
                Button {
                    onApplySpeed?(targetSpeed)
                } label: {
                    Label(lm.translate("Apply", "生效"), systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.blue)
                .help(lm.translate("Write current curve speed to the fan",
                                   "将当前温度对应的目标转速写入风扇"))

                // Admin authorization button (shown after first failed attempt)
                if needsAdmin {
                    Button(action: onAuthorize) {
                        Label(lm.translate("Authorize Admin", "授权管理员"),
                              systemImage: "lock.shield")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.orange)
                }

                // Status message after write attempt
                if let status = statusMessage {
                    Text(status)
                        .font(.caption2)
                        .foregroundColor(needsAdmin ? .red : .green)
                }
            }
        }
    }

    private func yGridLine(plot: PlotRect, speed: Double) -> some View {
        Path { p in
            let y = yFor(speed: speed, plot: plot, bounds: plot.bounds)
            p.move(to: CGPoint(x: plot.x0, y: y))
            p.addLine(to: CGPoint(x: plot.x1, y: y))
        }
        .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
    }

    private func xGridLine(plot: PlotRect, temp: Double, curve: FanCurve) -> some View {
        Path { p in
            let x = xFor(temp: temp, plot: plot, curve: curve)
            p.move(to: CGPoint(x: x, y: plot.y0))
            p.addLine(to: CGPoint(x: x, y: plot.y1))
        }
        .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
    }

    private func curvePath(plot: PlotRect, curve: FanCurve, bounds: (minY: Double, maxY: Double)) -> Path {
        var path = Path()
        let maxStep = FanCurve.maxStepIndex(for: curve.threshold)
        for k in 0...maxStep {
            let t = FanCurve.temperature(atStep: k, threshold: curve.threshold)
            let speed = curve.stepSpeeds[k] ?? 0
            let point = CGPoint(x: xFor(temp: t, plot: plot, curve: curve),
                                y: yFor(speed: speed, plot: plot, bounds: bounds))
            if k == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    /// Tappable nodes; the selected node shows an inline text-field editor.
    private func nodes(plot: PlotRect, curve: FanCurve, maxStep: Int,
                       bounds: (minY: Double, maxY: Double)) -> some View {
        ForEach(0...maxStep, id: \.self) { k in
            let t = FanCurve.temperature(atStep: k, threshold: curve.threshold)
            let speed = curve.stepSpeeds[k] ?? 0
            let x = xFor(temp: t, plot: plot, curve: curve)
            let y = yFor(speed: speed, plot: plot, bounds: bounds)

            if editingStep == k {
                nodeEditor(plot: plot, step: k, bounds: bounds)
            } else {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 10, height: 10)
                    .position(x: x, y: y)
                    .onTapGesture {
                        editingStep = k
                        editText = String(format: "%d", Int(speed))
                        editError = nil
                    }
            }
        }
    }

    /// Inline editor: numeric field + 确定/取消 (no −/+ steppers; see v4).
    private func nodeEditor(plot: PlotRect, step: Int,
                            bounds: (minY: Double, maxY: Double)) -> some View {
        let curve = currentCurve
        let temp = FanCurve.temperature(atStep: step, threshold: curve.threshold)
        let x = xFor(temp: temp, plot: plot, curve: curve)
        return VStack(spacing: 1) {
            HStack(spacing: 3) {
                Text("\(Int(temp))°C")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.secondary)
                Text(editError ?? "")
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(.red)
                TextField("", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 9, design: .monospaced))
                    .frame(width: 44)
                    .multilineTextAlignment(.trailing)
                    .background(Color(NSColor.textBackgroundColor))
                    .overlay(Rectangle().stroke(Color.secondary.opacity(0.4), lineWidth: 0.5))
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.orange.opacity(0.6), lineWidth: 1))

            HStack(spacing: 4) {
                Button(lm.translate("OK", "确定")) { commitEdit(step: step) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                Button(lm.translate("Cancel", "取消")) { editingStep = nil }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
            }
        }
        .position(x: clampX(x, plot: plot), y: plot.y0 + 34)
    }

    /// Commits the typed speed, clamps, smooths, persists.
    private func commitEdit(step: Int) {
        guard let value = Double(editText), value.isFinite else {
            editError = "0~\(Int(fan.maxSpeed))"
            return
        }
        var updated = currentCurve
        updated.stepSpeeds[step] = min(max(value, fan.minSpeed), fan.maxSpeed)
        curveStore.setCurve(updated.smoothed(), for: fan.index)
        editingStep = nil
        editText = ""
        editError = nil
    }

    /// Keeps the inline editor inside the horizontal plot bounds.
    private func clampX(_ x: CGFloat, plot: PlotRect) -> CGFloat {
        min(max(x, plot.x0 + 50), plot.x1 - 50)
    }

    // MARK: - Temp

    private func hardwareTemp() -> Double {
        curveStore.lastReadCPUTemp  // populated by the refresh driver
    }

    // MARK: - Geometry

    private struct PlotRect {
        let x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat
        let bounds: (minY: Double, maxY: Double)
    }

    /// Adaptive Y range: only the curve's actual speed span (rounded to
    /// 100s with a small margin), so a 1000–2000 curve fills the chart
    /// instead of a dense 0–maxSpeed grid.
    private func chartBounds(for curve: FanCurve) -> (minY: Double, maxY: Double) {
        let speeds = curve.stepSpeeds.values
        let rawMin = speeds.min() ?? fan.minSpeed
        let rawMax = speeds.max() ?? fan.maxSpeed
        let lo = max(fan.minSpeed, floor((rawMin - 100) / 100) * 100)
        var hi = min(fan.maxSpeed, ceil((rawMax + 100) / 100) * 100)
        if hi - lo < 200 { hi = lo + 200 }
        return (lo, hi)
    }

    private func plotRect(geo: GeometryProxy, bounds: (minY: Double, maxY: Double)) -> PlotRect {
        PlotRect(x0: 30, x1: geo.size.width - 8, y0: 8,
                 y1: geo.size.height - 22, bounds: bounds)
    }

    private func xFor(temp: Double, plot: PlotRect, curve: FanCurve) -> CGFloat {
        let range = max(curve.threshold, 1)
        let ratio = CGFloat(min(max(temp, 0), curve.threshold) / range)
        return plot.x0 + ratio * (plot.x1 - plot.x0)
    }

    private func yFor(speed: Double, plot: PlotRect, bounds: (minY: Double, maxY: Double)) -> CGFloat {
        let range = bounds.maxY - bounds.minY
        let ratio = CGFloat(min(max(speed, bounds.minY), bounds.maxY) - bounds.minY) / CGFloat(range)
        return plot.y1 - ratio * (plot.y1 - plot.y0)
    }
}
