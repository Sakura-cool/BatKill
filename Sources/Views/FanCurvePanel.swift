//  FanCurvePanel.swift
//  BatKill
//
//  Temperature-curve editor for the fan control "调速" (curve) sub-mode,
//  shown as a chart (验收反馈 v3):
//    - X axis: temperature 0 ... user threshold (°C), one grid per 10 °C
//    - Y axis: fan speed minSpeed ... maxSpeed (RPM), one grid per 100 RPM
//    - Tapping a node edits that step IN-PLACE (a compact stepper appears at
//      the node, no separate panel — the window height never jumps)
//    - A "生效 Apply" button writes the curve's target speed for the current
//      CPU temperature (like the fixed-speed "设定转速" button).

import SwiftUI

/// SwiftUI view rendering a fan's temperature-speed curve as a chart.
struct FanCurvePanel: View {
    let fan: FanInfo
    let curveStore: FanCurveStore
    let lm: LocalizationManager
    /// Called when the user taps "生效" with the target speed for the
    /// current CPU temperature. The parent performs the admin write.
    var onApplySpeed: ((Double) -> Void)?

    /// Step index being edited in place on the chart; nil = none.
    @State private var editingStep: Int?

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
        let bounds = chartBounds
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
                    // Horizontal grid (speed), one per 100 RPM with labels.
                    ForEach(Array(stride(from: bounds.minY, through: bounds.maxY, by: 100)), id: \.self) { speed in
                        yGridLine(plot: plot, speed: speed)
                        // Y-axis value label (RPM)
                        Text("\(Int(speed))")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.secondary)
                            .position(x: plot.x0 - 14, y: yFor(speed: speed, plot: plot, curve: curve))
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
                    curvePath(plot: plot, curve: curve)
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    // Current-temperature marker
                    Rectangle()
                        .fill(Color.red.opacity(0.5))
                        .frame(width: 1.5, height: plot.y1 - plot.y0)
                        .position(x: xFor(temp: current, plot: plot, curve: curve),
                                  y: (plot.y0 + plot.y1) / 2)
                    // Tappable nodes (+ in-place editor for the selected one)
                    nodes(plot: plot, curve: curve, maxStep: maxStep)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(height: 150)

            // Bottom legend: axis units + current-temp target
            HStack {
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
            }
        }
    }

    private func yGridLine(plot: PlotRect, speed: Double) -> some View {
        Path { p in
            let y = yFor(speed: speed, plot: plot, curve: currentCurve)
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

    private func curvePath(plot: PlotRect, curve: FanCurve) -> Path {
        var path = Path()
        let maxStep = FanCurve.maxStepIndex(for: curve.threshold)
        for k in 0...maxStep {
            let t = FanCurve.temperature(atStep: k, threshold: curve.threshold)
            let speed = curve.stepSpeeds[k] ?? 0
            let point = CGPoint(x: xFor(temp: t, plot: plot, curve: curve),
                                y: yFor(speed: speed, plot: plot, curve: curve))
            if k == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    /// Tappable nodes; the selected node shows a compact in-place stepper
    /// (no separate panel, so the window height never jumps).
    private func nodes(plot: PlotRect, curve: FanCurve, maxStep: Int) -> some View {
        ForEach(0...maxStep, id: \.self) { k in
            let t = FanCurve.temperature(atStep: k, threshold: curve.threshold)
            let speed = curve.stepSpeeds[k] ?? 0
            let x = xFor(temp: t, plot: plot, curve: curve)
            let y = yFor(speed: speed, plot: plot, curve: curve)

            if editingStep == k {
                // In-place editor: stepper + quick value label.
                HStack(spacing: 2) {
                    Button("−") { nudgeStep(k, by: -100, curve: curve) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10, weight: .bold))
                    Text("\(Int(speed))")
                        .font(.system(size: 9, design: .monospaced))
                        .frame(width: 42)
                    Button("+") { nudgeStep(k, by: 100, curve: curve) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10, weight: .bold))
                }
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.92))
                .cornerRadius(4)
                .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.orange.opacity(0.6), lineWidth: 1))
                .position(x: clampX(x, plot: plot), y: max(y, plot.y0 + 24))
            } else {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 10, height: 10)
                    .position(x: x, y: y)
                    .onTapGesture { editingStep = k }
            }
        }
    }

    /// Keeps the in-place editor inside the horizontal plot bounds.
    private func clampX(_ x: CGFloat, plot: PlotRect) -> CGFloat {
        min(max(x, plot.x0 + 40), plot.x1 - 40)
    }

    /// Adjusts one step, clamps to [minSpeed, maxSpeed], smooths, persists,
    /// and keeps the editor open for further nudging.
    private func nudgeStep(_ step: Int, by delta: Double, curve: FanCurve) {
        let speed = curve.stepSpeeds[step] ?? fan.minSpeed
        var updated = curve
        updated.stepSpeeds[step] = min(max(speed + delta, fan.minSpeed), fan.maxSpeed)
        curveStore.setCurve(updated.smoothed(), for: fan.index)
    }

    // MARK: - Temp

    private func hardwareTemp() -> Double {
        curveStore.lastReadCPUTemp  // populated by the refresh driver
    }

    // MARK: - Geometry

    private struct PlotRect {
        let x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat
    }

    private var chartBounds: (minY: Double, maxY: Double) {
        (fan.minSpeed, max(fan.maxSpeed, fan.minSpeed + 100))
    }

    private func plotRect(geo: GeometryProxy, bounds: (minY: Double, maxY: Double)) -> PlotRect {
        PlotRect(x0: 30, x1: geo.size.width - 8, y0: 8, y1: geo.size.height - 22)
    }

    private func xFor(temp: Double, plot: PlotRect, curve: FanCurve) -> CGFloat {
        let range = max(curve.threshold, 1)
        let ratio = CGFloat(min(max(temp, 0), curve.threshold) / range)
        return plot.x0 + ratio * (plot.x1 - plot.x0)
    }

    private func yFor(speed: Double, plot: PlotRect, curve: FanCurve) -> CGFloat {
        let bounds = chartBounds
        let range = bounds.maxY - bounds.minY
        let ratio = CGFloat(min(max(speed, bounds.minY), bounds.maxY) - bounds.minY) / CGFloat(range)
        return plot.y1 - ratio * (plot.y1 - plot.y0)
    }
}
